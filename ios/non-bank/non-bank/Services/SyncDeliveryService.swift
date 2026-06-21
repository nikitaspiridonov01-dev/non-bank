import Foundation

/// Thin client for the Worker's Phase-1 sync delivery endpoints
/// (`/v1/sync/{upload,inbox,ack,revoke}`). Pairs with `SyncDeliveryCrypto`
/// (which produces/consumes the encrypted `payload`) and `SyncPairing`
/// (which produces the `pair_hmac`).
///
/// Every call attaches App Attest headers (same as `SyncPairing` /
/// `/v1/parse-receipt`); on the simulator / unsupported devices those are
/// `[:]` and the lenient server lets the request through. All calls are
/// best-effort: a network error / non-2xx is swallowed and surfaced as a
/// `false` / empty result the orchestrator can retry or fall back from —
/// the transaction is always saved locally first, so sync failure is never
/// data loss.
enum SyncDeliveryService {

    /// One un-acked delivery as returned by `GET /v1/sync/inbox`. Snake-case
    /// keys match the Worker JSON verbatim.
    struct InboxDelivery: Decodable {
        let tx_sync_id: String
        let version: Int
        let op: String
        let payload: String
        let checksum: String?
        /// Sender's real user id (cleartext envelope field, new in the
        /// 0009 migration). The recipient derives the pairwise decryption
        /// key from this, so it can decrypt — and self-heal pairing from —
        /// a delivery even when it only holds the sender as an un-upgraded
        /// phantom. `nil` for legacy rows / older senders.
        let sender_id: String?
    }

    private static func syncEndpoint(_ leaf: String) -> URL {
        BackendConfig.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("sync")
            .appendingPathComponent(leaf)
    }

    /// Attach the shared JSON + App Attest headers to a request.
    private static func attest(_ req: inout URLRequest) async {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let headers = await AppAttestService.shared.authHeaders(backendURL: BackendConfig.baseURL)
        for (key, value) in headers {
            req.setValue(value, forHTTPHeaderField: key)
        }
    }

    private static func isOK(_ response: URLResponse?) -> Bool {
        guard let http = response as? HTTPURLResponse else { return false }
        return (200...299).contains(http.statusCode)
    }

    // MARK: - Upload (sender)

    private struct UploadBody: Encodable {
        let pair_hmac: String
        let recipient_id: String
        let tx_sync_id: String
        let version: Int
        let op: String
        let payload: String
        let checksum: String?
        let sender_id: String
    }

    /// Outcome of a delivery upload. `.pairingInactive` (HTTP 409) means the
    /// recipient REVOKED the pairing (removed us as a friend) — permanent, so
    /// the caller greys them; `.failed` is transient (offline / 5xx) and may
    /// recover, so it only offers the share fallback.
    enum UploadOutcome { case ok, pairingInactive, failed }

    /// POST /v1/sync/upload — push one addressed, encrypted delivery to a
    /// paired recipient. `.ok` only on a 2xx; a 409 `pairing_inactive` →
    /// `.pairingInactive`; anything else → `.failed`.
    @discardableResult
    static func upload(
        pairHMAC: String,
        recipientID: String,
        senderID: String,
        txSyncID: String,
        version: Int,
        op: String,
        payloadCiphertext: String,
        checksum: String?
    ) async -> UploadOutcome {
        var req = URLRequest(url: syncEndpoint("upload"))
        req.httpMethod = "POST"
        await attest(&req)
        let body = UploadBody(
            pair_hmac: pairHMAC, recipient_id: recipientID, tx_sync_id: txSyncID,
            version: version, op: op, payload: payloadCiphertext, checksum: checksum,
            sender_id: senderID
        )
        guard let httpBody = try? JSONEncoder().encode(body) else { return .failed }
        req.httpBody = httpBody
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 409 {
                return .pairingInactive
            }
            return isOK(response) ? .ok : .failed
        } catch {
            return .failed
        }
    }

    // MARK: - Inbox pull (recipient)

    /// Tombstone version for `delete` deliveries. Must beat any real
    /// `editVersion` (small monotonic counters) so a delete always wins the
    /// server's version guard — but it MUST stay within the JS/JSON
    /// safe-integer range (2^53-1 = 9_007_199_254_740_991). `Int.max`
    /// (9.22e18) does NOT: the Worker round-trips it through a JS `number` as
    /// `9223372036854776000`, which OVERFLOWS Swift's `Int` on decode and made
    /// the ENTIRE inbox response fail to decode — silently poisoning all sync
    /// (every pull returned []). 9e12 is astronomically above real edit
    /// counters yet safely below 2^53.
    static let tombstoneVersion = 9_000_000_000_000

    /// Wraps a single delivery so ONE malformed element (e.g. a legacy
    /// `Int.max`-versioned tombstone from a not-yet-updated client) is skipped
    /// instead of failing the whole array decode — the root cause of the inbox
    /// poisoning above. A bad row → `value == nil` → dropped; the rest apply.
    private struct FailableDelivery: Decodable {
        let value: InboxDelivery?
        init(from decoder: Decoder) throws {
            value = try? InboxDelivery(from: decoder)
        }
    }

    private struct InboxResponse: Decodable {
        let deliveries: [InboxDelivery]
        enum CodingKeys: String, CodingKey { case deliveries }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            deliveries = try container
                .decode([FailableDelivery].self, forKey: .deliveries)
                .compactMap(\.value)
        }
    }

    /// GET /v1/sync/inbox?recipient_id=… — pull un-acked deliveries.
    /// Returns [] on any failure (offline / non-2xx) so the caller simply
    /// tries again next foreground.
    static func fetchInbox(recipientID: String) async -> [InboxDelivery] {
        guard var components = URLComponents(
            url: syncEndpoint("inbox"), resolvingAgainstBaseURL: false
        ) else { return [] }
        components.queryItems = [URLQueryItem(name: "recipient_id", value: recipientID)]
        guard let url = components.url else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        await attest(&req)
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard isOK(response) else { return [] }
            return (try? JSONDecoder().decode(InboxResponse.self, from: data))?.deliveries ?? []
        } catch {
            return []
        }
    }

    // MARK: - Ack (recipient)

    private struct AckItem: Encodable { let tx_sync_id: String; let version: Int }
    private struct AckBody: Encodable { let recipient_id: String; let acks: [AckItem] }

    /// POST /v1/sync/ack — confirm the listed (syncID, version) deliveries
    /// were applied locally so the server can sweep them. Best-effort: a
    /// missed ack just means the row re-delivers next pull (idempotent).
    @discardableResult
    static func ack(
        recipientID: String,
        acks: [(txSyncID: String, version: Int)]
    ) async -> Bool {
        guard !acks.isEmpty else { return true }
        var req = URLRequest(url: syncEndpoint("ack"))
        req.httpMethod = "POST"
        await attest(&req)
        let body = AckBody(
            recipient_id: recipientID,
            acks: acks.map { AckItem(tx_sync_id: $0.txSyncID, version: $0.version) }
        )
        guard let httpBody = try? JSONEncoder().encode(body) else { return false }
        req.httpBody = httpBody
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return isOK(response)
        } catch {
            return false
        }
    }

    // MARK: - Revoke (friend removal)

    private struct RevokeBody: Encodable { let pair_hmac: String }

    /// POST /v1/sync/revoke — flip a pairing to 'revoked' when the user
    /// removes a friend, so the server refuses further deliveries for the
    /// pair. Best-effort; the local friend is already deleted regardless.
    @discardableResult
    static func revoke(pairHMAC: String) async -> Bool {
        var req = URLRequest(url: syncEndpoint("revoke"))
        req.httpMethod = "POST"
        await attest(&req)
        guard let httpBody = try? JSONEncoder().encode(RevokeBody(pair_hmac: pairHMAC)) else { return false }
        req.httpBody = httpBody
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return isOK(response)
        } catch {
            return false
        }
    }

    // MARK: - Push token registration (P3)

    private struct RegisterTokenBody: Encodable {
        let user_id: String
        let token: String
        let env: String
    }

    /// POST /v1/sync/register-token — register this device's APNs token so
    /// the server can push when a delivery lands. `env` is "sandbox" for
    /// Xcode dev builds, "production" for TestFlight / App Store. Best-effort.
    @discardableResult
    static func registerToken(userID: String, token: String, env: String) async -> Bool {
        var req = URLRequest(url: syncEndpoint("register-token"))
        req.httpMethod = "POST"
        await attest(&req)
        guard let httpBody = try? JSONEncoder().encode(
            RegisterTokenBody(user_id: userID, token: token, env: env)
        ) else { return false }
        req.httpBody = httpBody
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return isOK(response)
        } catch {
            return false
        }
    }
}

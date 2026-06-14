import Foundation
import CryptoKit

// MARK: - Sync Pairing
//
// Server-mediated sync, Phase 0: the opener side of pairing.
//
// When a real user opens an incoming share link and the inbound import
// succeeds, we tell the Worker that these two users are now paired so a
// later phase can route sync updates between them. The server must never
// learn the raw social graph, so the pairing identifier is an HMAC the
// CLIENT computes over the two user ids — the server only ever sees the
// opaque digest.
//
// ## What the server sees
//   POST {BackendConfig.baseURL}/v1/sync/pair
//   { "pair_hmac": "<64 lowercase hex>", "user_id": "<caller's user id>" }
//
// ## Why this is safe to embed a shared secret
// The HMAC key (`pairingSecret`) is a single fixed app-embedded constant,
// identical across every install. That's acceptable because the secret's
// only job is to stop the *server* from reverse-mapping `pair_hmac` back
// to a raw `(idA, idB)` pair by brute-forcing the (small, guessable)
// user-id space — without the key the server can't recompute the digest.
// It is NOT a per-user authentication secret; App Attest headers handle
// request authenticity. A leaked secret degrades the social-graph privacy
// property but doesn't grant any write capability the attest layer
// wouldn't already gate.
//
// ## Best-effort by contract
// Every call here is fire-and-forget. Network failure, missing/failed App
// Attest, or any non-2xx response is swallowed — pairing is a background
// nicety and must NEVER block, delay, or break the share-link import flow
// the user actually cares about.
enum SyncPairing {

    /// Fixed, app-embedded HMAC key. Shared across all installs by design
    /// (see file header). Both participants must derive the IDENTICAL
    /// `pair_hmac`, so this constant — and the canonicalisation below —
    /// must stay byte-for-byte stable across app versions.
    private static let pairingSecret = "non-bank-pairing-v1"

    /// Stable, order-independent pairing digest for two user ids.
    ///
    /// `pair_hmac = lowercase-hex( HMAC-SHA256( key: pairingSecret,
    ///              message: UTF8(canonical) ) )`
    /// where `canonical = [a, b].sorted().joined(separator: "|")`.
    ///
    /// The ids are sorted lexically and joined with `"|"` WITHOUT any
    /// lowercasing or other transform, so the opener and the sharer — who
    /// pass the same two ids in opposite argument order — land on the same
    /// canonical string and therefore the same digest. A later phase (the
    /// sharer side) reuses this exact function, which is why it lives in a
    /// standalone helper.
    static func pairHMAC(_ a: String, _ b: String) -> String {
        let canonical = [a, b].sorted().joined(separator: "|")
        let key = SymmetricKey(data: Data(pairingSecret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(
            for: Data(canonical.utf8),
            using: key
        )
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Fire-and-forget POST to `/v1/sync/pair` recording that `myID` and
    /// `sharerID` are now paired. Attaches App Attest headers when
    /// available (mirroring `/v1/parse-receipt`), and swallows every
    /// failure mode. Safe to call from any actor — it does only network
    /// IO and reads no main-actor state.
    ///
    /// No-ops when the two ids are equal (you can't pair with yourself) or
    /// when either id is empty.
    ///
    /// Returns `true` only when the server confirmed the pairing with a 2xx
    /// response. Marked `@discardableResult` so the existing fire-and-forget
    /// call sites stay unchanged, while the recipient toast path can `await`
    /// the result and only celebrate "new friend added" on a real success
    /// (a 403/offline/5xx returns `false`, so we never claim a pairing the
    /// server rejected).
    @discardableResult
    static func recordPairing(myID: String, sharerID: String) async -> Bool {
        guard !myID.isEmpty, !sharerID.isEmpty, myID != sharerID else { return false }

        let backendURL = BackendConfig.baseURL
        let endpoint = backendURL
            .appendingPathComponent("v1")
            .appendingPathComponent("sync")
            .appendingPathComponent("pair")

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 15

        let body = PairRequest(
            pair_hmac: pairHMAC(myID, sharerID),
            user_id: myID
        )
        guard let httpBody = try? JSONEncoder().encode(body) else { return false }
        req.httpBody = httpBody

        // App Attest: same headers `/v1/parse-receipt` sends. On the
        // simulator / unsupported devices this returns `[:]` and the
        // request goes through unattested — the server is currently
        // lenient, so that still succeeds. Any attest failure also yields
        // `[:]`; we attach whatever we get and let the server decide.
        let attestHeaders = await AppAttestService.shared.authHeaders(backendURL: backendURL)
        for (key, value) in attestHeaders {
            req.setValue(value, forHTTPHeaderField: key)
        }

        // Best-effort: any thrown error or non-2xx is swallowed (no retry
        // here — the caller decides whether to surface anything). We return
        // whether the server confirmed (2xx) so a caller that cares (the
        // recipient toast) can gate on a real success.
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            #if DEBUG
            print("[SyncPairing] /v1/sync/pair → \(status)")
            #endif
            return (200...299).contains(status)
        } catch {
            #if DEBUG
            print("[SyncPairing] recordPairing failed (ignored): \(error.localizedDescription)")
            #endif
            return false
        }
    }

    /// Wire shape for the POST body. Snake-case keys match the Worker
    /// contract verbatim — no `CodingKeys` remap needed.
    private struct PairRequest: Encodable {
        let pair_hmac: String
        let user_id: String
    }
}

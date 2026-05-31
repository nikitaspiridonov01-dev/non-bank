import Foundation
import DeviceCheck
import CryptoKit

// MARK: - App Attest Service
//
// Cryptographically proves that requests to the expensive AI endpoint
// (`/v1/parse-receipt`) come from a genuine, unmodified instance of
// THIS app running on real Apple hardware — not a script replaying a
// captured `device_id`. Backed by Apple's `DCAppAttestService` (Secure
// Enclave key + attestation cert chain rooted at Apple's App Attest CA).
//
// ## Flow
//  1. **Key + attestation (once per install):** generate a Secure
//     Enclave key → `keyId`; attest it against a server-issued
//     challenge; the backend verifies the attestation cert chain,
//     extracts the public key, and stores `(keyId → pubkey, counter=0)`.
//  2. **Per-request assertion:** sign a fresh `{timestamp, nonce}`
//     blob with the attested key; the backend verifies the signature
//     against the stored public key and that the Secure-Enclave counter
//     strictly increased (replay protection).
//
// ## Graceful degradation
//  - **Simulator / unsupported device:** `DCAppAttestService.isSupported`
//    is `false`. We attach no headers. The backend's **staging** env is
//    lenient (allows missing attestation) so simulator development keeps
//    working; **production** is strict (rejects), but production builds
//    only ever run on real devices where App Attest is supported.
//  - **Any attest error:** we return empty headers and let the request
//    proceed; prod will 403 and the caller falls back to local OCR, same
//    as any other parse failure. We never hard-block the app on attest.
//
// `keyId` is NOT secret (the private key lives in the Secure Enclave,
// only referenced by id), so persisting it in UserDefaults is fine.
actor AppAttestService {

    static let shared = AppAttestService()

    private let service = DCAppAttestService.shared

    private enum Keys {
        static let keyId = "appattest.keyId"
        static let attested = "appattest.attested"
    }

    /// In-flight attestation guard so concurrent first-requests don't
    /// each generate + attest a separate key.
    private var attestTask: Task<String, Error>?

    private init() {}

    /// Headers to attach to a protected request, or `[:]` when App
    /// Attest is unavailable / fails (the request then proceeds and the
    /// backend decides whether to allow it per env strictness).
    func authHeaders(backendURL: URL) async -> [String: String] {
        guard service.isSupported else { return [:] }
        do {
            let keyId = try await ensureAttestedKey(backendURL: backendURL)
            // Per-request client data: a fresh timestamp + nonce. The
            // backend recomputes `SHA256(clientData)` from the header,
            // checks the timestamp is recent, verifies the assertion
            // signature, and enforces a strictly-increasing counter.
            let clientData = Self.makeClientData()
            let clientDataHash = Data(SHA256.hash(data: clientData))
            let assertion = try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
            return [
                "X-Attest-Key-Id": keyId,
                "X-Attest-Assertion": assertion.base64EncodedString(),
                "X-Attest-Client-Data": clientData.base64EncodedString(),
            ]
        } catch {
            #if DEBUG
            print("[AppAttest] authHeaders failed: \(error.localizedDescription)")
            #endif
            return [:]
        }
    }

    // MARK: - Attestation (one-time key registration)

    private func ensureAttestedKey(backendURL: URL) async throws -> String {
        // Fast path: a key we've already attested + registered.
        if let keyId = UserDefaults.standard.string(forKey: Keys.keyId),
           UserDefaults.standard.bool(forKey: Keys.attested) {
            return keyId
        }
        // Coalesce concurrent callers onto one attestation.
        if let task = attestTask { return try await task.value }
        let task = Task<String, Error> {
            defer { attestTask = nil }
            let keyId = try await service.generateKey()
            let challenge = try await fetchChallenge(keyId: keyId, backendURL: backendURL)
            // Attestation client-data hash = SHA256 of the server
            // challenge — binds this attestation to a fresh nonce the
            // backend issued, so an old attestation can't be replayed.
            let clientDataHash = Data(SHA256.hash(data: challenge))
            let attestation = try await service.attestKey(keyId, clientDataHash: clientDataHash)
            try await registerAttestation(
                keyId: keyId,
                attestation: attestation,
                challenge: challenge,
                backendURL: backendURL
            )
            UserDefaults.standard.set(keyId, forKey: Keys.keyId)
            UserDefaults.standard.set(true, forKey: Keys.attested)
            return keyId
        }
        attestTask = task
        return try await task.value
    }

    private func fetchChallenge(keyId: String, backendURL: URL) async throws -> Data {
        var comps = URLComponents(
            url: backendURL.appendingPathComponent("v1/attest/challenge"),
            resolvingAgainstBaseURL: false
        )!
        comps.queryItems = [URLQueryItem(name: "keyId", value: keyId)]
        var req = URLRequest(url: comps.url!)
        req.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AttestError.challengeFailed
        }
        let decoded = try JSONDecoder().decode(ChallengeResponse.self, from: data)
        guard let challenge = Data(base64Encoded: decoded.challenge) else {
            throw AttestError.malformedChallenge
        }
        return challenge
    }

    private func registerAttestation(
        keyId: String,
        attestation: Data,
        challenge: Data,
        backendURL: URL
    ) async throws {
        var req = URLRequest(url: backendURL.appendingPathComponent("v1/attest/verify"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 20
        let body = AttestVerifyBody(
            keyId: keyId,
            attestation: attestation.base64EncodedString(),
            challenge: challenge.base64EncodedString()
        )
        req.httpBody = try JSONEncoder().encode(body)
        let (_, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw AttestError.registrationFailed
        }
    }

    // MARK: - Helpers

    /// `{"t": <unix seconds>, "n": "<16 random bytes, base64>"}` as
    /// UTF-8 JSON. Deterministic key order (`t` then `n`) so the bytes
    /// the Secure Enclave signs match exactly what the backend hashes.
    private static func makeClientData() -> Data {
        var nonceBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        let nonce = Data(nonceBytes).base64EncodedString()
        let ts = Int(Date().timeIntervalSince1970)
        // Hand-format to guarantee byte-stability (JSONEncoder key order
        // isn't contractually fixed across OS versions).
        let json = "{\"t\":\(ts),\"n\":\"\(nonce)\"}"
        return Data(json.utf8)
    }

    enum AttestError: Error {
        case challengeFailed
        case malformedChallenge
        case registrationFailed
    }

    private struct ChallengeResponse: Decodable { let challenge: String }
    private struct AttestVerifyBody: Encodable {
        let keyId: String
        let attestation: String
        let challenge: String
    }
}

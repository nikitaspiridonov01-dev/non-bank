import Foundation

/// Thin client for the Worker's `/v1/share-items/{share_id}` endpoints.
/// Pairs the URL payload (which carries the financial summary) with a
/// server-side ciphertext of the receipt items list.
///
/// Both methods are deliberately permissive about failure: the share
/// link works without items (it always has, since the encoder used to
/// strip items entirely), so any network / 4xx / 5xx response is logged
/// and surfaced as `nil` / a thrown error the caller can swallow. The
/// fallback is the no-items rendering the recipient sees today.
@MainActor
final class ShareItemsService {
    static let shared = ShareItemsService()

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Build the `/v1/share-items/{share_id}` URL for a payload checksum.
    /// `share_id` validated as 64-char hex on the server; we lowercase
    /// here (`SharedTransactionPayload.checksum` is already lowercase)
    /// to be defensive against future re-implementations.
    private func endpoint(shareID: String) -> URL {
        BackendConfig.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("share-items")
            .appendingPathComponent(shareID.lowercased())
    }

    enum ServiceError: LocalizedError {
        case badResponse
        case serverError(status: Int)

        var errorDescription: String? {
            switch self {
            case .badResponse:
                return "Share-items service returned a non-HTTP response"
            case .serverError(let status):
                return "Share-items service returned HTTP \(status)"
            }
        }
    }

    /// Upload an encrypted items payload under the given share ID.
    /// Caller must produce `ciphertextBase64` via `ShareItemsCrypto.
    /// encryptItems(_:urlPayload:)` — same URL payload that derives the
    /// recipient's decryption key. Returns silently on 200 / 201. Any
    /// other status throws `ServiceError.serverError`.
    func upload(shareID: String, ciphertextBase64: String) async throws {
        var req = URLRequest(url: endpoint(shareID: shareID))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(["payload": ciphertextBase64])

        let (_, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.badResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(status: http.statusCode)
        }
    }

    /// Fetch the encrypted items payload for a share ID. Returns `nil`
    /// when the server reports 404 — that's the normal "this share has
    /// no items on the server" outcome (sender skipped upload, items
    /// already expired, or this is a legacy URL from before the
    /// server-items rollout). Throws on any other non-2xx.
    func fetch(shareID: String) async throws -> String? {
        let req = URLRequest(url: endpoint(shareID: shareID))
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw ServiceError.badResponse
        }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else {
            throw ServiceError.serverError(status: http.statusCode)
        }
        let decoded = try JSONDecoder().decode([String: String].self, from: data)
        return decoded["payload"]
    }
}

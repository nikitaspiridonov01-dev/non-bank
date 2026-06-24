import Foundation
import CryptoKit

/// E2E encryption / decryption helpers for receipt items transported
/// alongside a share-link.
///
/// ## Threat model
///
/// The Cloudflare Worker stores the ciphertext bundle (`/v1/share-items/
/// {checksum}`) and serves it on request. The Worker MUST NOT be able
/// to read the items it persists — only someone who already has the
/// share URL should decrypt. Achieved with a key derived from the URL's
/// `?p=...` payload string via HKDF-SHA256: anyone with the URL can
/// derive the same key; anyone without it (including the Worker, a
/// database snapshot leaker, a passive eavesdropper on TLS) cannot.
///
/// ## Wire format
///
///   `base64(nonce(12) ‖ ciphertext ‖ tag(16))`
///
/// where the plaintext is a compact JSON array of `WireItem` objects
/// (one-letter keys to keep the bundle small for the 10 KB server cap).
/// AES-256-GCM gives both confidentiality and integrity — a tampered
/// row on the server is rejected at decrypt time, the recipient falls
/// back to the no-items path silently.
///
/// ## Why HKDF over plain SHA-256
///
/// The URL payload is high-entropy (base64url of randomly-distributed
/// JSON bytes) but not uniform. HKDF's extract step "whitens" it into
/// a uniformly distributed key before the AES round, which is the
/// orthodox recipe for "derive a symmetric key from a non-uniform
/// secret". Salt is a static string — its only job is to scope this
/// derivation to this app's share-items feature so the same URL
/// payload couldn't accidentally collide with a derived key from
/// some hypothetical future feature.
enum ShareItemsCrypto {

    private static let hkdfSalt: Data = Data("non-bank-share-items-v1".utf8)
    private static let hkdfInfo: Data = Data("items".utf8)
    private static let keyByteCount: Int = 32  // AES-256

    enum CryptoError: LocalizedError {
        case invalidBase64
        case sealFailed
        case openFailed(underlying: Error)
        case encodingFailed

        var errorDescription: String? {
            switch self {
            case .invalidBase64:    return "Share-items payload was not valid base64"
            case .sealFailed:       return "Failed to encrypt share-items payload"
            case .openFailed:       return "Failed to decrypt share-items payload"
            case .encodingFailed:   return "Failed to encode share-items as JSON"
            }
        }
    }

    /// Derive the AES-256 key from a share-URL `?p=...` payload string.
    /// Same input → same key on every device with the same URL; the
    /// Worker never sees this material so it cannot derive it.
    static func deriveKey(urlPayload: String) -> SymmetricKey {
        let inputKey = SymmetricKey(data: Data(urlPayload.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: keyByteCount
        )
    }

    /// Encrypt a receipt-items list for upload to the share-items
    /// endpoint. Returns the base64-encoded combined-AEAD bundle.
    /// `urlPayload` is the URL's `?p=…` query-param value; it doubles
    /// as the key-derivation input AND the implicit binding between
    /// the ciphertext and a specific share URL (a ciphertext from one
    /// share can't decrypt under another share's key).
    static func encryptItems(_ items: [ReceiptItem], urlPayload: String) throws -> String {
        let wire = items.map(WireItem.init(from:))
        guard let plaintext = try? JSONEncoder().encode(wire) else {
            throw CryptoError.encodingFailed
        }
        let key = deriveKey(urlPayload: urlPayload)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw CryptoError.sealFailed }
            return combined.base64EncodedString()
        } catch {
            throw CryptoError.sealFailed
        }
    }

    /// Decrypt a payload pulled from the share-items endpoint. Throws
    /// on malformed base64 or auth-tag-mismatch (tampered ciphertext)
    /// — callers should treat any throw as "fall back to the no-items
    /// path" rather than surfacing crypto errors to the user.
    static func decryptItems(base64: String, urlPayload: String) throws -> [ReceiptItem] {
        guard let combined = Data(base64Encoded: base64) else {
            throw CryptoError.invalidBase64
        }
        let key = deriveKey(urlPayload: urlPayload)
        let plaintext: Data
        do {
            let sealed = try AES.GCM.SealedBox(combined: combined)
            plaintext = try AES.GCM.open(sealed, using: key)
        } catch {
            throw CryptoError.openFailed(underlying: error)
        }
        let wire = try JSONDecoder().decode([WireItem].self, from: plaintext)
        return wire.map { $0.toReceiptItem() }
    }

    /// Compact wire format — single-letter keys to keep ciphertext small
    /// (10 KB server cap). Only the fields the recipient needs to render
    /// + assign; persistence fields (`syncID`, `persistedID`, …) are
    /// re-minted on the recipient side at insert time.
    private struct WireItem: Codable {
        let n: String           // name
        let q: Double?          // quantity
        let p: Double?          // unit price
        let t: Double?          // line total
        let a: [String]         // assigned participant IDs
        let k: String?          // forced kind (manual tips); nil for auto rows

        init(from item: ReceiptItem) {
            n = item.name
            q = item.quantity
            p = item.price
            t = item.total
            a = item.assignedParticipantIDs
            k = item.forcedKind?.rawValue
        }

        // Optional-decode `a` and `k` so a payload from an older app
        // build (which omitted them) still decodes — a missing optional
        // synthesises to nil, and we map a nil `a` to the empty array.
        enum CodingKeys: String, CodingKey { case n, q, p, t, a, k }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            n = try c.decode(String.self, forKey: .n)
            q = try c.decodeIfPresent(Double.self, forKey: .q)
            p = try c.decodeIfPresent(Double.self, forKey: .p)
            t = try c.decodeIfPresent(Double.self, forKey: .t)
            a = try c.decodeIfPresent([String].self, forKey: .a) ?? []
            k = try c.decodeIfPresent(String.self, forKey: .k)
        }

        func toReceiptItem() -> ReceiptItem {
            ReceiptItem(
                name: n,
                quantity: q,
                price: p,
                total: t,
                assignedParticipantIDs: a,
                forcedKind: k.flatMap(ReceiptItem.Kind.init(rawValue:))
            )
        }
    }
}

import Foundation
import CryptoKit

/// End-to-end encryption for server-mediated split-transaction deliveries
/// (`pending_deliveries`). Mirrors `ShareItemsCrypto` (HKDF-SHA256 →
/// AES-256-GCM) but derives the key from the **pair of user ids** instead
/// of a URL payload, because app-to-app sync has no shared URL.
///
/// ## Key derivation & why the server can't read deliveries
/// `key = HKDF-SHA256( ikm: "non-bank-sync-v1|" + sorted(idA,idB).joined("|") )`.
/// Both paired users know both raw ids (each stored the other as a Friend),
/// so they independently derive the IDENTICAL key. The Worker stores only
/// the opaque `pair_hmac` (in `pairings`) and the AES-GCM ciphertext — it
/// never receives the raw-id key material, so a passive D1 dump can't
/// decrypt a delivery. This is the same DB-leak-resistance level as the
/// URL-keyed `share_items` channel.
///
/// ## Sender identification on pull
/// A delivery row carries `recipient_id` but deliberately NOT the sender's
/// raw id (keeping the social graph off the server). The recipient
/// therefore can't look up "who sent this" before decrypting — instead it
/// derives a candidate key for EACH of its paired friends and tries
/// `AES.GCM.open`; the AES-GCM auth tag authenticates exactly one key, so
/// the friend whose key opens the box IS the sender. See
/// `SyncDeliveryService.pullAndApply`.
enum SyncDeliveryCrypto {

    /// Versioned key-derivation prefix. Bump (and gate by payload schema)
    /// only if the derivation ever changes — both sides must agree byte
    /// for byte, exactly like `SyncPairing.pairingSecret`.
    private static let ikmPrefix = "non-bank-sync-v1"

    /// Distinct salt/info from `ShareItemsCrypto` so a ciphertext from one
    /// channel can never be opened with the other channel's key even if
    /// the input material somehow coincided.
    private static let hkdfSalt = Data("non-bank-sync-delivery-salt-v1".utf8)
    private static let hkdfInfo = Data("non-bank-sync-delivery-key-v1".utf8)
    private static let keyByteCount = 32 // AES-256

    enum CryptoError: LocalizedError {
        case encodingFailed
        case sealFailed
        case invalidBase64
        case openFailed(underlying: Error)
        case decodeFailed(underlying: Error)

        var errorDescription: String? {
            switch self {
            case .encodingFailed: return "Failed to encode sync delivery payload"
            case .sealFailed:     return "Failed to encrypt sync delivery payload"
            case .invalidBase64:  return "Sync delivery payload was not valid base64"
            case .openFailed:     return "Failed to decrypt sync delivery payload"
            case .decodeFailed:   return "Failed to decode sync delivery payload"
            }
        }
    }

    /// Order-independent symmetric key for the (a, b) pair. Sorted + joined
    /// the SAME way `SyncPairing.pairHMAC` canonicalises, so the two
    /// derivations stay aligned and obviously correct side by side.
    static func deriveKey(_ a: String, _ b: String) -> SymmetricKey {
        let canonical = ikmPrefix + "|" + [a, b].sorted().joined(separator: "|")
        let ikm = SymmetricKey(data: Data(canonical.utf8))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: ikm,
            salt: hkdfSalt,
            info: hkdfInfo,
            outputByteCount: keyByteCount
        )
    }

    /// Encrypt a payload addressed from `myID` to `peerID`. Returns the
    /// base64 combined-AEAD bundle for the delivery `payload` field. Uses
    /// `.sortedKeys` so the plaintext is canonical (irrelevant to AES, but
    /// keeps encode deterministic for tests).
    static func encrypt(
        _ payload: SharedTransactionPayload,
        myID: String,
        peerID: String
    ) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let plaintext = try? encoder.encode(payload) else {
            throw CryptoError.encodingFailed
        }
        let key = deriveKey(myID, peerID)
        do {
            let sealed = try AES.GCM.seal(plaintext, using: key)
            guard let combined = sealed.combined else { throw CryptoError.sealFailed }
            return combined.base64EncodedString()
        } catch {
            throw CryptoError.sealFailed
        }
    }

    /// Decrypt a delivery known to be from `peerID` to `myID`. Throws on
    /// bad base64 or an auth-tag mismatch (wrong key / tampered). Callers
    /// that don't yet know the sender try each candidate peer and treat a
    /// throw as "not from this peer" (see `tryDecrypt`).
    static func decrypt(
        base64: String,
        myID: String,
        peerID: String
    ) throws -> SharedTransactionPayload {
        guard let combined = Data(base64Encoded: base64) else {
            throw CryptoError.invalidBase64
        }
        let key = deriveKey(myID, peerID)
        let plaintext: Data
        do {
            let box = try AES.GCM.SealedBox(combined: combined)
            plaintext = try AES.GCM.open(box, using: key)
        } catch {
            throw CryptoError.openFailed(underlying: error)
        }
        do {
            return try JSONDecoder().decode(SharedTransactionPayload.self, from: plaintext)
        } catch {
            throw CryptoError.decodeFailed(underlying: error)
        }
    }

    /// Convenience for the pull path: attempt to open a delivery with the
    /// key for `peerID`, returning the payload on success or `nil` if this
    /// peer's key doesn't authenticate the ciphertext. The caller iterates
    /// its paired friends until one returns non-nil — that peer is the
    /// sender. Returns nil (not throw) so the loop stays clean.
    static func tryDecrypt(
        base64: String,
        myID: String,
        candidatePeerID: String
    ) -> SharedTransactionPayload? {
        try? decrypt(base64: base64, myID: myID, peerID: candidatePeerID)
    }
}

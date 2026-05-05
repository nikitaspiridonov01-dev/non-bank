import Foundation
import CryptoKit

// MARK: - Shared Transaction Payload

/// What we cram into a share-link URL. Designed for **no-backend** sharing
/// of split transactions: the entire transaction round-trips through the
/// URL itself (`https://example.com/s/?p=BASE64URL_OF_THIS_JSON`).
///
/// ## Why short JSON keys
/// URL length matters — base64-url-encoded JSON ends up in the link the
/// user copies into iMessage / Telegram / wherever. Two-letter keys keep
/// the typical link well under 800 chars even with many participants.
///
/// ## Schema versioning
/// `v` is always emitted, decoder rejects unknown versions outright with
/// `SharedTransactionError.unsupportedVersion`. When we add fields in v2,
/// old apps see "your friend uses a newer version, update to view" — never
/// silent corruption.
///
/// ## What we deliberately DON'T ship
/// - **emoji** — the receiver derives the transaction emoji from the
///   category, so shipping it separately would just create drift.
/// - **description / note** — agreed with product to skip for v1.
/// - **receipt items / tags** — same.
/// - **lentAmount** — derivable as `paidByMe - myShare`, no need to ship.
/// - **friend ownership of "isSettled"** — settle state is local and
///   shouldn't be propagated cross-user.
struct SharedTransactionPayload: Codable, Equatable {

    /// Schema version. Bump on incompatible field changes; the decoder
    /// only accepts known versions.
    let v: Int

    /// `Transaction.syncID` — the stable identifier we use on the
    /// receiver side to detect "I already have this share" and decide
    /// between create-new / update-existing / no-op.
    let id: String

    /// Sharer's `UserIDService.currentID()`. Two uses on the receiver:
    /// 1. Generate the sharer's pixel-cat avatar.
    /// 2. Exclude the sharer from the "who are you?" picker (the receiver
    ///    can't be the sharer — the sharer is the one who sent the link).
    let s: String

    /// Total purchase amount (`SplitInfo.totalAmount`). The full bill,
    /// before splitting.
    let ta: Double

    /// What the sharer actually paid out of pocket (`SplitInfo.paidByMe`,
    /// also stored on `Transaction.amount` for split rows).
    let pa: Double

    /// Sharer's fair share of the bill (`SplitInfo.myShare`).
    let ms: Double

    /// ISO 4217 currency code.
    let c: String

    /// Transaction date as a UNIX timestamp (seconds, Double for
    /// sub-second precision). Receiver re-creates with the same date so
    /// the friend's debt history stays in sync.
    let d: TimeInterval

    /// Transaction kind: `"exp"` (expense) or `"inc"` (income).
    /// Currently splits are always expenses, but encoded explicitly for
    /// forward-compat.
    let k: String

    /// Transaction title.
    let t: String

    /// Category title. Receiver matches by exact title against their own
    /// categories; on miss, creates a new one using `ce` as the icon.
    let cn: String

    /// Category emoji. Used only when `cn` doesn't match any of the
    /// receiver's categories. Receiver guarantees uniqueness — if `ce`
    /// collides with another category they own, they pick a different
    /// glyph.
    let ce: String

    /// Split mode raw value (`"equal"`, `"custom"`, …). `nil` for legacy
    /// data without an explicit mode.
    let sm: String?

    /// Sharer's display name (`UserProfileService.displayName()`). `nil`
    /// when the sharer hasn't set one yet — the receiver falls back to
    /// the generic `"Friend"` placeholder in that case. Optional so v1
    /// payloads from older app versions still decode cleanly.
    let sn: String?

    /// Other participants in the split — everyone EXCEPT the sharer.
    /// Order is preserved from the sharer's view so the receiver renders
    /// names in the same sequence.
    let f: [Participant]

    struct Participant: Codable, Equatable {
        /// Sharer's stable ID for this friend (`FriendIDGenerator` format,
        /// e.g. `"amber-lynx-7K2D"`). Receivers may match against their
        /// own friend list to skip the picker for known faces.
        let id: String
        /// Display name as the sharer saved it. Receiver shows this name
        /// when this participant isn't them.
        let n: String
        /// Fair share of the total (`FriendShare.share`).
        let sh: Double
        /// What this participant actually paid up-front
        /// (`FriendShare.paidAmount`). Usually 0 — the sharer often pays
        /// for everyone.
        let pa: Double
    }
}

// MARK: - Checksum

extension SharedTransactionPayload {
    /// SHA-256 hex digest of the canonical JSON of this payload. Two
    /// payloads with the same contents always produce the same digest,
    /// regardless of how/when they were encoded.
    ///
    /// ## Why we need this
    /// The receiver, when seeing a link they've already imported, asks:
    /// "is this byte-for-byte the same as what I already have, or did the
    /// sharer edit something?" Storing the digest with the imported
    /// transaction lets us answer that in O(1) without re-parsing the
    /// whole share link.
    ///
    /// ## Why `.sortedKeys`
    /// `JSONEncoder` doesn't promise key order without it. Sorted-keys
    /// JSON is canonical: same payload → same bytes → same SHA.
    var checksum: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        // `try!` is intentional — `Encodable` of `Codable` value-only
        // structs cannot fail at runtime; the only failure modes (bad
        // floats etc.) we don't allow at construction.
        let data = try! encoder.encode(self)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Errors

enum SharedTransactionError: LocalizedError {
    /// Encoder was handed a transaction that isn't a split.
    case notASplitTransaction
    /// Encoder couldn't find the category record needed for `cn` / `ce`.
    case categoryNotFound(name: String)
    /// Decoder was handed a URL with an unsupported `v`. Future apps may
    /// emit higher versions; current code refuses to risk silent loss.
    case unsupportedVersion(Int)
    /// The URL had no `?p=…` parameter.
    case missingPayload
    /// `?p=…` wasn't valid base64url.
    case invalidEncoding
    /// Decoded JSON didn't conform to `SharedTransactionPayload`.
    case malformedPayload(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .notASplitTransaction:
            return "Only split transactions can be shared."
        case .categoryNotFound(let name):
            return "Couldn't find category \"\(name)\" for the share link."
        case .unsupportedVersion(let v):
            return "This share link uses a newer format (version \(v)). Update the app to open it."
        case .missingPayload:
            return "Share link is missing its data."
        case .invalidEncoding:
            return "Share link is corrupted (could not decode)."
        case .malformedPayload(let underlying):
            return "Share link contents are invalid: \(underlying.localizedDescription)"
        }
    }
}

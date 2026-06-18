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

    /// Recurring rule, when the shared transaction is a recurring
    /// reminder. Optional — non-recurring transactions omit it. New
    /// in v1.1 (additive — existing v1 decoders ignore unknown keys
    /// per Swift Codable defaults, so this stays backwards compatible).
    /// The receiver applies it to `Transaction.repeatInterval` so the
    /// imported reminder behaves the same as a locally-created one.
    let r: SharedRecurring?

    /// Monotonic edit version (`Transaction.editVersion`). Additive and
    /// OPTIONAL: old apps that predate server-sync omit it and new
    /// decoders ignore the absence (treated as "no version info"); old
    /// decoders ignore the unknown key. The receiver's
    /// `ShareIntentClassifier` uses it as a guard — it never applies an
    /// incoming edit whose version isn't strictly greater than the local
    /// copy's, so a stale / out-of-order delivery can't clobber a newer
    /// transaction. `nil` falls back to the pre-sync checksum-only behavior.
    let ev: Int?

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
        /// "Connected": was this participant a CONNECTED/real-user friend
        /// on the sharer's side at share time (`Friend.isConnected`)?
        ///
        /// Drives the recipient-identity invariant in
        /// `ShareIntentClassifier`: a participant the sharer addressed by
        /// a REAL userID is `cn == true`; a phantom / ad-hoc person the
        /// sharer addressed by a generated id is `cn == false`. If the
        /// receiver can't match any participant by their own userID, they
        /// MUST be one of the phantoms — so the picker shows only
        /// `cn != true` candidates and never lets the receiver mis-pick a
        /// connected friend (which would corrupt the sharer's synced data).
        ///
        /// OPTIONAL on purpose: links emitted before this field existed
        /// decode with `cn == nil`, which the classifier treats the same
        /// as `false` (`cn != true`) — so OLD links naturally fall back to
        /// "every participant is a candidate" = the original behavior.
        let cn: Bool?

        // Explicit memberwise init so the `cn:` argument can default to
        // `nil`. Without this, every existing `Participant(...)` call site
        // (encoder, tests, fixtures) would have to pass `cn`. Defaulting
        // here keeps them all building unchanged; the encoder passes the
        // real value.
        init(id: String, n: String, sh: Double, pa: Double, cn: Bool? = nil) {
            self.id = id
            self.n = n
            self.sh = sh
            self.pa = pa
            self.cn = cn
        }
    }

    // Custom memberwise init — Swift's synthesized one doesn't support
    // default values, so once `r` was added every existing call site
    // (encoder + tests) would need updating. Defaulting `r` to nil
    // here keeps non-recurring callers building without changes; the
    // encoder explicitly passes its computed value.
    init(
        v: Int,
        id: String,
        s: String,
        ta: Double,
        pa: Double,
        ms: Double,
        c: String,
        d: TimeInterval,
        k: String,
        t: String,
        cn: String,
        ce: String,
        sm: String?,
        sn: String?,
        f: [Participant],
        r: SharedRecurring? = nil,
        ev: Int? = nil
    ) {
        self.v = v
        self.id = id
        self.s = s
        self.ta = ta
        self.pa = pa
        self.ms = ms
        self.c = c
        self.d = d
        self.k = k
        self.t = t
        self.cn = cn
        self.ce = ce
        self.sm = sm
        self.sn = sn
        self.f = f
        self.r = r
        self.ev = ev
    }
}

// MARK: - Recurring rule (compact wire format)

/// Compact, share-link-friendly representation of `RepeatInterval`. We
/// don't reuse the iOS enum directly because Swift's Codable
/// synthesises tagged-union JSON that's verbose (`{"daily":{...}}`); a
/// flat struct with short keys keeps the URL tighter.
///
/// Wire shape (only the fields relevant to the kind are emitted):
///   daily   → `{"k":"d","h":9,"mn":0}`
///   weekly  → `{"k":"w","h":9,"mn":0,"dw":[2,5]}`
///   monthly → `{"k":"m","h":9,"mn":0,"dm":[1,15]}`
///   yearly  → `{"k":"y","h":9,"mn":0,"mo":3,"dy":15}`
struct SharedRecurring: Codable, Equatable {
    /// Kind: `"d"` daily, `"w"` weekly, `"m"` monthly, `"y"` yearly.
    let k: String
    /// Hour of day (0–23).
    let h: Int
    /// Minute of hour (0–59). Named `mn` (not `m`) so it can't be
    /// confused with `"m"` (monthly) on the kind axis.
    let mn: Int
    /// Days of week (1=Sunday … 7=Saturday). Only set when `k == "w"`.
    let dw: [Int]?
    /// Days of month (1–31). Only set when `k == "m"`.
    let dm: [Int]?
    /// Month of year (1=Jan … 12=Dec). Only set when `k == "y"`.
    let mo: Int?
    /// Day of month (1–31). Only set when `k == "y"`.
    let dy: Int?

    // MARK: Conversion

    /// Build the wire format from a `RepeatInterval`. One direction —
    /// the encoder (sharer side) calls this; the receiver decodes via
    /// the reverse helper below.
    init?(from interval: RepeatInterval) {
        switch interval {
        case .daily(let hour, let minute):
            self.k = "d"; self.h = hour; self.mn = minute
            self.dw = nil; self.dm = nil; self.mo = nil; self.dy = nil
        case .weekly(let hour, let minute, let days):
            self.k = "w"; self.h = hour; self.mn = minute
            self.dw = days.map(\.rawValue)
            self.dm = nil; self.mo = nil; self.dy = nil
        case .monthly(let hour, let minute, let days):
            self.k = "m"; self.h = hour; self.mn = minute
            self.dm = days
            self.dw = nil; self.mo = nil; self.dy = nil
        case .yearly(let hour, let minute, let month, let day):
            self.k = "y"; self.h = hour; self.mn = minute
            self.mo = month.rawValue; self.dy = day
            self.dw = nil; self.dm = nil
        }
    }

    /// Decode back into a `RepeatInterval`. Returns nil for an
    /// unknown kind so a v1.2 sharer that emits a new kind doesn't
    /// crash an older receiver — they get the transaction without
    /// the recurring flag, same as a non-recurring share.
    func toRepeatInterval() -> RepeatInterval? {
        switch k {
        case "d":
            return .daily(hour: h, minute: mn)
        case "w":
            let days = (dw ?? []).compactMap { DayOfWeek(rawValue: $0) }
            guard !days.isEmpty else { return nil }
            return .weekly(hour: h, minute: mn, daysOfWeek: days)
        case "m":
            let days = dm ?? []
            guard !days.isEmpty else { return nil }
            return .monthly(hour: h, minute: mn, daysOfMonth: days)
        case "y":
            guard let moRaw = mo, let month = MonthOfYear(rawValue: moRaw),
                  let day = dy else { return nil }
            return .yearly(hour: h, minute: mn, month: month, dayOfMonth: day)
        default:
            return nil
        }
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

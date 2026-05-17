import Foundation

// MARK: - Parsed Receipt Models

/// Helper to decode numbers that may arrive as String, Int, Double, null, or garbage like "-"
struct FlexibleDouble: Codable, Sendable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let d = try? container.decode(Double.self) {
            value = d
        } else if let i = try? container.decode(Int.self) {
            value = Double(i)
        } else if let s = try? container.decode(String.self) {
            // Try to parse number from string, stripping spaces/commas
            let cleaned = s.replacingOccurrences(of: " ", with: "")
                           .replacingOccurrences(of: ",", with: ".")
            value = Double(cleaned)
        } else {
            value = nil
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

struct ReceiptItem: Codable, Sendable, Identifiable, Equatable {

    /// What this line represents on the receipt. Drives the icon shown
    /// next to it in review/edit sheets and how the line is treated in
    /// the "by items" split-share calculator (regular `.item`s are
    /// directly assignable to participants; the rest are distributed
    /// proportionally to each participant's item subtotal).
    ///
    /// The classifier is based on the item's name (via
    /// `ReceiptLineFilter`) and the sign of `lineTotal`. We don't store
    /// the kind on disk — it's a pure function of the existing fields,
    /// so a future tweak to the classifier (e.g. a new tax keyword)
    /// instantly reclassifies historic rows on next read.
    enum Kind: String, Codable, Sendable, Equatable {
        case item
        case discount
        case fee
        case tip

        /// Classifies a (name, lineTotal) pair the same way
        /// `ReceiptItem.kind` does. Exposed as a static so view-model
        /// wrappers (e.g. the editor's `EditableItem`) can render the
        /// matching icon without round-tripping through a full
        /// `ReceiptItem`.
        ///
        /// Note: there is no `.tax` case. Tax / VAT / sales-tax lines
        /// are filtered out at parse time (classifier returns
        /// `.skipNonProduct`) because they're store-side metadata
        /// already included in the receipt grand total — not a
        /// trackable buyer expense. Historic rows that used to carry
        /// kind=tax in name (e.g. "VAT 18%") now fall through this
        /// switch as plain `.item` on read; they're harmless because
        /// no split logic depends on the `.tax` case anymore.
        static func classify(name: String, lineTotal: Double) -> Kind {
            if lineTotal < 0 { return .discount }
            switch ReceiptLineFilter.classify(name) {
            case .discount: return .discount
            case .fee:      return .fee
            case .tip:      return .tip
            case .keep, .skipNonProduct, .anchorTotal:
                return .item
            }
        }
    }

    /// Sentinel used inside `assignedParticipantIDs` to represent the
    /// current user (the one creating the split). Friend IDs are
    /// UUID-style strings, so the double-underscore prefix can't collide.
    /// We use a sentinel (rather than a separate `Bool isAssignedToMe`
    /// field) so the assignment list has a single uniform shape regardless
    /// of whether `you` is a participant.
    static let selfParticipantID = "__me__"

    /// In-memory unique identifier, used by SwiftUI iteration. Distinct from
    /// `persistedID` so the same record can survive renumbering.
    var id = UUID()
    let name: String
    let quantity: Double?
    let price: Double?
    let total: Double?

    /// IDs of participants responsible for this line in a `byItems`
    /// split. Each entry is either a `Friend.id` or `selfParticipantID`.
    /// An item with an empty array is unassigned — the create-transaction
    /// flow surfaces a warning before save.
    ///
    /// Default is empty so existing call sites that build a `ReceiptItem`
    /// from scratch (LLM parser output, manual rows added in the editor)
    /// don't need to know about assignments. They're populated by the
    /// item-assignment flow only when `splitMode == .byItems`.
    var assignedParticipantIDs: [String] = []

    // MARK: - Persistence fields
    //
    // These are not part of the JSON Codable contract — they're populated and
    // mutated by the SQLite layer. `Codable` therefore uses an explicit
    // `CodingKeys` that excludes them.

    /// SQLite autoincrement primary key. `nil` until the row is inserted.
    var persistedID: Int? = nil
    /// Transaction this item belongs to. `nil` while the user is still
    /// reviewing parsed items inside the create-transaction flow.
    var transactionID: Int? = nil
    /// Stable cross-device identifier for syncing.
    var syncID: String = UUID().uuidString
    /// Display order within the receipt (top-to-bottom on the original).
    var position: Int = 0
    var lastModified: Date = Date()

    /// True if this item has a name and a non-zero price or total. Negative
    /// values are allowed so discount items (`Скидка -5,00`) survive — the
    /// downstream parser converts those into deductions.
    var isUsable: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        ((price ?? 0) != 0 || (total ?? 0) != 0)
    }

    /// Best-effort line total: prefers stored `total`, falls back to
    /// `quantity * price` when only the unit price is recorded. Returns the
    /// stored total verbatim — including negatives — since callers (sum,
    /// pruning) need the actual sign.
    var lineTotal: Double {
        if let total, total != 0 { return total }
        let q = quantity ?? 1
        return q * (price ?? 0)
    }

    /// Classification used by the icon row and split-share calculator.
    /// Derived purely from `name` (via `ReceiptLineFilter`) and the sign
    /// of `lineTotal` — so a future tweak to the classifier (a new tax
    /// keyword, a fresh discount synonym) instantly reclassifies historic
    /// rows on next read with no migration.
    var kind: Kind {
        Kind.classify(name: name, lineTotal: lineTotal)
    }

    enum CodingKeys: String, CodingKey {
        case name, quantity, price, total
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        quantity = (try? container.decode(FlexibleDouble.self, forKey: .quantity))?.value
        price = (try? container.decode(FlexibleDouble.self, forKey: .price))?.value
        total = (try? container.decode(FlexibleDouble.self, forKey: .total))?.value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(quantity, forKey: .quantity)
        try container.encodeIfPresent(price, forKey: .price)
        try container.encodeIfPresent(total, forKey: .total)
    }

    init(
        name: String,
        quantity: Double?,
        price: Double?,
        total: Double?,
        assignedParticipantIDs: [String] = [],
        persistedID: Int? = nil,
        transactionID: Int? = nil,
        syncID: String = UUID().uuidString,
        position: Int = 0,
        lastModified: Date = Date()
    ) {
        self.name = name
        self.quantity = quantity
        self.price = price
        self.total = total
        self.assignedParticipantIDs = assignedParticipantIDs
        self.persistedID = persistedID
        self.transactionID = transactionID
        self.syncID = syncID
        self.position = position
        self.lastModified = lastModified
    }

    // MARK: - Display formatting
    //
    // Single source of truth for how a receipt-item amount or quantity reads
    // in the UI. Used by every surface that lists items so the formatting
    // can't drift out of sync between them. The visual rendering of an
    // amount (bold integer + smaller decimal) lives in
    // `ReceiptItemAmountText` — this string formatter is for places that
    // need a single-line value (the editor's "Total: X" header, the
    // save-confirmation copy, the "qty × price" subtitle).

    /// Integer-clean values render without a decimal ("305"); anything
    /// else gets two-decimal precision ("5.84"). Thousand separators come
    /// from the shared `NumberFormatting.integerPart` so larger receipts
    /// read as "1 290" rather than "1290" and stay consistent with the
    /// home rows / transaction card amount style.
    static func formatAmount(_ value: Double) -> String {
        NumberFormatting.integerPart(value) + NumberFormatting.decimalPartIfAny(value)
    }

    /// `%g` for fractional quantities so "1.5", "0.25" etc. display
    /// without trailing zeros, while whole numbers stay as "2", "10".
    static func formatQuantity(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(Int(value))
        }
        return String(format: "%g", value)
    }
}

struct ParsedReceipt: Codable, Sendable {
    let storeName: String?
    let date: String?
    let items: [ReceiptItem]
    let totalAmount: Double?
    let currency: String?
    /// LLM's best match against the user's existing category list — populated
    /// only on the cloud path. Plain string (not a `Category.id`) so the
    /// matcher in `CreateTransactionViewModel` can do a tolerant title compare.
    let suggestedCategory: String?
    /// ISO-639-1 two-letter code of the dominant receipt language,
    /// or `nil` if the parser couldn't identify it with confidence.
    /// Surfaced to analytics only — no UI consumption.
    let language: String?

    enum CodingKeys: String, CodingKey {
        case storeName, date, items, totalAmount, currency, suggestedCategory, language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeName = try? container.decode(String.self, forKey: .storeName)
        date = try? container.decode(String.self, forKey: .date)
        currency = try? container.decode(String.self, forKey: .currency)
        totalAmount = (try? container.decode(FlexibleDouble.self, forKey: .totalAmount))?.value
        suggestedCategory = try? container.decode(String.self, forKey: .suggestedCategory)
        language = try? container.decode(String.self, forKey: .language)

        let rawItems = (try? container.decode([ReceiptItem].self, forKey: .items)) ?? []
        // Filter out garbage items with no valid price
        items = rawItems.filter { $0.isUsable }
    }

    /// Direct initializer for heuristic construction (no decoding).
    init(
        storeName: String?,
        date: String?,
        items: [ReceiptItem],
        totalAmount: Double?,
        currency: String?,
        suggestedCategory: String? = nil,
        language: String? = nil
    ) {
        self.storeName = storeName
        self.date = date
        self.items = items
        self.totalAmount = totalAmount
        self.currency = currency
        self.suggestedCategory = suggestedCategory
        self.language = language
    }
}

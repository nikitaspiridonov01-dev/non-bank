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
    /// In-memory unique identifier, used by SwiftUI iteration. Distinct from
    /// `persistedID` so the same record can survive renumbering.
    var id = UUID()
    let name: String
    let quantity: Double?
    let price: Double?
    let total: Double?

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
        self.persistedID = persistedID
        self.transactionID = transactionID
        self.syncID = syncID
        self.position = position
        self.lastModified = lastModified
    }
}

struct ParsedReceipt: Codable, Sendable {
    let storeName: String?
    let date: String?
    let items: [ReceiptItem]
    let totalAmount: Double?
    let currency: String?

    enum CodingKeys: String, CodingKey {
        case storeName, date, items, totalAmount, currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        storeName = try? container.decode(String.self, forKey: .storeName)
        date = try? container.decode(String.self, forKey: .date)
        currency = try? container.decode(String.self, forKey: .currency)
        totalAmount = (try? container.decode(FlexibleDouble.self, forKey: .totalAmount))?.value

        let rawItems = (try? container.decode([ReceiptItem].self, forKey: .items)) ?? []
        // Filter out garbage items with no valid price
        items = rawItems.filter { $0.isUsable }
    }

    /// Direct initializer for heuristic construction (no decoding).
    init(storeName: String?, date: String?, items: [ReceiptItem], totalAmount: Double?, currency: String?) {
        self.storeName = storeName
        self.date = date
        self.items = items
        self.totalAmount = totalAmount
        self.currency = currency
    }
}

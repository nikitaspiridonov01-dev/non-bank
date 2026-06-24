import Foundation

/// Envelope written by `ExportTransactionsView` and read by the
/// auto-import path in `ImportTransactionsView`. Carries everything
/// needed for a lossless round-trip of a non-bank export:
///   - the transactions themselves (with `splitInfo`, recurrence,
///     `excludedFromInsights`, etc.),
///   - the `Friend` records referenced by any `splitInfo.friends[]`
///     (so split rows still show real names on a fresh device),
///   - the receipt items belonging to any exported transaction (so a
///     `splitMode = .byItems` row keeps its line-by-line detail).
///
/// The presence of the top-level `transactions` key — alongside a
/// matching `schemaVersion` — is what the importer keys off to skip
/// the manual field-mapping wizard. Files without this shape go
/// through the existing manual flow.
struct NonBankExport: Codable {
    /// Bumped whenever the envelope shape changes in a way that older
    /// clients couldn't safely consume. Current readers accept `1`.
    let schemaVersion: Int
    let exportedAt: Date
    let transactions: [Transaction]
    let friends: [Friend]
    let receiptItems: [ExportedReceiptItem]

    static let currentSchemaVersion = 1
}

/// Receipt-item payload used inside `NonBankExport`. Distinct from the
/// `ReceiptItem` `Codable` contract because:
///   - `ReceiptItem.CodingKeys` only encodes `name/quantity/price/total`
///     (that contract is shared with the OCR/LLM input format and
///     mustn't grow), so we'd otherwise lose ordering, assignments,
///     and the parent-transaction link.
///   - The parent link is stored as `transactionID: Int` locally, but
///     local autoincrement IDs don't survive a re-import. We key by
///     `transactionSyncID` instead — stable across devices.
struct ExportedReceiptItem: Codable {
    let transactionSyncID: String
    let name: String
    let quantity: Double?
    let price: Double?
    let total: Double?
    let assignedParticipantIDs: [String]
    let syncID: String
    let position: Int
    let lastModified: Date
    /// Stored kind override (manual tips). Optional so backups written
    /// before this field — and rows that never had a forced kind — decode
    /// cleanly to `nil` (= name-based classification on re-import).
    let forcedKind: ReceiptItem.Kind?

    init(from item: ReceiptItem, transactionSyncID: String) {
        self.transactionSyncID = transactionSyncID
        self.name = item.name
        self.quantity = item.quantity
        self.price = item.price
        self.total = item.total
        self.assignedParticipantIDs = item.assignedParticipantIDs
        self.syncID = item.syncID
        self.position = item.position
        self.lastModified = item.lastModified
        self.forcedKind = item.forcedKind
    }

    /// Rebuild a `ReceiptItem` for persistence. `transactionID` is left
    /// `nil` — the importer fills it in after the parent transaction is
    /// inserted and its new autoincrement ID is known.
    func toReceiptItem() -> ReceiptItem {
        ReceiptItem(
            name: name,
            quantity: quantity,
            price: price,
            total: total,
            assignedParticipantIDs: assignedParticipantIDs,
            persistedID: nil,
            transactionID: nil,
            syncID: syncID,
            position: position,
            lastModified: lastModified,
            forcedKind: forcedKind
        )
    }
}

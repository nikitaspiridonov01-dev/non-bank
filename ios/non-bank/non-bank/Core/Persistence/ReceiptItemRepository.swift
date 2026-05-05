import Foundation

/// Protocol for receipt-item data access.
protocol ReceiptItemRepositoryProtocol {
    func fetchAll() async -> [ReceiptItem]
    func fetch(transactionID: Int) async -> [ReceiptItem]
    /// Inserts the items as a batch and returns the same list with
    /// `persistedID` populated. Caller is responsible for setting
    /// `transactionID` before calling.
    func insertBatch(_ items: [ReceiptItem]) async -> [ReceiptItem]
    func update(_ item: ReceiptItem) async
    func delete(id: Int) async
    /// Cascade-style delete used when the parent transaction is removed.
    func deleteAll(transactionID: Int) async
}

/// Production implementation backed by `DatabaseProtocol`.
final class ReceiptItemRepository: ReceiptItemRepositoryProtocol {
    private let db: DatabaseProtocol

    init(db: DatabaseProtocol = SQLiteService.shared) {
        self.db = db
    }

    func fetchAll() async -> [ReceiptItem] {
        await db.fetchAllReceiptItems()
    }

    func fetch(transactionID: Int) async -> [ReceiptItem] {
        await db.fetchReceiptItems(transactionID: transactionID)
    }

    func insertBatch(_ items: [ReceiptItem]) async -> [ReceiptItem] {
        await db.insertReceiptItems(items)
    }

    func update(_ item: ReceiptItem) async {
        await db.updateReceiptItem(item)
    }

    func delete(id: Int) async {
        await db.deleteReceiptItem(id: id)
    }

    func deleteAll(transactionID: Int) async {
        await db.deleteReceiptItems(transactionID: transactionID)
    }
}

import Foundation

/// Protocol for transaction data access.
protocol TransactionRepositoryProtocol {
    func fetchAll() async -> [Transaction]
    func insert(_ transaction: Transaction) async
    func insertBatch(_ transactions: [Transaction]) async
    func update(_ transaction: Transaction) async
    func delete(id: Int) async
    func deleteAll() async
}

/// Production implementation backed by DatabaseProtocol.
final class TransactionRepository: TransactionRepositoryProtocol {
    private let db: DatabaseProtocol

    init(db: DatabaseProtocol = SQLiteService.shared) {
        self.db = db
    }

    func fetchAll() async -> [Transaction] {
        await db.fetchAllTransactions()
    }

    func insert(_ transaction: Transaction) async {
        await db.insertTransaction(transaction)
    }

    func insertBatch(_ transactions: [Transaction]) async {
        await db.insertTransactions(transactions)
    }

    func update(_ transaction: Transaction) async {
        await db.updateTransaction(transaction)
    }

    func delete(id: Int) async {
        await db.deleteTransaction(id: id)
    }

    func deleteAll() async {
        await db.deleteAllTransactions()
    }
}

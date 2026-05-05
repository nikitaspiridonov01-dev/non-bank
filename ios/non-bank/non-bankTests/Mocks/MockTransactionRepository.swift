import Foundation
@testable import non_bank

final class MockTransactionRepository: TransactionRepositoryProtocol, @unchecked Sendable {
    var transactions: [Transaction] = []
    private(set) var insertCallCount = 0
    private(set) var insertBatchCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0
    private(set) var deleteAllCallCount = 0

    func fetchAll() async -> [Transaction] { transactions }

    func insert(_ transaction: Transaction) async {
        insertCallCount += 1
        transactions.append(transaction)
    }

    func insertBatch(_ newTransactions: [Transaction]) async {
        insertBatchCallCount += 1
        transactions.append(contentsOf: newTransactions)
    }

    func update(_ transaction: Transaction) async {
        updateCallCount += 1
        if let idx = transactions.firstIndex(where: { $0.id == transaction.id }) {
            transactions[idx] = transaction
        }
    }

    func delete(id: Int) async {
        deleteCallCount += 1
        transactions.removeAll { $0.id == id }
    }

    func deleteAll() async {
        deleteAllCallCount += 1
        transactions.removeAll()
    }
}

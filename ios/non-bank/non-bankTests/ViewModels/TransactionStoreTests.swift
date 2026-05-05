import XCTest
@testable import non_bank

@MainActor
final class TransactionStoreTests: XCTestCase {

    private var mockRepo: MockTransactionRepository!

    override func setUp() {
        super.setUp()
        mockRepo = MockTransactionRepository()
    }

    // MARK: - Load

    func testLoad_fetchesFromRepo() async {
        let tx = TestFixtures.makeTransaction()
        mockRepo.transactions = [tx]

        let store = TransactionStore(repo: mockRepo)
        // Wait for the Task in init to complete
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.transactions.count, 1)
        XCTAssertEqual(store.transactions.first?.id, tx.id)
    }

    // MARK: - Add

    func testAdd_insertsAndReloads() async {
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        let tx = TestFixtures.makeTransaction(id: 1)
        store.add(tx)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockRepo.insertCallCount, 1)
        XCTAssertEqual(store.transactions.count, 1)
    }

    // MARK: - AddBatch

    func testAddBatch_insertsBatchAndReloads() async {
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        let txs = [
            TestFixtures.makeTransaction(id: 1),
            TestFixtures.makeTransaction(id: 2),
        ]
        store.addBatch(txs)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockRepo.insertBatchCallCount, 1)
        XCTAssertEqual(store.transactions.count, 2)
    }

    // MARK: - Update

    func testUpdate_updatesAndReloads() async {
        let original = TestFixtures.makeTransaction(id: 1, title: "Old")
        mockRepo.transactions = [original]
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        let updated = TestFixtures.makeTransaction(id: 1, title: "New")
        store.update(updated)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockRepo.updateCallCount, 1)
        XCTAssertEqual(store.transactions.first?.title, "New")
    }

    // MARK: - Delete

    func testDelete_removesAndReloads() async {
        let tx = TestFixtures.makeTransaction(id: 1)
        mockRepo.transactions = [tx]
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        store.delete(id: 1)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockRepo.deleteCallCount, 1)
        XCTAssertTrue(store.transactions.isEmpty)
    }

    // MARK: - DeleteAll

    func testDeleteAll_clearsAndReloads() async {
        mockRepo.transactions = [
            TestFixtures.makeTransaction(id: 1),
            TestFixtures.makeTransaction(id: 2),
        ]
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        store.deleteAll()
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(mockRepo.deleteAllCallCount, 1)
        XCTAssertTrue(store.transactions.isEmpty)
    }
}

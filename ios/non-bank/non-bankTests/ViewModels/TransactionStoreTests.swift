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

    // MARK: - Add idempotency (duplicate-on-bad-network guard)

    /// A logical save committed twice with the SAME `syncID` (UI
    /// re-entrancy / retry on a slow network) must yield ONE row — the
    /// second commit updates the existing row in place instead of
    /// inserting a duplicate. This is the store-level backstop behind the
    /// modal's re-entry guard + stable in-flight syncID.
    func testAdd_sameSyncID_doesNotDuplicate() async {
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        // Both commits share one stable syncID — they represent the same
        // logical save (the repro: 9 identical split rows from re-taps).
        let syncID = "stable-sync-id"
        let base = TestFixtures.makeTransaction(id: 1, title: "Beograd – Čukarica")
        let tx1 = makeWithSyncID(base, syncID: syncID)
        let tx2 = makeWithSyncID(base, syncID: syncID)

        store.add(tx1)
        try? await Task.sleep(for: .milliseconds(50))
        store.add(tx2)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(store.transactions.count, 1, "Double-commit of one save must not duplicate")
        XCTAssertEqual(mockRepo.insertCallCount, 1, "Second commit should update, not insert")
        XCTAssertEqual(mockRepo.updateCallCount, 1)
    }

    /// `addAndReturnID` (the receipt-scan create path) must apply the same
    /// idempotency: a re-commit of the same `syncID` returns the SAME row
    /// id rather than minting a second row.
    func testAddAndReturnID_sameSyncID_returnsSameRow() async {
        let store = TransactionStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(50))

        let syncID = "scan-sync-id"
        let tx1 = makeWithSyncID(TestFixtures.makeTransaction(id: 5), syncID: syncID)
        let tx2 = makeWithSyncID(TestFixtures.makeTransaction(id: 0), syncID: syncID)

        let firstID = await store.addAndReturnID(tx1)
        let secondID = await store.addAndReturnID(tx2)

        XCTAssertEqual(store.transactions.count, 1, "Double-commit must not duplicate")
        XCTAssertNotNil(firstID)
        XCTAssertEqual(firstID, secondID, "Both commits must resolve to the same row id")
        XCTAssertEqual(mockRepo.insertCallCount, 1)
    }

    /// Re-stamp a fixture transaction with an explicit `syncID` while
    /// preserving every other field — `TestFixtures.makeTransaction`
    /// mints a random syncID, so we override it here for dedup tests.
    private func makeWithSyncID(_ tx: Transaction, syncID: String) -> Transaction {
        Transaction(
            id: tx.id,
            syncID: syncID,
            emoji: tx.emoji,
            category: tx.category,
            title: tx.title,
            description: tx.description,
            amount: tx.amount,
            currency: tx.currency,
            date: tx.date,
            type: tx.type,
            tags: tx.tags,
            lastModified: tx.lastModified,
            repeatInterval: tx.repeatInterval,
            parentReminderID: tx.parentReminderID,
            splitInfo: tx.splitInfo,
            payloadChecksum: tx.payloadChecksum,
            excludedFromInsights: tx.excludedFromInsights
        )
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

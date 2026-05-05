import XCTest
@testable import non_bank

@MainActor
final class NavigationRouterTests: XCTestCase {

    private var sut: NavigationRouter!

    override func setUp() {
        super.setUp()
        sut = NavigationRouter()
    }

    // MARK: - Create Transaction

    func testShowCreateTransaction() {
        sut.showCreateTransaction()
        XCTAssertTrue(sut.showTransactionEditor)
        XCTAssertNil(sut.editingTransaction)
    }

    // MARK: - Edit Transaction

    func testShowEditTransaction() {
        let tx = TestFixtures.makeTransaction()
        sut.showEditTransaction(tx)
        XCTAssertTrue(sut.showTransactionEditor)
        XCTAssertEqual(sut.editingTransaction?.id, tx.id)
    }

    // MARK: - Dismiss

    func testDismissTransactionEditor() {
        sut.showCreateTransaction()
        sut.dismissTransactionEditor()
        XCTAssertFalse(sut.showTransactionEditor)
        XCTAssertNil(sut.editingTransaction)
    }

    // MARK: - Import Success

    func testShowImportComplete() {
        sut.showImportComplete(count: 42)
        XCTAssertTrue(sut.showImportSuccess)
        XCTAssertEqual(sut.importedCount, 42)
    }

    // MARK: - Default State

    func testDefaultState() {
        XCTAssertEqual(sut.selectedTab, 0)
        XCTAssertFalse(sut.hideTabBar)
        XCTAssertFalse(sut.showTransactionEditor)
        XCTAssertNil(sut.editingTransaction)
        XCTAssertFalse(sut.showImportSuccess)
        XCTAssertEqual(sut.importedCount, 0)
    }
}

import XCTest
@testable import non_bank

/// Tests for `ReceiptItemController` — the extracted owner of the
/// create-transaction receipt-item state. Covers the
/// paid-extra-placeholder reconciliation that previously lived on
/// `CreateTransactionViewModel` and had no unit tests at all (the
/// only safety net was a manual exceed-confirm walk on device).
///
/// `@MainActor` mirrors the controller's actor isolation — the SUT
/// type is `@MainActor`, so test methods that mutate its state need
/// to run on the main actor as well. Using a stored `sut` plus
/// `setUp`/`tearDown` (rather than a fresh instance per test body)
/// matches the pattern in `CreateTransactionViewModelTests` and
/// avoids the cold-start crash that hit when tests constructed the
/// instance inline as the very first statement.
@MainActor
final class ReceiptItemControllerTests: XCTestCase {

    private var sut: ReceiptItemController!

    override func setUp() {
        super.setUp()
        sut = ReceiptItemController()
    }

    override func tearDown() {
        sut = nil
        super.tearDown()
    }

    private func makeItem(name: String, total: Double) -> ReceiptItem {
        ReceiptItem(name: name, quantity: nil, price: nil, total: total)
    }

    // MARK: - replaceAll / clear

    func testReplaceAll_replacesItems() {
        sut.items = [makeItem(name: "Initial", total: 1)]
        sut.replaceAll([
            makeItem(name: "Burger", total: 10),
            makeItem(name: "Fries", total: 5),
        ])
        XCTAssertEqual(sut.items.map(\.name), ["Burger", "Fries"])
    }

    func testClear_dropsEverything() {
        sut.items = [makeItem(name: "Burger", total: 10)]
        sut.clear()
        XCTAssertTrue(sut.items.isEmpty)
    }

    // MARK: - isPaidExtraItem name matching

    func testIsPaidExtraItem_recognisesUserBareName() {
        XCTAssertTrue(ReceiptItemController.isPaidExtraItem(makeItem(name: "Extra", total: 1)))
    }

    func testIsPaidExtraItem_recognisesFriendPossessiveSuffix() {
        XCTAssertTrue(ReceiptItemController.isPaidExtraItem(makeItem(name: "Michael's extra", total: 1)))
        XCTAssertTrue(ReceiptItemController.isPaidExtraItem(makeItem(name: "Анна's extra", total: 1)))
    }

    func testIsPaidExtraItem_rejectsNormalItems() {
        XCTAssertFalse(ReceiptItemController.isPaidExtraItem(makeItem(name: "Burger", total: 10)))
        XCTAssertFalse(ReceiptItemController.isPaidExtraItem(makeItem(name: "Extra cheese", total: 1)))
        XCTAssertFalse(ReceiptItemController.isPaidExtraItem(makeItem(name: "extras", total: 1)))
    }

    // MARK: - reconcilePaidExtra — happy paths

    func testReconcile_excessOverItems_appendsPlaceholder_forSelf() {
        sut.items = [
            makeItem(name: "Burger", total: 10),
            makeItem(name: "Fries", total: 5),
        ]
        // I paid 20 — items sum to 15, so a 5.00 extra placeholder.
        sut.reconcilePaidExtra(payerName: "You", newTotal: 20)
        XCTAssertEqual(sut.items.count, 3)
        let extra = sut.items.last!
        XCTAssertEqual(extra.name, "Extra", "Self placeholder must use bare 'Extra' name (no possessive)")
        XCTAssertEqual(extra.lineTotal, 5, accuracy: 0.001)
    }

    func testReconcile_excessOverItems_appendsPlaceholder_forFriend() {
        sut.items = [makeItem(name: "Pizza", total: 30)]
        sut.reconcilePaidExtra(payerName: "Michael", newTotal: 50)
        XCTAssertEqual(sut.items.count, 2)
        XCTAssertEqual(sut.items.last?.name, "Michael's extra")
        XCTAssertEqual(sut.items.last?.lineTotal ?? 0, 20, accuracy: 0.001)
    }

    func testReconcile_belowTotal_removesStalePlaceholder() {
        sut.items = [
            makeItem(name: "Burger", total: 10),
            makeItem(name: "Extra", total: 5),
        ]
        // newTotal lands exactly at the non-placeholder sum — placeholder
        // is stale and must be removed.
        sut.reconcilePaidExtra(payerName: "You", newTotal: 10)
        XCTAssertEqual(sut.items.map(\.name), ["Burger"])
    }

    func testReconcile_idempotentOnRepeatedConfirm() {
        sut.items = [makeItem(name: "Pizza", total: 30)]
        sut.reconcilePaidExtra(payerName: "Michael", newTotal: 50)
        let firstCount = sut.items.count
        let firstExtra = sut.items.last!.lineTotal
        // Re-confirming with the same numbers must NOT stack placeholders.
        sut.reconcilePaidExtra(payerName: "Michael", newTotal: 50)
        XCTAssertEqual(sut.items.count, firstCount)
        XCTAssertEqual(sut.items.last?.lineTotal ?? 0, firstExtra, accuracy: 0.001)
    }

    func testReconcile_updatesPlaceholderInPlace_preservingSyncID() {
        sut.items = [makeItem(name: "Pizza", total: 30)]
        sut.reconcilePaidExtra(payerName: "Michael", newTotal: 50)
        let initialSyncID = sut.items.last!.syncID
        // Different amount and different payer — placeholder updates
        // in place, syncID stays so SQLite treats this as an edit.
        sut.reconcilePaidExtra(payerName: "Anna", newTotal: 60)
        XCTAssertEqual(sut.items.count, 2)
        XCTAssertEqual(sut.items.last?.name, "Anna's extra")
        XCTAssertEqual(sut.items.last?.lineTotal ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(sut.items.last?.syncID, initialSyncID,
                       "syncID must survive in-place update")
    }

    // MARK: - reconcilePaidExtra — edge cases

    func testReconcile_emptyItems_noOp() {
        // Defensive guard — caller shouldn't invoke with empty items,
        // but if they do, nothing should change.
        sut.reconcilePaidExtra(payerName: "You", newTotal: 100)
        XCTAssertTrue(sut.items.isEmpty)
    }

    func testReconcile_floatNoiseUnderTolerance_doesNotCreatePlaceholder() {
        // 0.001 excess shouldn't trigger a "0.001 Extra" row — matches
        // the editor's exactMatchEpsilon (0.005).
        sut.items = [makeItem(name: "Burger", total: 10.0)]
        sut.reconcilePaidExtra(payerName: "You", newTotal: 10.001)
        XCTAssertEqual(sut.items.count, 1, "Sub-epsilon excess must NOT add placeholder")
    }

    func testReconcile_clearsAssignmentsOnAllItems() {
        // After upserting a placeholder, every item's
        // `assignedParticipantIDs` must reset so the UI re-prompts
        // for assignment. Previous assignees may be stale (different
        // exceeder, different shape).
        var preAssigned = makeItem(name: "Burger", total: 10)
        preAssigned.assignedParticipantIDs = ["friend-a"]
        sut.items = [preAssigned]
        sut.reconcilePaidExtra(payerName: "Michael", newTotal: 20)
        for item in sut.items {
            XCTAssertTrue(
                item.assignedParticipantIDs.isEmpty,
                "Placeholder reconciliation must wipe assignments on every row"
            )
        }
    }
}

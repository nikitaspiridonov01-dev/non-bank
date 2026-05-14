import XCTest
@testable import non_bank

final class SplitShareCalculatorTests: XCTestCase {

    // MARK: - Helpers

    private func makeItem(
        name: String = "Item",
        total: Double,
        assignees: [String] = []
    ) -> ReceiptItem {
        ReceiptItem(
            name: name,
            quantity: nil,
            price: nil,
            total: total,
            assignedParticipantIDs: assignees
        )
    }

    // MARK: - Direct-item distribution (Pass 1)

    func testCompute_singleAssigneePerItem_attributesFullLineTotal() {
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 20, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 10, accuracy: 0.001)
    }

    func testCompute_multipleAssignees_splitsItemEqually() {
        // Shared appetizer between two participants → each gets half.
        let items = [makeItem(name: "Cheese plate", total: 30, assignees: ["alice", "bob"])]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob", "carol"]
        )
        XCTAssertEqual(result["alice"]!, 15, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 15, accuracy: 0.001)
        XCTAssertEqual(result["carol"]!, 0, accuracy: 0.001)
    }

    func testCompute_unassignedItems_contributeToNobody() {
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Stray dessert", total: 8, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 20, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 0, accuracy: 0.001)
    }

    func testCompute_assigneesOutsideParticipantSet_areIgnored() {
        // Defensive: if assignments still reference a removed participant,
        // we drop them rather than crashing or attributing silently.
        let items = [makeItem(name: "Pizza", total: 30, assignees: ["alice", "ghost"])]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        // Only Alice is a real participant → she gets the whole item.
        XCTAssertEqual(result["alice"]!, 30, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 0, accuracy: 0.001)
    }

    // MARK: - Proportional charges (Pass 2)

    func testCompute_taxDistributedProportionalToItemShare() {
        // Alice took $20 of direct items, Bob took $10 → tax proportion is 2:1.
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"]),
            makeItem(name: "VAT", total: 3, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 22, accuracy: 0.001, "Alice: 20 + 3 × (20/30) = 22")
        XCTAssertEqual(result["bob"]!, 11, accuracy: 0.001, "Bob: 10 + 3 × (10/30) = 11")
    }

    func testCompute_tipDistributedProportional() {
        let items = [
            makeItem(name: "Burger", total: 15, assignees: ["alice"]),
            makeItem(name: "Salad", total: 10, assignees: ["bob"]),
            makeItem(name: "Tip", total: 5, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 18, accuracy: 0.001, "Alice: 15 + 5 × (15/25) = 18")
        XCTAssertEqual(result["bob"]!, 12, accuracy: 0.001, "Bob: 10 + 5 × (10/25) = 12")
    }

    func testCompute_feeDistributedProportional() {
        let items = [
            makeItem(name: "Drink", total: 8, assignees: ["alice"]),
            makeItem(name: "Drink", total: 8, assignees: ["bob"]),
            makeItem(name: "Service fee", total: 4, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 10, accuracy: 0.001, "Alice: 8 + 4 × 0.5 = 10")
        XCTAssertEqual(result["bob"]!, 10, accuracy: 0.001, "Bob: 8 + 4 × 0.5 = 10")
    }

    func testCompute_discountDistributedProportional_isNegative() {
        // Discount applies as negative line total → reduces shares
        // proportionally.
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"]),
            makeItem(name: "Discount", total: -3, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 18, accuracy: 0.001, "Alice: 20 - 3 × (20/30) = 18")
        XCTAssertEqual(result["bob"]!, 9, accuracy: 0.001, "Bob: 10 - 3 × (10/30) = 9")
    }

    func testCompute_skippedParticipant_excludedFromCharges() {
        // Carol took no items → her share is 0 → she gets none of the
        // tax (TZ: skipped participants are excluded from tax/fees).
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"]),
            makeItem(name: "Tax", total: 3, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob", "carol"]
        )
        XCTAssertEqual(result["alice"]!, 22, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 11, accuracy: 0.001)
        XCTAssertEqual(result["carol"]!, 0, accuracy: 0.001)
    }

    // MARK: - Edge cases

    func testCompute_emptyParticipants_returnsEmpty() {
        let items = [makeItem(name: "Pizza", total: 20, assignees: ["alice"])]
        let result = SplitShareCalculator.compute(items: items, participants: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testCompute_emptyItems_zeroShares() {
        let result = SplitShareCalculator.compute(
            items: [],
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 0, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 0, accuracy: 0.001)
    }

    func testCompute_onlyChargesNoItems_zeroShares() {
        // No direct items → no proportional base → charges have no
        // denominator. Shares stay at zero (the UI should never let
        // this state reach the calculator anyway).
        let items = [
            makeItem(name: "Tax", total: 3, assignees: []),
            makeItem(name: "Tip", total: 2, assignees: [])
        ]
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        XCTAssertEqual(result["alice"]!, 0, accuracy: 0.001)
        XCTAssertEqual(result["bob"]!, 0, accuracy: 0.001)
    }

    func testCompute_sumOfShares_approximatesItemsTotal() {
        // Sanity: result should cover the whole receipt (within
        // floating-point arithmetic). Mixed real-world receipt — the
        // charge names are picked to hit `ReceiptLineFilter`'s
        // classifier verbatim ("VAT" → .tax, "Tip" → .tip), since
        // anything that classifies as `.item` without assignees would
        // be silently lost (regular items aren't auto-redistributed
        // when nobody claimed them — that's a user-warning case at
        // save time, not the calculator's job to paper over).
        let items = [
            makeItem(name: "Pizza", total: 18.50, assignees: ["alice"]),
            makeItem(name: "Pasta", total: 14.00, assignees: ["bob"]),
            makeItem(name: "Wine", total: 22.00, assignees: ["alice", "bob"]),
            makeItem(name: "VAT 20%", total: 10.90, assignees: []),
            makeItem(name: "Tip", total: 5.00, assignees: []),
            makeItem(name: "Discount", total: -3.00, assignees: [])
        ]
        let receiptTotal = items.reduce(0) { $0 + $1.lineTotal }
        let result = SplitShareCalculator.compute(
            items: items,
            participants: ["alice", "bob"]
        )
        let resultSum = result.values.reduce(0, +)
        XCTAssertEqual(resultSum, receiptTotal, accuracy: 0.01)
    }
}

import XCTest
@testable import non_bank

/// Verifies `SplitItemBreakdown` stays bit-for-bit reconciled with
/// `SplitShareCalculator` (the persisted source of truth) and exposes the
/// per-item slices + per-kind charge cuts the new split UI needs.
final class SplitItemBreakdownTests: XCTestCase {

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

    /// The contract that matters most: each participant's breakdown total
    /// equals their `SplitShareCalculator` share, across a representative
    /// receipt (multi-assignee item + fee + tip + discount + a skipped
    /// participant).
    func testTotals_reconcileWithSplitShareCalculator() {
        let items = [
            makeItem(name: "Pizza", total: 18.50, assignees: ["alice"]),
            makeItem(name: "Pasta", total: 14.00, assignees: ["bob"]),
            makeItem(name: "Wine", total: 22.00, assignees: ["alice", "bob"]),
            makeItem(name: "Service fee", total: 5.00, assignees: []),
            makeItem(name: "Tip", total: 5.00, assignees: []),
            makeItem(name: "Discount", total: -3.00, assignees: [])
        ]
        let participants: Set<String> = ["alice", "bob", "carol"]

        let truth = SplitShareCalculator.compute(items: items, participants: participants)
        let breakdown = SplitItemBreakdown.compute(items: items, participants: participants)

        for id in participants {
            XCTAssertEqual(
                breakdown[id]!.total, truth[id]!, accuracy: 0.0001,
                "Breakdown total for \(id) must match SplitShareCalculator"
            )
        }
    }

    func testItemSlices_equalSplitAmongCoAssignees() {
        let items = [makeItem(name: "Cheese plate", total: 30, assignees: ["alice", "bob"])]
        let breakdown = SplitItemBreakdown.compute(
            items: items, participants: ["alice", "bob", "carol"]
        )
        XCTAssertEqual(breakdown["alice"]!.items.count, 1)
        XCTAssertEqual(breakdown["alice"]!.items[0].slice, 15, accuracy: 0.001)
        XCTAssertEqual(breakdown["bob"]!.items[0].slice, 15, accuracy: 0.001)
        // Carol took nothing — no item rows, no charge rows, zero total.
        XCTAssertTrue(breakdown["carol"]!.items.isEmpty)
        XCTAssertTrue(breakdown["carol"]!.charges.isEmpty)
        XCTAssertEqual(breakdown["carol"]!.total, 0, accuracy: 0.001)
    }

    func testCharges_splitByKind_sumMatchesAggregate() {
        // Alice $20 direct, Bob $10 direct → 2:1 proportion.
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"]),
            makeItem(name: "Service fee", total: 3, assignees: []),
            makeItem(name: "Tip", total: 6, assignees: []),
            makeItem(name: "Discount", total: -3, assignees: [])
        ]
        let breakdown = SplitItemBreakdown.compute(items: items, participants: ["alice", "bob"])

        let alice = breakdown["alice"]!
        // Alice's proportion = 20/30. fee 3→2, tip 6→4, discount -3→-2.
        let fee = alice.charges.first { $0.kind == .fee }!
        let tip = alice.charges.first { $0.kind == .tip }!
        let discount = alice.charges.first { $0.kind == .discount }!
        XCTAssertEqual(fee.amount, 2, accuracy: 0.001)
        XCTAssertEqual(tip.amount, 4, accuracy: 0.001)
        XCTAssertEqual(discount.amount, -2, accuracy: 0.001)
        // Charge rows are ordered fee, tip, discount.
        XCTAssertEqual(alice.charges.map { $0.kind }, [.fee, .tip, .discount])
        // Item slice (20) + charge cuts (2+4-2=4) = 24.
        XCTAssertEqual(alice.total, 24, accuracy: 0.001)
    }

    func testClaimants_returnsAllAssigneesWithEqualSlice() {
        let item = makeItem(name: "Wine", total: 30, assignees: ["alice", "bob", "ghost"])
        let claimants = SplitItemBreakdown.claimants(of: item, participants: ["alice", "bob"])
        // ghost is outside the roster → dropped; 30/2 = 15 each.
        XCTAssertEqual(claimants.count, 2)
        XCTAssertEqual(Set(claimants.map { $0.participantID }), ["alice", "bob"])
        for c in claimants { XCTAssertEqual(c.slice, 15, accuracy: 0.001) }
    }

    func testClaimants_nonItemKind_isEmpty() {
        let fee = makeItem(name: "Service fee", total: 4, assignees: [])
        XCTAssertTrue(SplitItemBreakdown.claimants(of: fee, participants: ["alice"]).isEmpty)
    }

    func testNoCharges_onlyItemRows() {
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"])
        ]
        let breakdown = SplitItemBreakdown.compute(items: items, participants: ["alice", "bob"])
        XCTAssertTrue(breakdown["alice"]!.charges.isEmpty)
        XCTAssertEqual(breakdown["alice"]!.total, 20, accuracy: 0.001)
    }

    /// `chargeDistribution` (drives the per-adjustment tap sheet) splits one
    /// charge LINE proportionally and reconciles to the line total.
    func testChargeDistribution_proportionalPerLine_reconciles() {
        let items = [
            makeItem(name: "Pizza", total: 20, assignees: ["alice"]),
            makeItem(name: "Beer", total: 10, assignees: ["bob"]),
            makeItem(name: "Service fee", total: 3, assignees: []),
            makeItem(name: "Discount", total: -3, assignees: [])
        ]
        let participants: Set<String> = ["alice", "bob"]

        let fee = items.first { $0.kind == .fee }!
        let dist = SplitItemBreakdown.chargeDistribution(of: fee, items: items, participants: participants)
        let byID = Dictionary(uniqueKeysWithValues: dist.map { ($0.participantID, $0.amount) })
        // Alice 20/30, Bob 10/30 → fee 3 → 2 / 1; sum == line total.
        XCTAssertEqual(byID["alice"]!, 2, accuracy: 0.001)
        XCTAssertEqual(byID["bob"]!, 1, accuracy: 0.001)
        XCTAssertEqual(dist.reduce(0) { $0 + $1.amount }, 3, accuracy: 0.001)

        // A discount line stays negative and reconciles too.
        let discount = items.first { $0.kind == .discount }!
        let ddist = SplitItemBreakdown.chargeDistribution(of: discount, items: items, participants: participants)
        XCTAssertEqual(ddist.reduce(0) { $0 + $1.amount }, -3, accuracy: 0.001)

        // An item row has no proportional distribution.
        let pizza = items.first { $0.kind == .item }!
        XCTAssertTrue(SplitItemBreakdown.chargeDistribution(of: pizza, items: items, participants: participants).isEmpty)
    }
}

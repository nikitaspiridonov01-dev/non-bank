import XCTest
@testable import non_bank

/// Tests for `SplitMathHelpers.resolveStoredSplitMode` — the
/// pure helper that decides whether a saved split should be tagged as
/// `.settleUp` based on its data shape, regardless of which mode the
/// user picked first in the create flow.
final class SplitModeCoercionTests: XCTestCase {

    private func friend(id: String, share: Double, paid: Double = 0) -> FriendShare {
        FriendShare(friendID: id, share: share, paidAmount: paid)
    }

    // MARK: - Coerces to settleUp

    func testCoerce_iPaidAll_friendOwesAll_isSettleUp() {
        // Classic "I covered Michael's coffee" — picked evenly, but
        // ended up with me paying 100% and Michael owing 100%.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .evenly,
            paidByMe: 30,
            myShare: 0,
            friends: [friend(id: "michael", share: 30, paid: 0)]
        )
        XCTAssertEqual(mode, .settleUp)
    }

    func testCoerce_friendPaidAll_iOweAll_isSettleUp() {
        // Inverse: Michael covered for me. paidByMe = 0, myShare =
        // total, Michael's share = 0, paidAmount = total.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .byAmount,
            paidByMe: 0,
            myShare: 30,
            friends: [friend(id: "michael", share: 0, paid: 30)]
        )
        XCTAssertEqual(mode, .settleUp)
    }

    func testCoerce_explicitSettleUp_staysSettleUp() {
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .settleUp,
            paidByMe: 30,
            myShare: 0,
            friends: [friend(id: "michael", share: 30, paid: 0)]
        )
        XCTAssertEqual(mode, .settleUp)
    }

    // MARK: - Stays as requested

    func testCoerce_evenlySplit_twoParticipantsBoth5050_staysEvenly() {
        // I paid 30, but the split is 50/50 → 2 share-bearers → not
        // settle-up.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .evenly,
            paidByMe: 30,
            myShare: 15,
            friends: [friend(id: "michael", share: 15, paid: 0)]
        )
        XCTAssertEqual(mode, .evenly)
    }

    func testCoerce_threePartySplit_evenly_staysEvenly() {
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .evenly,
            paidByMe: 60,
            myShare: 20,
            friends: [
                friend(id: "michael", share: 20, paid: 0),
                friend(id: "anna", share: 20, paid: 0)
            ]
        )
        XCTAssertEqual(mode, .evenly)
    }

    func testCoerce_twoPayersOneShareBearer_staysAsRequested() {
        // Split with 2 payers (rare) — not 1 payer, not settle-up.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .byAmount,
            paidByMe: 15,
            myShare: 0,
            friends: [
                friend(id: "michael", share: 30, paid: 15),
                friend(id: "anna", share: 0, paid: 0)
            ]
        )
        XCTAssertEqual(mode, .byAmount)
    }

    func testCoerce_iPaidAll_iOweAll_isNotSettleUp() {
        // Degenerate single-person split (1 payer = me, 1 share-bearer
        // = me). The user shouldn't have flagged this as split, but if
        // they did, it's not a settle-up either — both sides are the
        // same party, so there's nothing to "settle".
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .evenly,
            paidByMe: 30,
            myShare: 30,
            friends: []
        )
        XCTAssertEqual(mode, .evenly)
    }

    func testCoerce_friendPaidAndOwes_singlePartySamePerson_isNotSettleUp() {
        // Same degenerate case but for a friend: one friend both paid
        // and bears the share. Not a settle-up because there's no
        // counter-party.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: .evenly,
            paidByMe: 0,
            myShare: 0,
            friends: [friend(id: "michael", share: 30, paid: 30)]
        )
        XCTAssertEqual(mode, .evenly)
    }

    func testCoerce_nilRequested_settleUpShape_returnsSettleUp() {
        // Legacy data with no recorded mode but settle-up shape →
        // upgraded to `.settleUp` by the resolver.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: nil,
            paidByMe: 30,
            myShare: 0,
            friends: [friend(id: "michael", share: 30, paid: 0)]
        )
        XCTAssertEqual(mode, .settleUp)
    }

    func testCoerce_nilRequested_normalSplitShape_returnsNil() {
        // Legacy data, normal 50/50 → nothing to coerce, stays nil.
        let mode = SplitMathHelpers.resolveStoredSplitMode(
            requested: nil,
            paidByMe: 30,
            myShare: 15,
            friends: [friend(id: "michael", share: 15, paid: 0)]
        )
        XCTAssertNil(mode)
    }
}

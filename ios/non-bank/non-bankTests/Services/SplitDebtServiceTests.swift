import XCTest
@testable import non_bank

final class SplitDebtServiceTests: XCTestCase {

    // Fixed "now" for deterministic tests: 2024-06-15 12:00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_718_452_800)
    private let pastDate = Date(timeIntervalSince1970: 1_718_452_800 - 86400) // yesterday
    private let futureDate = Date(timeIntervalSince1970: 1_718_452_800 + 86400) // tomorrow

    // Identity converter — no currency conversion
    private let identityConvert: (Double, String, String) -> Double = { amount, _, _ in amount }

    // MARK: - Helpers

    private func makeSplit(
        id: Int = 1,
        date: Date,
        paidByMe: Double,
        myShare: Double,
        friends: [FriendShare],
        currency: String = "USD",
        repeatInterval: RepeatInterval? = nil,
        parentReminderID: Int? = nil
    ) -> Transaction {
        let total = paidByMe + friends.reduce(0) { $0 + $1.paidAmount }
        let lent = max(0, paidByMe - myShare)
        let info = SplitInfo(
            totalAmount: total,
            paidByMe: paidByMe,
            myShare: myShare,
            lentAmount: lent,
            friends: friends
        )
        return TestFixtures.makeTransaction(
            id: id,
            currency: currency,
            date: date,
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: info
        )
    }

    // MARK: - simplifiedDebts: basic cases

    func testSimplifiedDebts_empty() {
        let result = SplitDebtService.simplifiedDebts(
            transactions: [],
            targetCurrency: "USD",
            convert: identityConvert,
            now: now
        )
        XCTAssertEqual(result, .empty)
    }

    func testSimplifiedDebts_iPaid_oneFriend_friendOwesMe() {
        // I paid 20, friend's share is 10 → friend owes me 10
        let tx = makeSplit(
            date: pastDate,
            paidByMe: 20,
            myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [tx], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
        XCTAssertEqual(result.rows[0].amount, 10, accuracy: 0.001)
        XCTAssertEqual(result.status, .youLent(10))
    }

    func testSimplifiedDebts_friendPaid_iOweFriend() {
        // Friend paid 20, my share is 10 → I owe friend 10
        let tx = makeSplit(
            date: pastDate,
            paidByMe: 0,
            myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 20)]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [tx], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
        XCTAssertEqual(result.rows[0].amount, -10, accuracy: 0.001)
        XCTAssertEqual(result.status, .youOwe(10))
    }

    func testSimplifiedDebts_twoFriendsBothOweMe() {
        // I paid 30, split equally 3 ways → each friend owes me 10
        let tx = makeSplit(
            date: pastDate,
            paidByMe: 30,
            myShare: 10,
            friends: [
                FriendShare(friendID: "A", share: 10, paidAmount: 0),
                FriendShare(friendID: "B", share: 10, paidAmount: 0),
            ]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [tx], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.status, .youLent(20))
        XCTAssertEqual(result.rows.first { $0.friendID == "A" }?.amount ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(result.rows.first { $0.friendID == "B" }?.amount ?? 0, 10, accuracy: 0.001)
    }

    // MARK: - simplifiedDebts: transitive minimization

    func testSimplifiedDebts_triangle_balancesOutForMeWhenIntermediary() {
        // Two txs where I'm neutral but A and B have offsetting balances.
        // Tx1: A paid 30 for herself + B's share — I observe (0 paid, 0 share).
        // Tx2: B paid 30 for himself + A's share — same.
        // Net balances: Me=0, A=0, B=0. All balance out.
        let tx1 = makeSplit(
            id: 1, date: pastDate, paidByMe: 0, myShare: 0,
            friends: [
                FriendShare(friendID: "A", share: 15, paidAmount: 30),
                FriendShare(friendID: "B", share: 15, paidAmount: 0),
            ]
        )
        let tx2 = makeSplit(
            id: 2, date: pastDate, paidByMe: 0, myShare: 0,
            friends: [
                FriendShare(friendID: "A", share: 15, paidAmount: 0),
                FriendShare(friendID: "B", share: 15, paidAmount: 30),
            ]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [tx1, tx2], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.status, .settled)
        XCTAssertEqual(result.rows.count, 2)
        // All rows should balance out (amount ≈ 0)
        for row in result.rows {
            XCTAssertEqual(row.amount, 0, accuracy: 0.001)
        }
    }

    func testSimplifiedDebts_transitiveCancellation_meOutOfMyDebts() {
        // Graph: Me=+10, A=-10, B=+5, C=-5 (unambiguous magnitudes).
        // Greedy: (Me,A) 10 then (B,C) 5 — B/C don't involve me.
        // My view: A owes me 10; B and C are "balances out" from my perspective.
        let txMeA = makeSplit(
            id: 1, date: pastDate, paidByMe: 15, myShare: 5,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        let txBC = makeSplit(
            id: 2, date: pastDate, paidByMe: 0, myShare: 0,
            friends: [
                FriendShare(friendID: "B", share: 5, paidAmount: 10),
                FriendShare(friendID: "C", share: 5, paidAmount: 0),
            ]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [txMeA, txBC], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.status, .youLent(10))
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows.first { $0.friendID == "A" }?.amount ?? 0, 10, accuracy: 0.001)
        XCTAssertEqual(result.rows.first { $0.friendID == "B" }?.amount ?? 0, 0, accuracy: 0.001)
        XCTAssertEqual(result.rows.first { $0.friendID == "C" }?.amount ?? 0, 0, accuracy: 0.001)
    }

    // MARK: - simplifiedDebts: filtering

    func testSimplifiedDebts_excludesFutureTransactions() {
        let past = makeSplit(
            id: 1, date: pastDate, paidByMe: 20, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        let future = makeSplit(
            id: 2, date: futureDate, paidByMe: 30, myShare: 10,
            friends: [
                FriendShare(friendID: "B", share: 10, paidAmount: 0),
                FriendShare(friendID: "C", share: 10, paidAmount: 0),
            ]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [past, future], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.status, .youLent(10))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
    }

    func testSimplifiedDebts_excludesRecurringParents() {
        let child = makeSplit(
            id: 1, date: pastDate, paidByMe: 20, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)],
            parentReminderID: 99
        )
        let parent = makeSplit(
            id: 2, date: pastDate, paidByMe: 30, myShare: 10,
            friends: [FriendShare(friendID: "B", share: 20, paidAmount: 0)],
            repeatInterval: .daily(hour: 9, minute: 0)
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [child, parent], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.status, .youLent(10))
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
    }

    func testSimplifiedDebts_excludesNonSplitTransactions() {
        let split = makeSplit(
            id: 1, date: pastDate, paidByMe: 20, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        let regular = TestFixtures.makeTransaction(id: 2, amount: 100, date: pastDate)
        let result = SplitDebtService.simplifiedDebts(
            transactions: [split, regular], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
    }

    // MARK: - simplifiedDebts: multi-currency

    func testSimplifiedDebts_multiCurrency_convertsToTarget() {
        // EUR transaction worth 10 EUR → 11 USD with this converter.
        // USD transaction for 5 USD directly.
        let convert: (Double, String, String) -> Double = { amount, from, to in
            if from == "EUR", to == "USD" { return amount * 1.1 }
            if from == "USD", to == "EUR" { return amount / 1.1 }
            return amount
        }
        let eurTx = makeSplit(
            id: 1, date: pastDate, paidByMe: 10, myShare: 0,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)],
            currency: "EUR"
        )
        let usdTx = makeSplit(
            id: 2, date: pastDate, paidByMe: 5, myShare: 0,
            friends: [FriendShare(friendID: "A", share: 5, paidAmount: 0)],
            currency: "USD"
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [eurTx, usdTx], targetCurrency: "USD", convert: convert, now: now
        )
        // A owes: 10 EUR (=11 USD) + 5 USD = 16 USD
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].amount, 16, accuracy: 0.001)
        XCTAssertEqual(result.status, .youLent(16))
    }

    // MARK: - simplifiedDebts: row ordering

    func testSimplifiedDebts_rowsOrderedByAbsAmount_withBalancesOutLast() {
        // A owes me 5, B owes me 20, C balances out.
        let tx = makeSplit(
            id: 1, date: pastDate, paidByMe: 25, myShare: 0,
            friends: [
                FriendShare(friendID: "A", share: 5, paidAmount: 0),
                FriendShare(friendID: "B", share: 20, paidAmount: 0),
                FriendShare(friendID: "C", share: 0, paidAmount: 0),
            ]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [tx], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.rows.count, 3)
        XCTAssertEqual(result.rows[0].friendID, "B")
        XCTAssertEqual(result.rows[1].friendID, "A")
        XCTAssertEqual(result.rows[2].friendID, "C")
        XCTAssertEqual(result.rows[2].amount, 0, accuracy: 0.001)
    }

    // MARK: - simplifiedDebts: individual friend netting

    func testSimplifiedDebts_friendBalancesOutAcrossTxs() {
        // Tx1: I paid, A owes me 10.
        // Tx2: A paid, I owe A 10.
        // Net: balances out.
        let tx1 = makeSplit(
            id: 1, date: pastDate, paidByMe: 20, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        let tx2 = makeSplit(
            id: 2, date: pastDate, paidByMe: 0, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 20)]
        )
        let result = SplitDebtService.simplifiedDebts(
            transactions: [tx1, tx2], targetCurrency: "USD", convert: identityConvert, now: now
        )
        XCTAssertEqual(result.status, .settled)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
        XCTAssertEqual(result.rows[0].amount, 0, accuracy: 0.001)
    }

    // MARK: - pastSplitTransactions

    func testPastSplitTransactions_keepsOnlyValidSplits() {
        let pastSplit = makeSplit(
            id: 1, date: pastDate, paidByMe: 10, myShare: 5,
            friends: [FriendShare(friendID: "A", share: 5, paidAmount: 0)]
        )
        let futureSplit = makeSplit(
            id: 2, date: futureDate, paidByMe: 10, myShare: 5,
            friends: [FriendShare(friendID: "A", share: 5, paidAmount: 0)]
        )
        let recurringParentSplit = makeSplit(
            id: 3, date: pastDate, paidByMe: 10, myShare: 5,
            friends: [FriendShare(friendID: "A", share: 5, paidAmount: 0)],
            repeatInterval: .daily(hour: 9, minute: 0)
        )
        let nonSplit = TestFixtures.makeTransaction(id: 4, date: pastDate)
        let result = SplitDebtService.pastSplitTransactions(
            from: [pastSplit, futureSplit, recurringParentSplit, nonSplit],
            now: now
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testPastSplitTransactions_keepsRecurringChildren() {
        let child = makeSplit(
            id: 1, date: pastDate, paidByMe: 10, myShare: 5,
            friends: [FriendShare(friendID: "A", share: 5, paidAmount: 0)],
            parentReminderID: 99
        )
        let result = SplitDebtService.pastSplitTransactions(from: [child], now: now)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - userPosition

    func testUserPosition_nonSplitTransaction_notInvolved() {
        let tx = TestFixtures.makeTransaction(id: 1, date: pastDate)
        XCTAssertEqual(SplitDebtService.userPosition(in: tx), .notInvolved)
    }

    func testUserPosition_neitherPaidNorShared_notInvolved() {
        // Friends-only split: user observes.
        let tx = makeSplit(
            date: pastDate, paidByMe: 0, myShare: 0,
            friends: [
                FriendShare(friendID: "A", share: 10, paidAmount: 20),
                FriendShare(friendID: "B", share: 10, paidAmount: 0),
            ]
        )
        XCTAssertEqual(SplitDebtService.userPosition(in: tx), .notInvolved)
    }

    func testUserPosition_iPaidMore_lent() {
        let tx = makeSplit(
            date: pastDate, paidByMe: 20, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        XCTAssertEqual(SplitDebtService.userPosition(in: tx), .lent(10))
    }

    func testUserPosition_iPaidLess_borrowed() {
        let tx = makeSplit(
            date: pastDate, paidByMe: 0, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 20)]
        )
        XCTAssertEqual(SplitDebtService.userPosition(in: tx), .borrowed(10))
    }

    func testUserPosition_evenSplit_notInvolved() {
        // User paid exactly their share → no net. Display-wise treated as notInvolved.
        let tx = makeSplit(
            date: pastDate, paidByMe: 5, myShare: 5,
            friends: [FriendShare(friendID: "A", share: 5, paidAmount: 5)]
        )
        XCTAssertEqual(SplitDebtService.userPosition(in: tx), .notInvolved)
    }

    // MARK: - perTransactionSettlement

    func testPerTransactionSettlement_nonSplit_empty() {
        let tx = TestFixtures.makeTransaction(id: 1, date: pastDate)
        XCTAssertTrue(SplitDebtService.perTransactionSettlement(for: tx).rows.isEmpty)
    }

    func testPerTransactionSettlement_iPaid_friendOwes() {
        let tx = makeSplit(
            date: pastDate, paidByMe: 20, myShare: 10,
            friends: [FriendShare(friendID: "A", share: 10, paidAmount: 0)]
        )
        let result = SplitDebtService.perTransactionSettlement(for: tx)
        XCTAssertEqual(result.rows.count, 1)
        XCTAssertEqual(result.rows[0].friendID, "A")
        XCTAssertEqual(result.rows[0].amount, 10, accuracy: 0.001)
    }

    func testPerTransactionSettlement_prototypeScenario() {
        // From the prototype: total 10, You share 5 paid 2, Danila share 5 paid 5,
        // Misha share 0 paid 3 (non-sharing payer).
        // Balances: Me=-3, Danila=0, Misha=+3 → You borrow Misha 3; Danila balances.
        let tx = makeSplit(
            date: pastDate, paidByMe: 2, myShare: 5,
            friends: [
                FriendShare(friendID: "Danila", share: 5, paidAmount: 5),
                FriendShare(friendID: "Misha", share: 0, paidAmount: 3),
            ]
        )
        let result = SplitDebtService.perTransactionSettlement(for: tx)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertEqual(result.rows[0].friendID, "Misha")
        XCTAssertEqual(result.rows[0].amount, -3, accuracy: 0.001)
        XCTAssertEqual(result.rows[1].friendID, "Danila")
        XCTAssertEqual(result.rows[1].amount, 0, accuracy: 0.001)
    }

    func testPerTransactionSettlement_observerTriangle() {
        // User neutral, friends A and B offset each other.
        let tx = makeSplit(
            date: pastDate, paidByMe: 0, myShare: 0,
            friends: [
                FriendShare(friendID: "A", share: 0, paidAmount: 10),
                FriendShare(friendID: "B", share: 10, paidAmount: 0),
            ]
        )
        let result = SplitDebtService.perTransactionSettlement(for: tx)
        XCTAssertEqual(result.rows.count, 2)
        XCTAssertTrue(result.rows.allSatisfy { abs($0.amount) < 0.005 })
    }
}

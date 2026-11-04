import XCTest
@testable import non_bank

/// The friend pickers put the people you split with most often first.
@MainActor
final class FriendUsageRankingTests: XCTestCase {

    private let alia = Friend(id: "alia", name: "Alia")
    private let denis = Friend(id: "denis", name: "Denis")
    private let dragana = Friend(id: "dragana", name: "Dragana")
    private let elena = Friend(id: "elena", name: "Elena")
    private let miha = Friend(id: "miha", name: "Miha")

    /// The picker's incoming order: the store's, alphabetical.
    private var alphabetical: [Friend] { [alia, denis, dragana, elena, miha] }

    private func split(_ id: Int, daysAgo: Double, with friends: [(id: String, paid: Double)]) -> Transaction {
        TestFixtures.makeTransaction(
            id: id,
            date: TestFixtures.fixedDate.addingTimeInterval(-daysAgo * 86_400),
            splitInfo: SplitInfo(
                totalAmount: 100, paidByMe: 100, myShare: 50, lentAmount: 50,
                friends: friends.map { FriendShare(friendID: $0.id, share: 50, paidAmount: $0.paid) }
            )
        )
    }

    private func order(_ transactions: [Transaction]) -> [String] {
        FriendUsageRanking.sorted(alphabetical, by: FriendUsageRanking.usage(in: transactions)).map(\.name)
    }

    func testMostOftenSplitWithComesFirst() {
        let transactions = [
            split(1, daysAgo: 10, with: [("miha", 0)]),
            split(2, daysAgo: 9, with: [("miha", 0), ("dragana", 0)]),
            split(3, daysAgo: 8, with: [("miha", 0)]),
            split(4, daysAgo: 7, with: [("dragana", 0)]),
            TestFixtures.makeTransaction(id: 5),  // a plain expense, no split
        ]
        let usage = FriendUsageRanking.usage(in: transactions)
        XCTAssertEqual(usage["miha"]?.count, 3)
        XCTAssertEqual(usage["dragana"]?.count, 2)
        XCTAssertNil(usage["alia"])
        // Never-used friends keep the alphabetical order, after the rest.
        XCTAssertEqual(order(transactions), ["Miha", "Dragana", "Alia", "Denis", "Elena"])
    }

    func testEqualCountsPutTheMoreRecentFirst() {
        let transactions = [
            split(1, daysAgo: 30, with: [("alia", 0)]),
            split(2, daysAgo: 2, with: [("elena", 0)]),
        ]
        XCTAssertEqual(order(transactions), ["Elena", "Alia", "Denis", "Dragana", "Miha"])
    }

    /// Paying for a split is taking part in it too — the payer picker
    /// ranks the same way.
    func testPayingCountsAsTakingPart() {
        let usage = FriendUsageRanking.usage(in: [split(1, daysAgo: 1, with: [("denis", 100)])])
        XCTAssertEqual(usage["denis"]?.count, 1)
    }

    func testOneTransactionCountsOncePerFriend() {
        let usage = FriendUsageRanking.usage(in: [split(1, daysAgo: 1, with: [("miha", 0), ("miha", 50)])])
        XCTAssertEqual(usage["miha"]?.count, 1)
    }

    func testLastUsedIsTheLatestSplit() {
        let usage = FriendUsageRanking.usage(in: [
            split(1, daysAgo: 3, with: [("miha", 0)]),
            split(2, daysAgo: 20, with: [("miha", 0)]),
        ])
        XCTAssertEqual(usage["miha"]?.lastUsed, TestFixtures.fixedDate.addingTimeInterval(-3 * 86_400))
    }

    func testNoHistoryKeepsTheIncomingOrder() {
        XCTAssertEqual(order([]), ["Alia", "Denis", "Dragana", "Elena", "Miha"])
        XCTAssertTrue(FriendUsageRanking.sorted([], by: [:]).isEmpty)
    }
}

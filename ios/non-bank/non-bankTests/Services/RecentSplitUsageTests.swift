import XCTest
@testable import non_bank

/// "Recently used" on the mode picker: the setups (mode + people) you
/// split with most, with the stale ones gone.
@MainActor
final class RecentSplitUsageTests: XCTestCase {

    private let now = TestFixtures.fixedDate
    private let friends: Set<String> = ["miha", "alia", "denis", "dragana"]

    private func split(
        _ id: Int,
        daysAgo: Double,
        _ mode: SplitMode = .evenly,
        with friendIDs: [String],
        you: Bool = true,
        paidBy payer: String? = nil,
        checksum: String? = nil,
        parentReminderID: Int? = nil,
        savedDaysAgo: Double? = nil
    ) -> Transaction {
        let date = now.addingTimeInterval(-daysAgo * 86_400)
        // A payer who isn't in the split rides along with a zero share,
        // as `buildTransaction` stores them.
        let payerShares = payer.map { [FriendShare(friendID: $0, share: 0, paidAmount: 50)] } ?? []
        return Transaction(
            id: id,
            emoji: "🍽️",
            category: "Food",
            title: "Dinner",
            description: nil,
            amount: payer == nil ? 50 : 0,
            currency: "EUR",
            date: date,
            type: .expenses,
            tags: nil,
            lastModified: savedDaysAgo.map { now.addingTimeInterval(-$0 * 86_400) } ?? date,
            parentReminderID: parentReminderID,
            splitInfo: SplitInfo(
                totalAmount: 50,
                paidByMe: payer == nil ? 50 : 0,
                myShare: you ? 10 : 0,
                lentAmount: payer == nil ? 40 : 0,
                friends: friendIDs.map { FriendShare(friendID: $0, share: 10) } + payerShares,
                splitMode: mode
            ),
            payloadChecksum: checksum
        )
    }

    private func shortcuts(_ transactions: [Transaction], friends known: Set<String>? = nil) -> [RecentSplitOption] {
        RecentSplitUsage.options(from: transactions, knownFriendIDs: known ?? friends, now: now)
    }

    private func people(_ transactions: [Transaction], friends known: Set<String>? = nil) -> [[String]] {
        shortcuts(transactions, friends: known).map(\.friendIDs)
    }

    // MARK: - Order

    func testMostUsedComesFirst() {
        let transactions = [
            split(1, daysAgo: 20, with: ["miha"]),
            split(2, daysAgo: 10, with: ["miha"]),
            split(3, daysAgo: 5, with: ["miha"]),
            split(4, daysAgo: 1, with: ["alia"]),  // the latest, but used once
        ]
        XCTAssertEqual(people(transactions), [["miha"], ["alia"]])
    }

    func testEqualUseCountsPutTheMoreRecentFirst() {
        let transactions = [
            split(1, daysAgo: 12, with: ["miha"]),
            split(2, daysAgo: 11, with: ["miha"]),
            split(3, daysAgo: 4, with: ["alia"]),
            split(4, daysAgo: 3, with: ["alia"]),
        ]
        XCTAssertEqual(people(transactions), [["alia"], ["miha"]])
    }

    /// Frequency is counted over the last 30 days: a setup used a lot
    /// two months back loses to one used once this month.
    func testOnlyTheLast30DaysCountTowardsTheOrder() {
        let transactions = (1...5).map { split($0, daysAgo: 40 + Double($0), with: ["miha"]) }
            + [split(6, daysAgo: 25, with: ["alia"])]
        XCTAssertEqual(people(transactions), [["alia"]])
    }

    // MARK: - The second shortcut

    /// The example from the proposal: Miha every few days, Alia and
    /// Denis once three weeks ago — only Miha shows. Split with Alia
    /// and Denis again and both show.
    func testOneOffSetupLeavesAfterAWeek() {
        var transactions = (1...8).map { split($0, daysAgo: Double($0) * 3, with: ["miha"]) }
        transactions.append(split(9, daysAgo: 21, with: ["alia", "denis"]))
        XCTAssertEqual(people(transactions), [["miha"]])

        transactions.append(split(10, daysAgo: 0, with: ["alia", "denis"]))
        XCTAssertEqual(people(transactions), [["miha"], ["alia", "denis"]])
    }

    func testNewSetupShowsForAWeek() {
        var transactions = (1...3).map { split($0, daysAgo: Double($0), with: ["miha"]) }
        transactions.append(split(4, daysAgo: 6, with: ["alia"]))
        XCTAssertEqual(people(transactions), [["miha"], ["alia"]])

        transactions[3] = split(4, daysAgo: 8, with: ["alia"])
        XCTAssertEqual(people(transactions), [["miha"]])
    }

    /// Twice in 30 days keeps the second shortcut on screen even when
    /// the latest use is weeks old.
    func testSetupUsedTwiceThisMonthStays() {
        let transactions = [
            split(1, daysAgo: 1, with: ["miha"]),
            split(2, daysAgo: 2, with: ["miha"]),
            split(3, daysAgo: 3, with: ["miha"]),
            split(4, daysAgo: 25, with: ["alia", "denis"]),
            split(5, daysAgo: 20, with: ["alia", "denis"]),
        ]
        XCTAssertEqual(people(transactions), [["miha"], ["alia", "denis"]])
    }

    func testNeverMoreThanTwo() {
        var transactions: [Transaction] = []
        for (index, friend) in ["miha", "alia", "denis", "dragana"].enumerated() {
            for use in 0..<3 {
                transactions.append(split(index * 10 + use, daysAgo: Double(use), with: [friend]))
            }
        }
        XCTAssertEqual(shortcuts(transactions).count, 2)
    }

    // MARK: - Going stale

    func testNothingFor60DaysHidesTheBlock() {
        XCTAssertTrue(shortcuts([]).isEmpty)
        XCTAssertTrue(shortcuts([
            split(1, daysAgo: 61, with: ["miha"]),
            split(2, daysAgo: 90, with: ["alia"]),
        ]).isEmpty)
    }

    /// Nothing this month but something in the last 60 days: the latest
    /// one shows on its own.
    func testLastSetupWithin60DaysStillShowsAlone() {
        let transactions = [
            split(1, daysAgo: 45, with: ["miha"]),
            split(2, daysAgo: 50, with: ["alia"]),
        ]
        XCTAssertEqual(people(transactions), [["miha"]])
    }

    // MARK: - What counts

    func testSettleUpIsLeftOut() {
        let transactions = [
            split(1, daysAgo: 1, .settleUp, with: ["miha"], you: false),
            split(2, daysAgo: 2, .settleUp, with: ["miha"], you: false),
            split(3, daysAgo: 20, with: ["alia"]),
        ]
        XCTAssertEqual(people(transactions), [["alia"]])
        XCTAssertNil(RecentSplitUsage.setup(of: transactions[0], usedAt: now))
    }

    /// A friend's split shared with you, and occurrences of a recurring
    /// split, aren't setups you picked.
    func testOnlyYourOwnSplitsCount() {
        let transactions = [
            split(1, daysAgo: 1, with: ["miha"], checksum: "abc"),
            split(2, daysAgo: 2, with: ["miha"], checksum: "def"),
            split(3, daysAgo: 1, with: ["denis"], parentReminderID: 7),
            split(4, daysAgo: 2, with: ["denis"], parentReminderID: 7),
            split(5, daysAgo: 20, with: ["alia"]),
            TestFixtures.makeTransaction(id: 6, date: now),  // no split
        ]
        XCTAssertEqual(people(transactions), [["alia"]])
    }

    func testSplitWithoutARecordedModeIsSkipped() {
        let legacy = TestFixtures.makeTransaction(
            id: 1,
            date: now,
            splitInfo: SplitInfo(
                totalAmount: 50, paidByMe: 50, myShare: 25, lentAmount: 25,
                friends: [FriendShare(friendID: "miha", share: 25)]
            )
        )
        XCTAssertTrue(shortcuts([legacy]).isEmpty)
    }

    /// Someone who only paid isn't one of the people split with, so the
    /// split replays the same people as one without them.
    func testPayerOutsideTheSplitIsNotAParticipant() {
        let transactions = [
            split(1, daysAgo: 1, with: ["alia"], paidBy: "denis"),
            split(2, daysAgo: 2, with: ["alia"]),
        ]
        XCTAssertEqual(people(transactions), [["alia"]])
    }

    /// A setup with a deleted friend can't be replayed, so it doesn't
    /// hold a slot: the next one takes its place.
    func testSetupWithADeletedFriendMakesRoom() {
        let transactions = [
            split(1, daysAgo: 1, with: ["miha", "zoran"]),
            split(2, daysAgo: 2, with: ["miha", "zoran"]),
            split(3, daysAgo: 3, with: ["miha", "zoran"]),
            split(4, daysAgo: 4, with: ["alia"]),
            split(5, daysAgo: 5, with: ["alia"]),
            split(6, daysAgo: 6, with: ["denis"]),
        ]
        XCTAssertEqual(people(transactions), [["alia"], ["denis"]])
    }

    /// The same people picked in another order are the same setup; the
    /// shortcut keeps the latest order.
    func testSamePeopleInAnotherOrderAreOneSetup() {
        let transactions = [
            split(1, daysAgo: 5, with: ["alia", "denis"]),
            split(2, daysAgo: 2, with: ["denis", "alia"]),
            split(3, daysAgo: 1, with: ["miha"]),
        ]
        XCTAssertEqual(people(transactions), [["denis", "alia"], ["miha"]])
    }

    /// Splitting with the same people a different way, or leaving
    /// yourself out, is a different setup.
    func testModeAndYouArePartOfTheSetup() {
        let transactions = [
            split(1, daysAgo: 1, with: ["miha"]),
            split(2, daysAgo: 2, with: ["miha"]),
            split(3, daysAgo: 3, with: ["miha"]),
            split(4, daysAgo: 1, .byItems, with: ["miha"]),
            split(5, daysAgo: 2, .byItems, with: ["miha"]),
            split(6, daysAgo: 0, with: ["miha"], you: false),
        ]
        let shown = shortcuts(transactions)
        XCTAssertEqual(shown.map(\.mode), [.evenly, .byItems])
        XCTAssertEqual(shown.map(\.youIncluded), [true, true])

        let onlyThem = shortcuts([split(1, daysAgo: 0, with: ["miha"], you: false)])
        XCTAssertEqual(onlyThem.map(\.youIncluded), [false])
    }

    /// A split dated ahead counts from when it was saved, not as "just
    /// used" until its date.
    func testFutureDatedSplitCountsFromWhenItWasSaved() {
        let transactions = [
            split(1, daysAgo: 25, with: ["alia"]),
            split(2, daysAgo: 24, with: ["alia"]),
            split(3, daysAgo: -10, with: ["miha"], savedDaysAgo: 20),
            split(4, daysAgo: -30, with: ["denis"], savedDaysAgo: 0),
        ]
        XCTAssertEqual(people(transactions), [["alia"], ["denis"]])
        XCTAssertEqual(
            RecentSplitUsage.usedAt(transactions[2], now: now),
            now.addingTimeInterval(-20 * 86_400)
        )
        XCTAssertEqual(RecentSplitUsage.usedAt(transactions[0], now: now), transactions[0].date)
    }
}

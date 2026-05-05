import XCTest
@testable import non_bank

final class ReminderServiceTests: XCTestCase {

    // Fixed "now" for deterministic tests: 2024-06-15 12:00:00 UTC
    private let now = Date(timeIntervalSince1970: 1_718_452_800)
    private let pastDate = Date(timeIntervalSince1970: 1_718_452_800 - 86400) // yesterday
    private let futureDate = Date(timeIntervalSince1970: 1_718_452_800 + 86400) // tomorrow

    // MARK: - homeTransactions

    func testHomeTransactions_excludesFuture() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: pastDate),
            TestFixtures.makeTransaction(id: 2, date: futureDate),
        ]
        let result = ReminderService.homeTransactions(from: txs, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testHomeTransactions_excludesRecurringParents() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: pastDate, repeatInterval: .daily(hour: 9, minute: 0)),
            TestFixtures.makeTransaction(id: 2, date: pastDate),
        ]
        let result = ReminderService.homeTransactions(from: txs, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 2)
    }

    func testHomeTransactions_includesRecurringChildren() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: pastDate, parentReminderID: 99),
        ]
        let result = ReminderService.homeTransactions(from: txs, now: now)
        XCTAssertEqual(result.count, 1)
    }

    // MARK: - reminders

    func testReminders_includesFutureTransactions() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: futureDate),
            TestFixtures.makeTransaction(id: 2, date: pastDate),
        ]
        let result = ReminderService.reminders(from: txs, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testReminders_includesRecurringParents() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: pastDate, repeatInterval: .daily(hour: 9, minute: 0)),
        ]
        let result = ReminderService.reminders(from: txs, now: now)
        XCTAssertEqual(result.count, 1)
    }

    func testReminders_includesPastRecurringParents() {
        // Past-dated recurring parents should appear in reminders (not just future ones)
        let veryOldDate = Date(timeIntervalSince1970: now.timeIntervalSince1970 - 86400 * 30) // 30 days ago
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: veryOldDate, repeatInterval: .monthly(hour: 10, minute: 0, daysOfMonth: [1])),
            TestFixtures.makeTransaction(id: 2, date: pastDate), // regular past, should NOT appear
        ]
        let result = ReminderService.reminders(from: txs, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testReminders_excludesRecurringChildren() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: futureDate, parentReminderID: 99),
        ]
        let result = ReminderService.reminders(from: txs, now: now)
        XCTAssertEqual(result.count, 0)
    }

    // MARK: - nextOccurrenceDate

    func testNextOccurrenceDate_futureOneTime() {
        let tx = TestFixtures.makeTransaction(id: 1, date: futureDate)
        let result = ReminderService.nextOccurrenceDate(for: tx, now: now)
        XCTAssertEqual(result, futureDate)
    }

    func testNextOccurrenceDate_pastNonRecurring() {
        let tx = TestFixtures.makeTransaction(id: 1, date: pastDate)
        let result = ReminderService.nextOccurrenceDate(for: tx, now: now)
        XCTAssertNil(result)
    }

    func testNextOccurrenceDate_recurring() {
        let tx = TestFixtures.makeTransaction(
            id: 1, date: pastDate,
            repeatInterval: .daily(hour: 9, minute: 0)
        )
        let result = ReminderService.nextOccurrenceDate(for: tx, now: now)
        XCTAssertNotNil(result)
        // Should be in the future or at least >= now
        XCTAssertGreaterThanOrEqual(result!, now)
    }

    // MARK: - spawnChild

    func testSpawnChild_inheritsParentFields() {
        let parent = TestFixtures.makeTransaction(
            id: 42, title: "Monthly Rent", amount: 1200, type: .expenses,
            repeatInterval: .monthly(hour: 10, minute: 0, daysOfMonth: [1])
        )
        let child = ReminderService.spawnChild(from: parent, at: futureDate)

        XCTAssertEqual(child.id, 0)
        XCTAssertEqual(child.title, "Monthly Rent")
        XCTAssertEqual(child.amount, 1200)
        XCTAssertEqual(child.type, .expenses)
        XCTAssertEqual(child.parentReminderID, 42)
        XCTAssertNil(child.repeatInterval)
        XCTAssertEqual(child.date, futureDate)
    }

    // MARK: - sortedByNextOccurrence

    func testSortedByNextOccurrence_sortsCorrectly() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: Date(timeIntervalSince1970: now.timeIntervalSince1970 + 7200)), // +2h
            TestFixtures.makeTransaction(id: 2, date: Date(timeIntervalSince1970: now.timeIntervalSince1970 + 3600)), // +1h
        ]
        let sorted = ReminderService.sortedByNextOccurrence(txs, now: now)
        XCTAssertEqual(sorted.first?.id, 2)
        XCTAssertEqual(sorted.last?.id, 1)
    }

    // MARK: - transactionsNeedingSpawn

    func testTransactionsNeedingSpawn_noChildrenYet() {
        let calendar = Calendar.current
        // Parent created 3 days ago with daily repeat at 09:00
        let parentDate = calendar.date(byAdding: .day, value: -3, to: now)!
        let parent = TestFixtures.makeTransaction(
            id: 10, date: parentDate,
            repeatInterval: .daily(hour: 9, minute: 0)
        )
        let result = ReminderService.transactionsNeedingSpawn(
            recurringParents: [parent],
            allTransactions: [parent],
            now: now,
            calendar: calendar
        )
        // Should spawn at least 1 child (exact count depends on time alignment)
        XCTAssertGreaterThan(result.count, 0)
        XCTAssertTrue(result.allSatisfy { $0.parent.id == 10 })
    }

    func testTransactionsNeedingSpawn_firstOccurrenceMatchingParentDateSpawns() {
        // User sets `daily at 15:30`, saves at 15:30:14 (non-zero seconds).
        // `nextOccurrence` produces `hour:minute:00`, so without normalizing
        // parent.date we'd skip today's 15:30 (15:30:00 < 15:30:14) and only
        // spawn tomorrow. This guards that the very first occurrence spawns.
        let calendar = Calendar.current
        var comps = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: now
        )
        comps.hour = 15
        comps.minute = 30
        comps.second = 14
        let parentDate = calendar.date(from: comps)!
        comps.second = 47
        let nowRef = calendar.date(from: comps)! // same day, 15:30:47

        let parent = TestFixtures.makeTransaction(
            id: 42, date: parentDate,
            repeatInterval: .daily(hour: 15, minute: 30)
        )
        let result = ReminderService.transactionsNeedingSpawn(
            recurringParents: [parent],
            allTransactions: [parent],
            now: nowRef,
            calendar: calendar,
            lastAcknowledged: { _ in nil }
        )
        XCTAssertEqual(result.count, 1)
        // Spawn date should be today 15:30:00 (matching the daily pattern).
        var expected = comps
        expected.second = 0
        XCTAssertEqual(result.first?.spawnDate, calendar.date(from: expected))
    }

    func testTransactionsNeedingSpawn_respectsAckFromDeletedChild() {
        // Simulates "spawn then delete": ack is stored even though no child
        // exists anymore. The service must not re-spawn the same occurrence.
        let calendar = Calendar.current
        let parentDate = calendar.date(byAdding: .day, value: -2, to: now)!
        let parent = TestFixtures.makeTransaction(
            id: 77,
            date: parentDate,
            repeatInterval: .daily(hour: 9, minute: 0)
        )
        // Ack yesterday's 09:00 occurrence as if it had been spawned.
        let yesterday9am = calendar.date(
            byAdding: .day, value: -1,
            to: calendar.startOfDay(for: now).addingTimeInterval(9 * 3600)
        )!
        let result = ReminderService.transactionsNeedingSpawn(
            recurringParents: [parent],
            allTransactions: [parent],
            now: now,
            calendar: calendar,
            lastAcknowledged: { syncID in
                syncID == parent.syncID ? yesterday9am : nil
            }
        )
        // Only today's 09:00 should remain (yesterday is acked, two-days-ago
        // is before ack, so excluded).
        XCTAssertEqual(result.count, 1)
    }
}

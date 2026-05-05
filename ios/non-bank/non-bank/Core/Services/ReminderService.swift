import Foundation

/// Pure business logic for reminders and recurring transaction management.
/// No UI dependencies. Unit-testable.
enum ReminderService {

    // MARK: - Filtering

    /// Returns transactions that should appear in the Reminders screen:
    /// - Future-dated transactions (date > now)
    /// - Recurring parent transactions (repeatInterval != nil, parentReminderID == nil)
    /// Excludes recurring children (they appear in the home list).
    static func reminders(
        from transactions: [Transaction],
        now: Date = Date()
    ) -> [Transaction] {
        transactions.filter { tx in
            // Recurring children belong to home list, not reminders
            guard tx.parentReminderID == nil else { return false }
            // Future-dated OR recurring parent
            return tx.date > now || tx.repeatInterval != nil
        }
    }

    /// Returns transactions that should appear in the Home screen:
    /// - Past/present dated (date <= now)
    /// - NOT recurring parents without a past date (those appear in reminders only)
    /// Recurring children DO appear here.
    static func homeTransactions(
        from transactions: [Transaction],
        now: Date = Date()
    ) -> [Transaction] {
        transactions.filter { tx in
            // Future transactions show only in reminders
            if tx.date > now { return false }
            // Recurring parents that have a past date still don't show in home
            // (they are template records; only their children appear)
            if tx.isRecurringParent { return false }
            return true
        }
    }

    // MARK: - Next Occurrence

    /// For a recurring transaction, computes the next occurrence date.
    /// For one-time future transactions, returns their date.
    /// Returns nil for past non-recurring transactions.
    static func nextOccurrenceDate(
        for transaction: Transaction,
        now: Date = Date()
    ) -> Date? {
        if let interval = transaction.repeatInterval {
            return interval.nextOccurrence(after: now)
        }
        if transaction.date > now {
            return transaction.date
        }
        return nil
    }

    // MARK: - Spawn Check

    /// Checks which recurring parent transactions need to spawn a new child.
    /// A child should be spawned when the next occurrence date has passed
    /// and no child exists for that date yet.
    static func transactionsNeedingSpawn(
        recurringParents: [Transaction],
        allTransactions: [Transaction],
        now: Date = Date(),
        calendar: Calendar = .current,
        lastAcknowledged: (String) -> Date? = { SpawnTracker.lastAcknowledged(parentSyncID: $0) }
    ) -> [(parent: Transaction, spawnDate: Date)] {
        var results: [(Transaction, Date)] = []

        for parent in recurringParents {
            guard let interval = parent.repeatInterval else { continue }

            // The latest known occurrence for this parent is the max of:
            //  - most recent child's date (currently present in the store)
            //  - tracker ack (covers children that were spawned-then-deleted)
            //  - start-of-minute(parent.date) - 1s so the very first spawn can
            //    include `parent.date`'s matching occurrence. We normalize to
            //    minute precision because `nextOccurrence` produces
            //    `hour:minute:00`, and a parent.date with non-zero seconds
            //    would otherwise already be *after* the first candidate.
            let children = allTransactions.filter { $0.parentReminderID == parent.id }
            let childMax = children.map(\.date).max() ?? .distantPast
            let storedAck = lastAcknowledged(parent.syncID) ?? .distantPast
            let preParentDate = minuteStart(of: parent.date, calendar: calendar)
                .addingTimeInterval(-1)
            var checkDate = [childMax, storedAck, preParentDate].max() ?? preParentDate

            while let nextDate = interval.nextOccurrence(after: checkDate, calendar: calendar),
                  nextDate <= now {
                results.append((parent, nextDate))
                checkDate = nextDate
            }
        }

        return results
    }

    /// Truncates a date down to the start of its minute (seconds = 0).
    private static func minuteStart(of date: Date, calendar: Calendar) -> Date {
        var comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        comps.second = 0
        return calendar.date(from: comps) ?? date
    }

    /// Creates a child transaction from a parent template at the given date.
    static func spawnChild(
        from parent: Transaction,
        at date: Date
    ) -> Transaction {
        Transaction(
            id: 0, // Will be assigned by SQLite autoincrement
            syncID: UUID().uuidString,
            emoji: parent.emoji,
            category: parent.category,
            title: parent.title,
            description: parent.description,
            amount: parent.amount,
            currency: parent.currency,
            date: date,
            type: parent.type,
            tags: nil,
            lastModified: Date(),
            repeatInterval: nil, // Child does NOT repeat
            parentReminderID: parent.id,
            splitInfo: parent.splitInfo
        )
    }

    // MARK: - Sorting

    /// Sorts reminders by next occurrence date (soonest first).
    static func sortedByNextOccurrence(
        _ reminders: [Transaction],
        now: Date = Date()
    ) -> [Transaction] {
        reminders.sorted { a, b in
            let dateA = nextOccurrenceDate(for: a, now: now) ?? .distantFuture
            let dateB = nextOccurrenceDate(for: b, now: now) ?? .distantFuture
            return dateA < dateB
        }
    }
}

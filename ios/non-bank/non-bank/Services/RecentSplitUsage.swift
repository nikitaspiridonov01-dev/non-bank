import Foundation

/// The "Recently used" shortcuts on the mode picker, worked out from the
/// splits you created: the setups (mode + people) you use most, minus the
/// ones gone stale.
///
/// - First: the setup used most in the last 30 days, the more recent one
///   on a tie; with nothing in 30 days, the latest from the last 60 days.
/// - Second: only while it's in use too — at least twice in 30 days, or
///   once in the last 7 days. A one-off split shows for a week (handy on a
///   trip with the same people), then leaves on its own.
/// - Nothing used for 60 days: no shortcuts.
///
/// Settle-ups and recurring transactions (the recurring one itself and
/// its occurrences) are left out. Only your own splits count: a friend's
/// split shared with you (it carries a payload checksum) isn't a setup you
/// picked. Counted from the transactions themselves, so the existing
/// history counts from the start, and deleting or editing a transaction
/// shows in the shortcuts.
enum RecentSplitUsage {

    static let window: TimeInterval = 30 * 86_400
    static let fresh: TimeInterval = 7 * 86_400
    static let expiry: TimeInterval = 60 * 86_400
    /// Uses within `window` that keep a second shortcut on screen.
    static let busyUses = 2
    static let maxShown = 2

    /// At most `maxShown` setups, most used first. Setups naming a friend
    /// who no longer exists are skipped before choosing, so they can't
    /// take a slot the picker would then leave empty.
    static func options(
        from transactions: [Transaction],
        knownFriendIDs: Set<String>,
        now: Date = Date()
    ) -> [RecentSplitOption] {
        var tallies: [String: Tally] = [:]
        for transaction in transactions {
            let used = usedAt(transaction, now: now)
            let age = now.timeIntervalSince(used)
            guard age <= expiry,
                  let option = setup(of: transaction, usedAt: used),
                  option.friendIDs.allSatisfy(knownFriendIDs.contains)
            else { continue }
            var tally = tallies[option.dedupKey] ?? Tally(option: option, uses: 0, lastUsed: used)
            if age <= window { tally.uses += 1 }
            if used >= tally.lastUsed {
                // The latest use's friend order drives the avatar stack.
                tally.lastUsed = used
                tally.option = option
            }
            tallies[option.dedupKey] = tally
        }

        let ranked = tallies.values.sorted { a, b in
            if a.uses != b.uses { return a.uses > b.uses }
            if a.lastUsed != b.lastUsed { return a.lastUsed > b.lastUsed }
            return a.option.dedupKey < b.option.dedupKey
        }
        var shown: [RecentSplitOption] = []
        for (rank, tally) in ranked.prefix(maxShown).enumerated() {
            let inUse = tally.uses >= busyUses || now.timeIntervalSince(tally.lastUsed) <= fresh
            guard rank == 0 || inUse else { break }
            shown.append(tally.option)
        }
        return shown
    }

    /// When the setup was used: the transaction's date. A future-dated
    /// one (planned ahead) counts from when it was saved, so it doesn't
    /// sit in the shortcuts as "just used" until that date comes.
    static func usedAt(_ transaction: Transaction, now: Date) -> Date {
        transaction.date <= now ? transaction.date : min(transaction.lastModified, now)
    }

    /// The setup a transaction was split with, or nil when it doesn't
    /// count: no split, a settle-up, a recurring transaction or one of its
    /// occurrences, a friend's shared split, or no recorded mode.
    static func setup(of transaction: Transaction, usedAt: Date) -> RecentSplitOption? {
        guard transaction.payloadChecksum == nil,
              transaction.repeatInterval == nil,
              transaction.parentReminderID == nil,
              let split = transaction.splitInfo,
              let mode = split.splitMode, mode != .settleUp
        else { return nil }
        // The picked participants, in their order. Payers who weren't part
        // of the split follow them with a zero share (`buildTransaction`'s
        // `extraPayerShares`) and aren't participants to replay.
        let friendIDs = split.friends
            .filter { !(abs($0.share) < 0.005 && $0.paidAmount > 0.005) }
            .map(\.friendID)
        guard !friendIDs.isEmpty else { return nil }
        return RecentSplitOption(
            mode: mode,
            friendIDs: friendIDs,
            // The same reading the edit screen uses (`youIncludedInSplit`).
            youIncluded: split.myShare > 0,
            settleUpPayerID: nil,
            settleUpRecipientID: nil,
            createdAt: usedAt
        )
    }

    private struct Tally {
        var option: RecentSplitOption
        var uses: Int
        var lastUsed: Date
    }
}

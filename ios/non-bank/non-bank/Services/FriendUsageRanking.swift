import Foundation

/// Order for the friend pickers ("Who to split with", "Add payers", "Who
/// to settle with"): the friends you split with most often first, so the
/// usual people sit at the top instead of wherever the alphabet puts them.
///
/// Derived from the transactions themselves — no separate counter to keep
/// in sync — so it covers the whole history from the first launch of this
/// version, and follows transactions synced from another device.
enum FriendUsageRanking {

    struct Usage: Equatable {
        var count: Int
        var lastUsed: Date
    }

    /// Per friend: how many split transactions they took part in — sharing
    /// the cost or paying for it — and the date of the latest one.
    static func usage(in transactions: [Transaction]) -> [String: Usage] {
        var usage: [String: Usage] = [:]
        for transaction in transactions {
            guard let split = transaction.splitInfo else { continue }
            for id in Set(split.friends.map(\.friendID)) {
                if var known = usage[id] {
                    known.count += 1
                    known.lastUsed = max(known.lastUsed, transaction.date)
                    usage[id] = known
                } else {
                    usage[id] = Usage(count: 1, lastUsed: transaction.date)
                }
            }
        }
        return usage
    }

    /// `friends` with the most used first; at equal counts, the more
    /// recently used first. Friends never split with keep their incoming
    /// (alphabetical) order, after everyone else.
    static func sorted(_ friends: [Friend], by usage: [String: Usage]) -> [Friend] {
        friends.enumerated().sorted { a, b in
            let usageA = usage[a.element.id], usageB = usage[b.element.id]
            let countA = usageA?.count ?? 0, countB = usageB?.count ?? 0
            if countA != countB { return countA > countB }
            if let lastA = usageA?.lastUsed, let lastB = usageB?.lastUsed, lastA != lastB {
                return lastA > lastB
            }
            return a.offset < b.offset
        }.map(\.element)
    }
}

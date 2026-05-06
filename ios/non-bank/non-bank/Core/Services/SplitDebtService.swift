import Foundation

/// A single row in the simplified debts view — a friend and the net amount
/// I transfer to/from them after greedy simplification.
struct SimplifiedDebt: Equatable, Identifiable {
    let friendID: String
    /// Positive = friend owes me. Negative = I owe friend. ~0 = balances out.
    let amount: Double

    var id: String { friendID }
}

/// Result of simplifying split-transaction debts Splitwise-style.
struct SimplifiedDebtsSummary: Equatable {
    /// One row per friend who appears in any valid split transaction.
    /// Non-zero rows first (sorted by |amount| desc), "balances out" rows last.
    let rows: [SimplifiedDebt]
    /// Sum of my simplified debts in the target currency.
    let netAmount: Double

    var status: DebtSummary.Status {
        if netAmount > 0.005 { return .youLent(netAmount) }
        if netAmount < -0.005 { return .youOwe(abs(netAmount)) }
        return .settled
    }

    static let empty = SimplifiedDebtsSummary(rows: [], netAmount: 0)
}

/// The user's personal position in a single split transaction.
enum UserTransactionPosition: Equatable {
    /// User has no share and paid nothing — transaction is between other friends.
    case notInvolved
    /// User paid more than their share — others owe them.
    case lent(Double)
    /// User's share exceeds what they paid — they owe others.
    case borrowed(Double)
    /// User has a share or upfront contribution but the two cancel out
    /// — they're a participant whose net delta is ~0 within this
    /// single transaction. Distinct from `.notInvolved` so the UI can
    /// say "your share is settled" instead of "you're not in this".
    case settled
}

/// Simplified settlement within a single split transaction, from the user's POV.
struct PerTransactionSettlement: Equatable {
    struct Row: Equatable, Identifiable {
        let friendID: String
        /// Positive = friend owes me, negative = I owe friend, ~0 = balances out
        let amount: Double
        var id: String { friendID }
    }
    /// One row per friend participant. Non-zero rows first (by |amount| desc),
    /// balances-out rows last.
    let rows: [Row]
}

/// Result of aggregating split-transaction debts across all friends.
struct DebtSummary: Equatable {
    /// Per-friend net debt amounts (positive = friend owes me, negative = I owe friend).
    /// Keyed by friend ID. Excludes zero balances.
    let perFriend: [String: Double]

    /// Overall net: positive = I lent more than I owe, negative = I owe more than I lent.
    let netAmount: Double

    /// Up to 3 friend IDs with the largest absolute debt, sorted descending.
    let topFriendIDs: [String]

    var status: Status {
        if netAmount > 0.005 { return .youLent(netAmount) }
        if netAmount < -0.005 { return .youOwe(abs(netAmount)) }
        return .settled
    }

    enum Status: Equatable {
        case settled
        case youOwe(Double)
        case youLent(Double)
    }

    static let empty = DebtSummary(perFriend: [:], netAmount: 0, topFriendIDs: [])
}

/// Pure business logic for calculating split-transaction debts.
/// No UI or persistence dependencies.
enum SplitDebtService {

    /// Calculates the aggregate debt summary from all split transactions.
    ///
    /// - Parameters:
    ///   - transactions: Home-eligible transactions (past, non-recurring-parent).
    ///     Future transactions and recurring parents should already be filtered out.
    ///   - targetCurrency: The user's selected display currency.
    ///   - convert: Currency conversion closure `(amount, fromCurrency, toCurrency) -> converted`.
    /// - Returns: A `DebtSummary` describing the user's net debt position.
    static func calculateDebt(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> DebtSummary {
        // Only consider transactions that have split info
        let splitTransactions = transactions.filter { $0.splitInfo != nil }
        guard !splitTransactions.isEmpty else { return .empty }

        // Accumulate per-friend debt in target currency
        var perFriend: [String: Double] = [:]

        for tx in splitTransactions {
            guard let split = tx.splitInfo else { continue }

            for friend in split.friends {
                // How much this friend owes relative to what they paid:
                // friend.share = their fair portion of the total
                // friend.paidAmount = how much they actually paid
                // debt = share - paidAmount
                //   positive => friend still owes this amount (I lent them)
                //   negative => friend overpaid (I owe them)
                let debtInOriginal = friend.share - friend.paidAmount
                let debtConverted = convert(debtInOriginal, tx.currency, targetCurrency)

                perFriend[friend.friendID, default: 0] += debtConverted
            }
        }

        // Remove near-zero balances
        perFriend = perFriend.filter { abs($0.value) > 0.005 }

        let netAmount = perFriend.values.reduce(0, +)

        // Top 3 friends by absolute debt in the direction of net.
        //
        // **Stable order**: `perFriend` is a Dictionary, whose iteration
        // order is undefined and reshuffles between runs. Sorting only
        // by amount means two friends with equal debts (very common —
        // both owe `5.00`) can swap positions on every recompute. The
        // home split chip is recomputed on each render, so that swap
        // shows up as flicker / reorder when the user just scrolls.
        // Adding `friendID` as a deterministic tiebreaker pins the
        // order until the underlying numbers actually change.
        let topFriendIDs: [String]
        if netAmount > 0.005 {
            topFriendIDs = perFriend
                .filter { $0.value > 0 }
                .sorted { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
                }
                .prefix(3)
                .map(\.key)
        } else if netAmount < -0.005 {
            topFriendIDs = perFriend
                .filter { $0.value < 0 }
                .sorted { lhs, rhs in
                    lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
                }
                .prefix(3)
                .map(\.key)
        } else {
            topFriendIDs = []
        }

        return DebtSummary(
            perFriend: perFriend,
            netAmount: netAmount,
            topFriendIDs: topFriendIDs
        )
    }

    /// Sentinel ID representing the current user in the internal balance graph.
    /// Chosen so it cannot collide with `FriendIDGenerator` output (which is dashed).
    private static let meID = "__me__"

    /// Computes simplified per-friend debts using greedy pairing on the
    /// full participant graph (Splitwise "simplify debts" style).
    ///
    /// Only past, non-recurring-parent split transactions are considered.
    /// The result lists every friend who appeared in a valid split — friends
    /// whose simplified balance with the user nets to zero are marked with
    /// `amount == 0` so the UI can render them as "balances out".
    static func simplifiedDebts(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        now: Date = Date()
    ) -> SimplifiedDebtsSummary {
        let valid = transactions.filter { tx in
            tx.date <= now && !tx.isRecurringParent && tx.splitInfo != nil
        }
        guard !valid.isEmpty else { return .empty }

        var balances: [String: Double] = [:]
        var friendsInvolved: [String] = []
        var seenFriends = Set<String>()

        for tx in valid {
            guard let split = tx.splitInfo else { continue }

            balances[meID, default: 0] += convert(split.paidByMe - split.myShare, tx.currency, targetCurrency)

            for friend in split.friends {
                if seenFriends.insert(friend.friendID).inserted {
                    friendsInvolved.append(friend.friendID)
                }
                balances[friend.friendID, default: 0] += convert(friend.paidAmount - friend.share, tx.currency, targetCurrency)
            }
        }

        let myDebts = greedySimplify(balances: balances)

        let rows = friendsInvolved
            .map { SimplifiedDebt(friendID: $0, amount: myDebts[$0] ?? 0) }
            .sorted { lhs, rhs in
                let lhsNonZero = abs(lhs.amount) > 0.005
                let rhsNonZero = abs(rhs.amount) > 0.005
                if lhsNonZero != rhsNonZero { return lhsNonZero }
                return abs(lhs.amount) > abs(rhs.amount)
            }

        let netAmount = rows.reduce(0) { $0 + $1.amount }
        return SimplifiedDebtsSummary(rows: rows, netAmount: netAmount)
    }

    /// Past, non-recurring-parent split transactions — the set that feeds
    /// the simplified debts calculation and the list view on the debt screen.
    static func pastSplitTransactions(
        from transactions: [Transaction],
        now: Date = Date()
    ) -> [Transaction] {
        transactions.filter { tx in
            tx.date <= now && !tx.isRecurringParent && tx.splitInfo != nil
        }
    }

    /// The user's personal position in a single split transaction.
    /// Amounts are in the transaction's own currency — callers convert if needed.
    static func userPosition(in transaction: Transaction) -> UserTransactionPosition {
        guard let split = transaction.splitInfo else { return .notInvolved }
        // True "not involved" — user neither has a share nor paid
        // anything upfront, so this transaction is purely between
        // other friends.
        if split.paidByMe < 0.005 && split.myShare < 0.005 { return .notInvolved }
        let delta = split.paidByMe - split.myShare
        if delta > 0.005 { return .lent(delta) }
        if delta < -0.005 { return .borrowed(-delta) }
        // User IS a participant (share > 0 or paid > 0) but their
        // contribution and consumption cancel out — settled within
        // this single transaction. Earlier this fell through to
        // `.notInvolved`, which surfaced the wrong "you're not
        // involved" copy on perfectly balanced splits.
        return .settled
    }

    /// Computes the simplified settlement within a single split transaction.
    /// Returns one row per friend participant; rows involving the user show the
    /// transfer amount, others show 0 ("balances out"). Amounts in the transaction's
    /// own currency.
    static func perTransactionSettlement(for transaction: Transaction) -> PerTransactionSettlement {
        guard let split = transaction.splitInfo else {
            return PerTransactionSettlement(rows: [])
        }

        var balances: [String: Double] = [:]
        balances[meID] = split.paidByMe - split.myShare

        var friendOrder: [String] = []
        var seen = Set<String>()
        for friend in split.friends {
            if seen.insert(friend.friendID).inserted {
                friendOrder.append(friend.friendID)
            }
            balances[friend.friendID, default: 0] += friend.paidAmount - friend.share
        }

        let myDebts = greedySimplify(balances: balances)

        let rows = friendOrder
            .map { PerTransactionSettlement.Row(friendID: $0, amount: myDebts[$0] ?? 0) }
            .sorted { lhs, rhs in
                let lhsNonZero = abs(lhs.amount) > 0.005
                let rhsNonZero = abs(rhs.amount) > 0.005
                if lhsNonZero != rhsNonZero { return lhsNonZero }
                return abs(lhs.amount) > abs(rhs.amount)
            }
        return PerTransactionSettlement(rows: rows)
    }

    /// Greedy pairing of creditors with debtors on a pre-computed balance map.
    /// Returns only the user's resulting transfers, keyed by the counterparty ID.
    /// Positive = counterparty owes the user. Negative = user owes counterparty.
    private static func greedySimplify(balances: [String: Double]) -> [String: Double] {
        // Tiebreak on equal amounts is by ascending ID so the output stays deterministic
        // across runs — dictionary iteration order is otherwise unspecified.
        let descendingByAmount: ((id: String, amount: Double), (id: String, amount: Double)) -> Bool = { lhs, rhs in
            if lhs.amount != rhs.amount { return lhs.amount > rhs.amount }
            return lhs.id < rhs.id
        }
        var creditors = balances
            .filter { $0.value > 0.005 }
            .map { (id: $0.key, amount: $0.value) }
            .sorted(by: descendingByAmount)
        var debtors = balances
            .filter { $0.value < -0.005 }
            .map { (id: $0.key, amount: -$0.value) }
            .sorted(by: descendingByAmount)

        var myDebts: [String: Double] = [:]

        while let creditor = creditors.first, let debtor = debtors.first {
            let amount = min(creditor.amount, debtor.amount)

            if debtor.id == meID {
                myDebts[creditor.id, default: 0] -= amount
            } else if creditor.id == meID {
                myDebts[debtor.id, default: 0] += amount
            }

            let creditorRemaining = creditor.amount - amount
            let debtorRemaining = debtor.amount - amount

            if creditorRemaining < 0.005 {
                creditors.removeFirst()
            } else {
                creditors[0] = (id: creditor.id, amount: creditorRemaining)
                creditors.sort(by: descendingByAmount)
            }
            if debtorRemaining < 0.005 {
                debtors.removeFirst()
            } else {
                debtors[0] = (id: debtor.id, amount: debtorRemaining)
                debtors.sort(by: descendingByAmount)
            }
        }
        return myDebts
    }
}

import Foundation

/// Pure functions used by `CreateTransactionViewModel.buildTransaction`
/// to normalise the persisted `SplitInfo` shape before it goes to
/// SQLite. Extracted from the VM so the math is unit-testable in
/// isolation and the save path doesn't have to detour through
/// `@MainActor`-isolated state to reach static-only logic.
///
/// `nonisolated` namespace — every function is callable from any
/// actor context. Inputs are scalar shares + the friend list; no
/// reach into stores or view-model state.
enum SplitMathHelpers {

    /// Picks the `SplitMode` to persist on a `SplitInfo`. Auto-coerces
    /// any 1-payer + 1-share-bearer configuration into `.settleUp` so
    /// the UI ("X pays for Y", debt summary) reads the same regardless
    /// of which mode the user picked first.
    ///
    /// Detection rule: count distinct parties with `paidAmount > 0`
    /// (paying side) and parties with `share > 0` (receiving side). When
    /// both equal 1 and they're different parties, the shape is settle-
    /// up. The "different parties" check guards against a degenerate
    /// you-pay-you-share single-person split (1 payer, 1 share-bearer,
    /// but it's the same person — that's not a settle-up, that's a
    /// solo expense the user shouldn't have flagged as split).
    static func resolveStoredSplitMode(
        requested: SplitMode?,
        paidByMe: Double,
        myShare: Double,
        friends: [FriendShare]
    ) -> SplitMode? {
        let payerThreshold = 0.001
        let shareThreshold = 0.001

        let mePays = paidByMe > payerThreshold
        let meShares = myShare > shareThreshold
        let payingFriends = friends.filter { $0.paidAmount > payerThreshold }
        let sharingFriends = friends.filter { $0.share > shareThreshold }

        let payerCount = (mePays ? 1 : 0) + payingFriends.count
        let shareCount = (meShares ? 1 : 0) + sharingFriends.count

        guard payerCount == 1, shareCount == 1 else { return requested }

        // Confirm payer and share-bearer are distinct parties.
        if mePays && meShares { return requested }
        if let payer = payingFriends.first, let receiver = sharingFriends.first,
           payer.friendID == receiver.friendID {
            return requested
        }

        return .settleUp
    }

    /// Enforce the settle-up shape on a `SplitInfo` before it goes
    /// to SQLite. Picks the **single** payer (the one with the
    /// largest `paidAmount`, breaking ties towards "me") and the
    /// single receiver (the largest `share`, ties again towards
    /// "me"); zeroes everyone else. Without this clamp the write
    /// path could let a stale `vm.payers` from a previous draft slip
    /// a second non-zero `paidAmount` through — the debt summary
    /// then credits both "payers" and the user sees their debt
    /// halved.
    ///
    /// Inputs already passed `resolveStoredSplitMode == .settleUp`,
    /// so they are guaranteed to encode a valid pair. The helper
    /// re-asserts the invariant deterministically so a regression
    /// upstream (multiple non-zero payers / receivers) gets
    /// re-normalised rather than written through.
    static func normaliseSettleUp(
        total: Double,
        paidByMe: Double,
        myShare: Double,
        friends: [FriendShare]
    ) -> SplitInfo {
        let payerThreshold = 0.001

        // Pick the payer: largest non-zero `paidAmount` wins. Ties
        // break toward "me" because `paidByMe` is the explicit "you
        // paid" signal from the create UI.
        let friendPayer = friends
            .filter { $0.paidAmount > payerThreshold }
            .max(by: { $0.paidAmount < $1.paidAmount })
        let mePaysWins: Bool
        if paidByMe > payerThreshold, let f = friendPayer {
            mePaysWins = paidByMe >= f.paidAmount
        } else {
            mePaysWins = paidByMe > payerThreshold
        }

        // Pick the receiver: same rule on `share`.
        let friendReceiver = friends
            .filter { $0.share > payerThreshold }
            .max(by: { $0.share < $1.share })
        let meReceives: Bool
        if myShare > payerThreshold, let f = friendReceiver {
            meReceives = myShare >= f.share
        } else {
            meReceives = myShare > payerThreshold
        }

        // Normalise: the winning payer gets the full total, the
        // winning receiver gets the full total as their share,
        // everyone else is zero.
        let payerID: String = mePaysWins ? "me" : (friendPayer?.friendID ?? "me")
        let receiverID: String = meReceives ? "me" : (friendReceiver?.friendID ?? "")

        let normalisedPaidByMe: Double = (payerID == "me") ? total : 0
        let normalisedMyShare: Double = (receiverID == "me") ? total : 0

        // Build the friend list. We keep every friend that was in
        // the original payload so participant references survive,
        // but zero their amounts unless they're the picked payer or
        // receiver. That way the debt graph still resolves but
        // can't be double-counted.
        let normalisedFriends: [FriendShare] = friends.map { friend in
            let isPayer = !mePaysWins && friend.friendID == payerID
            let isReceiver = !meReceives && friend.friendID == receiverID
            return FriendShare(
                friendID: friend.friendID,
                share: isReceiver ? total : 0,
                paidAmount: isPayer ? total : 0,
                isSettled: friend.isSettled
            )
        }

        // Lent amount on a settle-up is the full total when "me"
        // paid (the user is fronting the receiver's share in cash)
        // or zero otherwise.
        let normalisedLent: Double = max(normalisedPaidByMe - normalisedMyShare, 0)

        return SplitInfo(
            totalAmount: total,
            paidByMe: normalisedPaidByMe,
            myShare: normalisedMyShare,
            lentAmount: normalisedLent,
            friends: normalisedFriends,
            splitMode: .settleUp
        )
    }
}

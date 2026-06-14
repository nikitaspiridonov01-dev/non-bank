import Foundation

/// A previously-used split configuration, surfaced as a one-tap
/// "Recently used" shortcut on the mode picker so the user can replay
/// a recent split (same mode + same people) without walking the whole
/// flow again.
///
/// Recorded on transaction SAVE (create only — never on edit) for any
/// mode except pay-for-yourself. Persisted newest-first, capped at 2,
/// and deduped by `dedupKey` so re-saving the same configuration just
/// bumps it to the top instead of stacking duplicates.
///
/// Participant identity is stored as raw IDs only — names / avatars /
/// connected-state are resolved LIVE from `FriendStore` at render time
/// so a renamed or reconnected friend always shows current data, and a
/// DELETED friend (id no longer resolving) drops the whole option from
/// the list (it can't be rendered or tapped — see the picker).
struct RecentSplitOption: Codable, Equatable, Identifiable {
    let mode: SplitMode
    /// Ordered friend IDs as they were selected (excludes "me" — the
    /// `youIncluded` flag carries the self-participation). Order is
    /// preserved so the replayed selection and avatar stack match the
    /// original.
    let friendIDs: [String]
    let youIncluded: Bool
    /// Only set for `.settleUp`. Directional: a swapped payer/recipient
    /// is a DISTINCT option. `"me"` or a `Friend.id`.
    let settleUpPayerID: String?
    let settleUpRecipientID: String?
    let createdAt: Date

    /// Stable identity used both for `Identifiable` and dedup. Two
    /// options collide (one replaces the other on `record`) iff their
    /// keys match.
    ///
    /// - Non-settle-up: mode + the SORTED friend set + the youIncluded
    ///   flag — so re-picking the same people in a different tap order
    ///   still dedups.
    /// - Settle-up: directional `"settleUp|payer>recipient"` so
    ///   "I pay Mike" and "Mike pays me" stay as two separate recents.
    var dedupKey: String {
        if mode == .settleUp {
            let payer = settleUpPayerID ?? "?"
            let recipient = settleUpRecipientID ?? "?"
            return "settleUp|\(payer)>\(recipient)"
        }
        let sorted = friendIDs.sorted().joined(separator: ",")
        return "\(mode.rawValue)|\(sorted)|you:\(youIncluded ? 1 : 0)"
    }

    var id: String { dedupKey }
}

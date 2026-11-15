import Observation

/// The friends created during one add / edit-transaction flow, newest
/// first.
///
/// The friend pickers rank people by how often you split with them
/// (`FriendUsageRanking`), so a friend just created mid-transaction — never
/// split with yet — landed at the bottom of the list, selected but out of
/// sight. Within the flow they're listed first instead: one instance lives
/// as long as the flow (`CreateTransactionModal`) and reaches every picker
/// in it through the environment. A new flow starts empty, so there the
/// usual order applies.
@Observable
final class FriendsCreatedInFlow {
    /// Newest first.
    private(set) var ids: [String] = []

    func record(_ id: String) {
        ids.removeAll { $0 == id }
        ids.insert(id, at: 0)
    }
}

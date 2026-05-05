import Foundation
import Combine

@MainActor
class FriendStore: ObservableObject {
    @Published private(set) var friends: [Friend] = []
    private let repo: FriendRepositoryProtocol
    private var hasLoaded = false

    nonisolated init(repo: FriendRepositoryProtocol = FriendRepository()) {
        self.repo = repo
        Task { await load() }
    }

    func load() async {
        friends = await repo.fetchAll()
        hasLoaded = true
    }

    func add(_ friend: Friend) async {
        guard friend.isValid else { return }
        await repo.insert(friend)
        await load()
    }

    func update(_ friend: Friend) {
        // Update locally first for immediate UI feedback, then persist
        if let idx = friends.firstIndex(where: { $0.id == friend.id }) {
            friends[idx] = friend
        }
        Task {
            await repo.update(friend)
        }
    }

    func remove(_ friend: Friend) {
        friends.removeAll { $0.id == friend.id }
        Task { await repo.delete(id: friend.id) }
    }

    func friend(byID id: String) -> Friend? {
        friends.first { $0.id == id }
    }

    /// Upgrade a phantom Friend's ID to a real userID. Used by the
    /// share-link receiver flow when the same person who was created
    /// locally (with a random ID) shares back from their actual app —
    /// at that moment we know phantom → real, so we rewrite the Friend
    /// record's primary key and mark it `isConnected = true` so the
    /// avatar switches from B&W (phantom) to colour (verified).
    ///
    /// If a Friend with `realID` already exists separately in the
    /// store, we leave both records alone — merging two named
    /// Friends could throw away user-set data and is best left to a
    /// future explicit "merge contacts" UX. We do still mark the
    /// existing real-ID Friend as connected, since the round-trip
    /// proved them to be a real user.
    ///
    /// Note: SQLite Friend table has `id` as PRIMARY KEY, so we INSERT
    /// new + DELETE old rather than UPDATE-ing in place.
    func upgradePhantom(phantomID: String, realID: String) async {
        guard phantomID != realID else { return }
        guard let phantom = friends.first(where: { $0.id == phantomID }) else {
            return
        }
        if let existingReal = friends.first(where: { $0.id == realID }) {
            // Real ID already exists — don't merge; just flag both as
            // connected so avatars colour up.
            if !existingReal.isConnected {
                let updated = Friend(
                    id: existingReal.id,
                    name: existingReal.name,
                    groups: existingReal.groups,
                    splitMode: existingReal.splitMode,
                    isConnected: true
                )
                update(updated)
            }
            return
        }
        // Insert a new row with the real ID, copy across name/groups/
        // mode, mark connected. Then drop the phantom row.
        let upgraded = Friend(
            id: realID,
            name: phantom.name,
            groups: phantom.groups,
            splitMode: phantom.splitMode,
            isConnected: true
        )
        await add(upgraded)
        await repo.delete(id: phantomID)
        await load()
    }

    /// All distinct group names from existing friends.
    var allGroups: [String] {
        Array(Set(friends.flatMap { $0.groups })).sorted()
    }
}

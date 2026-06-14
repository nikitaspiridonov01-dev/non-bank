import Foundation
import Combine

@MainActor
class FriendStore: ObservableObject {
    @Published private(set) var friends: [Friend] = []
    /// `true` after the first `load()` finishes. Surfaced to the view
    /// layer (via `@Published`) so FriendsView can show a skeleton
    /// placeholder during cold-launch instead of flashing the empty
    /// illustration before SQLite is ready.
    @Published private(set) var hasLoadedOnce: Bool = false
    private let repo: FriendRepositoryProtocol
    private var hasLoaded = false
    /// Set in `MainTabView` after both stores exist. Weak so the
    /// store doesn't retain the SyncManager (which already retains
    /// references to the stores).
    weak var syncManager: SyncManager?

    /// Resolved on first access from the DI container. Lazy so the
    /// store can be constructed before DI registration (the
    /// `nonisolated init` runs in `@StateObject` property
    /// initialisation, which can fire before `non_bankApp.init`
    /// finishes `registerDefaults`).
    @MainActor
    private lazy var analytics: AnalyticsServiceProtocol =
        DIContainer.shared.resolve(AnalyticsServiceProtocol.self)

    nonisolated init(repo: FriendRepositoryProtocol = FriendRepository()) {
        self.repo = repo
        Task { await load() }
    }

    func load() async {
        friends = await repo.fetchAll()
        hasLoaded = true
        hasLoadedOnce = true
    }

    func add(_ friend: Friend) async {
        guard friend.isValid else { return }
        await repo.insert(friend)
        await load()
        await syncManager?.pushFriend(friend, action: .save)
        // Analytics: `friend.isConnected` distinguishes share-link-
        // upgraded friends (came through a real round-trip) from
        // manual ones. The activation event also fires only once
        // per install.
        let source: FriendCreationSource = friend.isConnected ? .shareLink : .manual
        analytics.track(.friendCreated(source: source))
        analytics.recordFeatureUseIfFirst(.friends)
        analytics.recordActivationFirstFriendIfNeeded(source: source)
    }

    func update(_ friend: Friend) {
        // Update locally first for immediate UI feedback, then persist
        if let idx = friends.firstIndex(where: { $0.id == friend.id }) {
            friends[idx] = friend
        }
        Task {
            await repo.update(friend)
            await syncManager?.pushFriend(friend, action: .save)
        }
        analytics.track(.friendEdited)
    }

    func remove(_ friend: Friend) {
        friends.removeAll { $0.id == friend.id }
        Task {
            await repo.delete(id: friend.id)
            await syncManager?.pushFriend(friend, action: .delete)
            // Server-sync (CC2): removing a PAIRED friend revokes the
            // server pairing so future split transactions no longer
            // auto-deliver in EITHER direction (the pairing is one symmetric
            // row per pair). Best-effort — the local delete already
            // happened; the recipient's own upload would also start getting
            // 409 'pairing_inactive'. Locally, the friend is gone from
            // `friends`, so this device also stops uploading to / decrypting
            // from them.
            if friend.isConnected {
                let pairHMAC = SyncPairing.pairHMAC(UserIDService.currentID(), friend.id)
                await SyncDeliveryService.revoke(pairHMAC: pairHMAC)
            }
        }
        // `hadSplits` is true if the friend appears on any split-
        // mode transaction — useful for "are users deleting active
        // friends or just contact-list cleanup."
        let hadSplits = false  // we don't have a TX cross-reference
                               // here without a wider rewrite; default
                               // conservatively until the integration
                               // surfaces a real signal.
        analytics.track(.friendDeleted(hadSplits: hadSplits))
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
        await syncManager?.pushFriend(phantom, action: .delete)
        await load()
    }

    /// Mark an existing friend connected (colour their avatar) WITHOUT an id
    /// change — used when a pairing handshake confirms a friend whose id is
    /// already their real user id but wasn't flagged connected yet.
    func markConnected(id: String) {
        guard let f = friends.first(where: { $0.id == id }), !f.isConnected else { return }
        update(Friend(id: f.id, name: f.name, groups: f.groups, splitMode: f.splitMode, isConnected: true))
    }

    /// All distinct group names from existing friends.
    var allGroups: [String] {
        Array(Set(friends.flatMap { $0.groups })).sorted()
    }
}

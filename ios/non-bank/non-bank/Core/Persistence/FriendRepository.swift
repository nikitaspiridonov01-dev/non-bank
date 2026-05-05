import Foundation

/// Protocol for friend data access.
protocol FriendRepositoryProtocol {
    func fetchAll() async -> [Friend]
    func insert(_ friend: Friend) async
    func update(_ friend: Friend) async
    func delete(id: String) async
}

/// Production implementation backed by DatabaseProtocol.
final class FriendRepository: FriendRepositoryProtocol {
    private let db: DatabaseProtocol

    init(db: DatabaseProtocol = SQLiteService.shared) {
        self.db = db
    }

    func fetchAll() async -> [Friend] {
        await db.fetchAllFriends()
    }

    func insert(_ friend: Friend) async {
        await db.insertFriend(friend)
    }

    func update(_ friend: Friend) async {
        await db.updateFriend(friend)
    }

    func delete(id: String) async {
        await db.deleteFriend(id: id)
    }
}

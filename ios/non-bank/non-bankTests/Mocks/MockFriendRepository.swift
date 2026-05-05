import Foundation
@testable import non_bank

final class MockFriendRepository: FriendRepositoryProtocol, @unchecked Sendable {
    var friends: [Friend] = []
    private(set) var insertCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    func fetchAll() async -> [Friend] { friends }

    func insert(_ friend: Friend) async {
        insertCallCount += 1
        friends.append(friend)
    }

    func update(_ friend: Friend) async {
        updateCallCount += 1
        if let idx = friends.firstIndex(where: { $0.id == friend.id }) {
            friends[idx] = friend
        }
    }

    func delete(id: String) async {
        deleteCallCount += 1
        friends.removeAll { $0.id == id }
    }
}

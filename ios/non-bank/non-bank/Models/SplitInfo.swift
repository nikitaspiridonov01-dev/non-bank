import Foundation

/// Describes how a transaction is split among friends.
struct SplitInfo: Codable, Equatable {
    /// The full purchase amount before splitting
    let totalAmount: Double
    /// How much I actually paid out of pocket
    let paidByMe: Double
    /// My fair share of the total
    let myShare: Double
    /// Money I lent to others (I paid more than my share)
    let lentAmount: Double
    /// References to friends involved in the split, with their shares
    let friends: [FriendShare]
    /// How the split was calculated (nil for legacy data)
    let splitMode: SplitMode?

    init(
        totalAmount: Double,
        paidByMe: Double,
        myShare: Double,
        lentAmount: Double,
        friends: [FriendShare],
        splitMode: SplitMode? = nil
    ) {
        self.totalAmount = totalAmount
        self.paidByMe = paidByMe
        self.myShare = myShare
        self.lentAmount = lentAmount
        self.friends = friends
        self.splitMode = splitMode
    }
}

/// A friend's portion in a split transaction.
struct FriendShare: Codable, Equatable, Identifiable {
    let friendID: String
    let share: Double
    /// How much this friend actually paid (0 if they didn't pay)
    let paidAmount: Double
    /// Whether this friend has settled their debt (future scope for repayment tracking)
    let isSettled: Bool

    var id: String { friendID }

    init(friendID: String, share: Double, paidAmount: Double = 0, isSettled: Bool = false) {
        self.friendID = friendID
        self.share = share
        self.paidAmount = paidAmount
        self.isSettled = isSettled
    }

    // Custom decoding for backwards compatibility (paidAmount may be missing in old data)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        friendID = try container.decode(String.self, forKey: .friendID)
        share = try container.decode(Double.self, forKey: .share)
        paidAmount = try container.decodeIfPresent(Double.self, forKey: .paidAmount) ?? 0
        isSettled = try container.decode(Bool.self, forKey: .isSettled)
    }
}

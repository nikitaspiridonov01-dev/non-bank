import Foundation

/// A person who can participate in split transactions.
struct Friend: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let groups: [String]
    let splitMode: SplitMode?
    let lastModified: Date

    /// Whether this Friend's `id` corresponds to a real, verified user
    /// userID rather than a locally-generated placeholder. Set to true
    /// when:
    ///  - The Friend was created from an incoming share-link (the
    ///    sharer's `payload.s` is by definition a real `UserIDService`
    ///    value, not a phantom).
    ///  - A previously-phantom Friend was upgraded after the receiver
    ///    detected a share-back from that contact (their phantom ID was
    ///    swapped for their real userID).
    ///
    /// Used by the avatar render to show **colored** pixel-cat for
    /// connected friends and **black-and-white** for phantoms — a
    /// subtle visual cue that "we know this person is real" vs "this
    /// is just a name you typed locally."
    let isConnected: Bool

    init(
        id: String = FriendIDGenerator.generate(),
        name: String,
        groups: [String] = [],
        splitMode: SplitMode? = nil,
        lastModified: Date = Date(),
        isConnected: Bool = false
    ) {
        self.id = id
        self.name = name
        self.groups = groups
        self.splitMode = splitMode
        self.lastModified = lastModified
        self.isConnected = isConnected
    }

    var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    // Backward-compatible decoding: existing rows in the DB don't have
    // `isConnected` (it's a Phase-4 addition). Default to `false` so
    // pre-feature friends render as phantoms — true to their actual
    // unconnected state.
    enum CodingKeys: String, CodingKey {
        case id, name, groups, splitMode, lastModified, isConnected
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        groups = try container.decodeIfPresent([String].self, forKey: .groups) ?? []
        splitMode = try container.decodeIfPresent(SplitMode.self, forKey: .splitMode)
        lastModified = try container.decode(Date.self, forKey: .lastModified)
        isConnected = try container.decodeIfPresent(Bool.self, forKey: .isConnected) ?? false
    }
}

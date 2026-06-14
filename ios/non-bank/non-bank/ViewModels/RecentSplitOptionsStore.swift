import Foundation
import Combine

/// Persists the user's most-recent split configurations so the mode
/// picker can offer one-tap "Recently used" shortcuts.
///
/// Mirrors `CurrencyStore`'s shape: publishes a `@Published` list and
/// persists it as a Codable JSON blob through `KeyValueStoreProtocol`
/// (`UserDefaultsService` in production). Injected at the app root as
/// an `@EnvironmentObject` alongside `CurrencyStore` / `FriendStore`.
///
/// Invariants:
///  - Newest-first ordering.
///  - Capped at `maxOptions` (2) entries.
///  - Deduped by `RecentSplitOption.dedupKey` — recording an option
///    whose key already exists drops the old entry and prepends the
///    fresh one (so it floats to the top with an updated timestamp).
final class RecentSplitOptionsStore: ObservableObject {
    /// Max shortcuts kept / shown. Locked at 2 per the feature spec.
    static let maxOptions = 2

    @Published private(set) var options: [RecentSplitOption] = []

    private let storageKey = "recentSplitOptions"
    private let store: KeyValueStoreProtocol

    init(store: KeyValueStoreProtocol = UserDefaultsService()) {
        self.store = store
        if let data = store.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([RecentSplitOption].self, from: data) {
            self.options = decoded
        }
    }

    /// Record a freshly-saved split configuration. Removes any existing
    /// entry with the same `dedupKey`, prepends the new one, and trims
    /// to `maxOptions` — keeping the list newest-first.
    func record(_ option: RecentSplitOption) {
        var updated = options.filter { $0.dedupKey != option.dedupKey }
        updated.insert(option, at: 0)
        if updated.count > Self.maxOptions {
            updated = Array(updated.prefix(Self.maxOptions))
        }
        options = updated
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(options) {
            store.set(data, forKey: storageKey)
        }
    }
}

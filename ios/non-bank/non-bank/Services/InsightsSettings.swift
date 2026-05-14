import Foundation
import Combine

/// Single source of truth for the "Insights and analytics" behaviour
/// toggle shown in Settings. Controls whether split-transaction
/// analytics use the user's real share (`splitInfo.myShare`) or the
/// out-of-pocket amount (`paidByMe`).
///
/// Defaults to ON — new users see "potential expenses and debts"
/// counted by default, which matches the mental model "this is what
/// the purchase cost me", regardless of whose card paid.
///
/// Backed by `NSUbiquitousKeyValueStore` so the preference syncs
/// across the user's signed-in iCloud devices, with a UserDefaults
/// mirror for the unsigned/offline case. iCloud key-value changes are
/// observed and republished so an update on another device reflows
/// the analytics screen here without a relaunch.
@MainActor
final class InsightsSettings: ObservableObject {
    static let shared = InsightsSettings()

    private enum Keys {
        /// When true, split transactions contribute `splitInfo.myShare`
        /// to insights; row labels switch to "Your share". When false,
        /// behaviour reverts to the pre-feature state: split rows show
        /// `paidByMe` and insights count the out-of-pocket payment.
        static let includePotentialExpenses = "insights.includePotentialExpenses"
    }

    @Published var includePotentialExpenses: Bool {
        didSet {
            UserDefaults.standard.set(includePotentialExpenses, forKey: Keys.includePotentialExpenses)
            iCloudStore.set(includePotentialExpenses, forKey: Keys.includePotentialExpenses)
            iCloudStore.synchronize()
        }
    }

    private let iCloudStore = NSUbiquitousKeyValueStore.default

    private init() {
        // Defaults to true — new behaviour is the spec'd default. Old
        // UserDefaults installs without this key get true. iCloud wins
        // if it has a value (a fresh install on a second device should
        // pick up the user's existing preference).
        let cloudHasValue = iCloudStore.object(forKey: Keys.includePotentialExpenses) != nil
        let localHasValue = UserDefaults.standard.object(forKey: Keys.includePotentialExpenses) != nil
        if cloudHasValue {
            self.includePotentialExpenses = iCloudStore.bool(forKey: Keys.includePotentialExpenses)
        } else if localHasValue {
            self.includePotentialExpenses = UserDefaults.standard.bool(forKey: Keys.includePotentialExpenses)
        } else {
            self.includePotentialExpenses = true
        }
        iCloudStore.synchronize()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleCloudChange(_:)),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: iCloudStore
        )
    }

    /// Fires when the iCloud key-value store gets an update from
    /// another device. We only republish for the keys we own, and we
    /// avoid the didSet write-back loop by writing through the same
    /// `iCloudStore` we just read from (the system collapses no-op
    /// writes; the UserDefaults mirror also stays in sync).
    @objc private func handleCloudChange(_ note: Notification) {
        guard let keys = note.userInfo?[NSUbiquitousKeyValueStoreChangedKeysKey] as? [String] else { return }
        if keys.contains(Keys.includePotentialExpenses) {
            let newValue = iCloudStore.bool(forKey: Keys.includePotentialExpenses)
            if newValue != includePotentialExpenses {
                Task { @MainActor in
                    self.includePotentialExpenses = newValue
                }
            }
        }
    }
}

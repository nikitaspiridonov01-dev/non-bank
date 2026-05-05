import Foundation

/// Tracks the highest occurrence-date acknowledged for each recurring parent.
///
/// An occurrence is "acknowledged" when it's either successfully spawned as a
/// child transaction OR explicitly deleted by the user. Without this, deleting
/// an auto-spawned child causes `ReminderService.transactionsNeedingSpawn` to
/// re-create it on the next cycle, since it infers progress from the current
/// set of children.
///
/// State is persisted in `UserDefaults` keyed by the parent's `syncID` so it
/// survives process relaunches. Cleared when the parent reminder is deleted.
enum SpawnTracker {
    private static let key = "recurring.spawnAcks"

    /// The latest acknowledged occurrence for `parentSyncID`, or nil if none.
    static func lastAcknowledged(parentSyncID: String, defaults: UserDefaults = .standard) -> Date? {
        guard let raw = defaults.dictionary(forKey: key) as? [String: Double],
              let timestamp = raw[parentSyncID] else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }

    /// Record that the given occurrence is handled (spawned or deleted).
    /// Never moves backwards — only bumps the stored ack if `date` is later.
    static func acknowledge(parentSyncID: String, at date: Date, defaults: UserDefaults = .standard) {
        var raw = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        let ts = date.timeIntervalSince1970
        if let existing = raw[parentSyncID], existing >= ts { return }
        raw[parentSyncID] = ts
        defaults.set(raw, forKey: key)
    }

    /// Remove all tracking for a parent — used when the parent reminder is
    /// deleted so a fresh reminder with the same syncID (shouldn't happen, but
    /// just in case) doesn't inherit stale state.
    static func clear(parentSyncID: String, defaults: UserDefaults = .standard) {
        var raw = (defaults.dictionary(forKey: key) as? [String: Double]) ?? [:]
        guard raw.removeValue(forKey: parentSyncID) != nil else { return }
        defaults.set(raw, forKey: key)
    }
}

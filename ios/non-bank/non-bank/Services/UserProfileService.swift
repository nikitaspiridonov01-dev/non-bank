import Foundation

// MARK: - User Profile Service

/// Persists the user-supplied display name shown to people they share
/// transactions with. Backed by `UserDefaults` (not Keychain) — the name
/// isn't a security secret and the receiver-side flow tolerates it being
/// missing, so survival across app deletion isn't worth the Keychain
/// complexity.
///
/// ## Where the name shows up
///
/// - Embedded in the share-link payload as `sn` (sharer name) so the
///   receiver's app can render the sharer as a friend with a real name
///   instead of the generic `"Friend"` placeholder.
/// - `nil` until the user explicitly sets one. Share flow detects the
///   nil case and prompts before producing the URL.
enum UserProfileService {

    private static let displayNameKey = "user_profile_display_name"

    /// The user's chosen display name, if any. Whitespace-trimmed; empty
    /// strings are treated as nil so a previously-set name that the user
    /// then cleared is correctly reported as "not set".
    static func displayName() -> String? {
        guard let raw = UserDefaults.standard.string(forKey: displayNameKey) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Convenience: `true` when no name is set yet. Used by the share
    /// flow to decide whether to show the "What's your name?" prompt.
    static var isNameSet: Bool { displayName() != nil }

    /// Persist a new name. Whitespace-trimmed; empty strings clear the
    /// stored value (semantic equivalent of "unset").
    static func setDisplayName(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            UserDefaults.standard.removeObject(forKey: displayNameKey)
        } else {
            UserDefaults.standard.set(trimmed, forKey: displayNameKey)
        }
    }
}

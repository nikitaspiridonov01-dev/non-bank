import Foundation
import Security

/// Manages a persistent user ID that is:
/// - Bound to the iCloud account when sync is enabled (via NSUbiquitousKeyValueStore)
/// - Bound to the device when sync is disabled (via Keychain — survives app deletion)
///
/// The ID is generated once using `FriendIDGenerator` and persisted permanently.
enum UserIDService {

    private static let cloudKey = "app_user_id"

    // Keychain constants
    private static let keychainService = "com.nonbank.user-id"
    private static let keychainAccount = "app_user_id"

    /// Returns the current user ID, creating one if needed.
    static func currentID() -> String {
        if SyncManager.isCloudKitEnabled,
           UserDefaults.standard.bool(forKey: SyncManager.syncEnabledKey) {
            return resolveWithCloud()
        }
        return resolveLocal()
    }

    // MARK: - iCloud-bound

    /// Priority: cloud > keychain > generate new.
    private static func resolveWithCloud() -> String {
        let cloud = NSUbiquitousKeyValueStore.default
        cloud.synchronize()

        if let cloudID = cloud.string(forKey: cloudKey), !cloudID.isEmpty {
            // Cache in Keychain for offline access
            saveToKeychain(cloudID)
            return cloudID
        }

        if let localID = readFromKeychain(), !localID.isEmpty {
            // Push existing device ID to cloud
            cloud.set(localID, forKey: cloudKey)
            return localID
        }

        let newID = FriendIDGenerator.generate()
        cloud.set(newID, forKey: cloudKey)
        saveToKeychain(newID)
        return newID
    }

    // MARK: - Device-bound (Keychain)

    private static func resolveLocal() -> String {
        if let localID = readFromKeychain(), !localID.isEmpty {
            return localID
        }

        let newID = FriendIDGenerator.generate()
        saveToKeychain(newID)
        return newID
    }

    // MARK: - Keychain helpers

    private static func readFromKeychain() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let data = result as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func saveToKeychain(_ value: String) {
        guard let data = value.data(using: .utf8) else { return }

        // Try to update existing item first
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)

        if updateStatus == errSecItemNotFound {
            // Item doesn't exist yet — add it
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(addQuery as CFDictionary, nil)
        }
    }
}

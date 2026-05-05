import Foundation

/// Protocol for key-value persistence (UserDefaults abstraction).
/// Allows mocking in tests and swapping storage backends.
protocol KeyValueStoreProtocol {
    func string(forKey key: String) -> String?
    func set(_ value: String?, forKey key: String)
    func data(forKey key: String) -> Data?
    func set(_ data: Data?, forKey key: String)
}

/// Production implementation backed by UserDefaults.
final class UserDefaultsService: KeyValueStoreProtocol {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    func set(_ value: String?, forKey key: String) {
        defaults.setValue(value, forKey: key)
    }

    func data(forKey key: String) -> Data? {
        defaults.data(forKey: key)
    }

    func set(_ data: Data?, forKey key: String) {
        defaults.set(data, forKey: key)
    }
}

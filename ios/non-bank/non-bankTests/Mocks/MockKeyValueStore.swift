import Foundation
@testable import non_bank

final class MockKeyValueStore: KeyValueStoreProtocol {
    private var strings: [String: String] = [:]
    private var dataStore: [String: Data] = [:]

    func string(forKey key: String) -> String? { strings[key] }

    func set(_ value: String?, forKey key: String) {
        strings[key] = value
    }

    func data(forKey key: String) -> Data? { dataStore[key] }

    func set(_ data: Data?, forKey key: String) {
        dataStore[key] = data
    }
}

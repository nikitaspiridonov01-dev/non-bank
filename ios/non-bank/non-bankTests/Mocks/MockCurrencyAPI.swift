import Foundation
@testable import non_bank

final class MockCurrencyAPI: CurrencyAPIProtocol, @unchecked Sendable {
    var ratesToReturn: [String: Double] = ["USD": 1.0, "EUR": 0.92]
    var shouldThrow = false
    private(set) var fetchCallCount = 0

    func fetchLatestRates(base: String) async throws -> [String: Double] {
        fetchCallCount += 1
        if shouldThrow { throw NetworkError.badResponse }
        return ratesToReturn
    }
}

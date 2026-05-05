import Foundation
@testable import non_bank

final class MockNetworkClient: NetworkClientProtocol, @unchecked Sendable {
    var dataToReturn: Data = Data()
    var shouldThrow = false
    private(set) var fetchCallCount = 0
    private(set) var lastRequestedURL: URL?

    func fetchData(from url: URL) async throws -> Data {
        fetchCallCount += 1
        lastRequestedURL = url
        if shouldThrow { throw NetworkError.badResponse }
        return dataToReturn
    }
}

import Foundation

/// Minimal protocol for making network requests — allows mocking in tests.
protocol NetworkClientProtocol {
    func fetchData(from url: URL) async throws -> Data
}

/// Production implementation using URLSession.
final class NetworkClient: NetworkClientProtocol {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw NetworkError.badResponse
        }
        return data
    }
}

enum NetworkError: Error {
    case badResponse
    case decodingFailed
}

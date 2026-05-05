import Foundation

/// Fetches exchange rates from the Frankfurter API.
protocol CurrencyAPIProtocol {
    func fetchLatestRates(base: String) async throws -> [String: Double]
}

final class CurrencyAPI: CurrencyAPIProtocol {
    private let client: NetworkClientProtocol
    private let baseURL = "https://api.frankfurter.dev/v2"

    init(client: NetworkClientProtocol = NetworkClient()) {
        self.client = client
    }

    func fetchLatestRates(base: String = "USD") async throws -> [String: Double] {
        guard let url = URL(string: "\(baseURL)/rates?base=\(base)") else {
            throw NetworkError.badResponse
        }
        let data = try await client.fetchData(from: url)

        // v2 returns array: [{"base":"USD","quote":"EUR","rate":0.92,...}, ...]
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw NetworkError.decodingFailed
        }

        var result: [String: Double] = [base: 1.0]
        for item in array {
            if let quote = item["quote"] as? String,
               let rate = item["rate"] as? Double {
                result[quote] = rate
            }
        }
        return result
    }
}

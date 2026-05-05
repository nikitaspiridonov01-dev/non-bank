import XCTest
@testable import non_bank

final class CurrencyAPITests: XCTestCase {

    private var mockClient: MockNetworkClient!
    private var sut: CurrencyAPI!

    override func setUp() {
        super.setUp()
        mockClient = MockNetworkClient()
        sut = CurrencyAPI(client: mockClient)
    }

    // MARK: - fetchLatestRates

    func testFetchLatestRates_parsesV2Format() async throws {
        // Frankfurter v2 returns an array of objects
        let json: [[String: Any]] = [
            ["base": "USD", "quote": "EUR", "rate": 0.92],
            ["base": "USD", "quote": "GBP", "rate": 0.79],
        ]
        mockClient.dataToReturn = try JSONSerialization.data(withJSONObject: json)

        let rates = try await sut.fetchLatestRates(base: "USD")
        XCTAssertEqual(rates["USD"], 1.0) // base always 1.0
        XCTAssertEqual(rates["EUR"], 0.92)
        XCTAssertEqual(rates["GBP"], 0.79)
        XCTAssertEqual(mockClient.fetchCallCount, 1)
    }

    func testFetchLatestRates_networkError_throws() async {
        mockClient.shouldThrow = true

        do {
            _ = try await sut.fetchLatestRates(base: "USD")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is NetworkError)
        }
    }

    func testFetchLatestRates_invalidJSON_throws() async {
        mockClient.dataToReturn = Data("not json".utf8)

        do {
            _ = try await sut.fetchLatestRates(base: "USD")
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is NetworkError)
        }
    }
}

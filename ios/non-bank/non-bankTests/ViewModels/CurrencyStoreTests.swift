import XCTest
@testable import non_bank

final class CurrencyStoreTests: XCTestCase {

    private var mockStore: MockKeyValueStore!
    private var mockAPI: MockCurrencyAPI!
    private var sut: CurrencyStore!

    override func setUp() {
        super.setUp()
        mockStore = MockKeyValueStore()
        mockAPI = MockCurrencyAPI()
        sut = CurrencyStore(
            store: mockStore,
            converter: CurrencyService(),
            api: mockAPI
        )
    }

    // MARK: - Convert

    func testConvert_sameCurrency() {
        let result = sut.convert(amount: 100, from: "USD", to: "USD")
        XCTAssertEqual(result, 100.0)
    }

    func testConvertFromUsd() {
        let result = sut.convertFromUsd(amount: 100, to: "EUR")
        // Uses default rates from CurrencyStore; EUR=0.92
        XCTAssertEqual(result, 92.0, accuracy: 0.1)
    }

    func testConvertToUsd() {
        let result = sut.convertToUsd(amount: 92, from: "EUR")
        XCTAssertEqual(result, 100.0, accuracy: 0.1)
    }

    // MARK: - Persistence

    func testSelectedCurrency_persistedToStore() {
        sut.selectedCurrency = "EUR"
        // Combine sink should persist
        let persisted = mockStore.string(forKey: "selectedCurrency")
        XCTAssertEqual(persisted, "EUR")
    }

    func testSelectedCurrency_restoredFromStore() {
        mockStore.set("GBP", forKey: "selectedCurrency")
        let store = CurrencyStore(store: mockStore, converter: CurrencyService(), api: mockAPI)
        XCTAssertEqual(store.selectedCurrency, "GBP")
    }

    func testRates_restoredFromStore() {
        let rates: [String: Double] = ["USD": 1.0, "EUR": 0.95]
        let data = try! JSONEncoder().encode(rates)
        mockStore.set(data, forKey: "usdRates")

        let store = CurrencyStore(store: mockStore, converter: CurrencyService(), api: mockAPI)
        XCTAssertEqual(store.usdRates["EUR"], 0.95)
    }

    // MARK: - Fetch

    func testFetchRatesFrankfurter_success() {
        let exp = expectation(description: "fetch")
        mockAPI.ratesToReturn = ["USD": 1.0, "EUR": 0.90, "GBP": 0.78]

        sut.fetchRatesFrankfurter { success in
            XCTAssertTrue(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
        XCTAssertEqual(sut.usdRates["GBP"], 0.78)
    }

    func testFetchRatesFrankfurter_failure() {
        let exp = expectation(description: "fetch")
        mockAPI.shouldThrow = true

        sut.fetchRatesFrankfurter { success in
            XCTAssertFalse(success)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2.0)
    }

    // MARK: - Currency Options

    func testCurrencyOptions_baseCurrencyFirst() {
        sut.selectedCurrency = "EUR"
        let options = sut.currencyOptions
        XCTAssertEqual(options.first, "EUR")
    }

    func testCurrencyOptions_sortedByUsage() {
        sut.selectedCurrency = "USD"
        // Add transactions to influence sorting
        sut.updateTransactions([
            TestFixtures.makeTransaction(id: 1, currency: "EUR"),
            TestFixtures.makeTransaction(id: 2, currency: "EUR"),
            TestFixtures.makeTransaction(id: 3, currency: "RUB"),
        ])
        let options = sut.currencyOptions
        // USD first (base), then EUR (2 uses), then RUB (1 use)
        XCTAssertEqual(options[0], "USD")
        guard let eurIdx = options.firstIndex(of: "EUR"),
              let rubIdx = options.firstIndex(of: "RUB") else {
            XCTFail("EUR or RUB missing from options")
            return
        }
        XCTAssertLessThan(eurIdx, rubIdx)
    }
}

import XCTest
@testable import non_bank

final class CurrencyServiceTests: XCTestCase {

    private let sut = CurrencyService()
    private let rates: [String: Double] = ["USD": 1.0, "EUR": 0.92, "RUB": 84.0]

    func testConvertFromUsd() {
        let result = sut.convertFromUsd(amount: 100, to: "EUR", rates: rates)
        XCTAssertEqual(result, 92.0, accuracy: 0.01)
    }

    func testConvertToUsd() {
        let result = sut.convertToUsd(amount: 92, from: "EUR", rates: rates)
        XCTAssertEqual(result, 100.0, accuracy: 0.01)
    }

    func testConvert_sameCurrency_returnsOriginal() {
        let result = sut.convert(amount: 50, from: "USD", to: "USD", rates: rates)
        XCTAssertEqual(result, 50.0)
    }

    func testConvert_crossCurrency() {
        // EUR→RUB via USD: 100 EUR → 100/0.92 USD → (100/0.92)*84 RUB
        let result = sut.convert(amount: 100, from: "EUR", to: "RUB", rates: rates)
        let expected = (100.0 / 0.92) * 84.0
        XCTAssertEqual(result, expected, accuracy: 0.01)
    }

    func testConvert_unknownCurrency_returnsAmount() {
        // Unknown currency not in rates — falls back to amount unchanged
        let result = sut.convertToUsd(amount: 100, from: "XYZ", rates: rates)
        XCTAssertEqual(result, 100.0)
    }

    func testConvertFromUsd_unknownCurrency_returnsAmount() {
        let result = sut.convertFromUsd(amount: 100, to: "XYZ", rates: rates)
        XCTAssertEqual(result, 100.0)
    }
}

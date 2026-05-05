import XCTest
@testable import non_bank

final class NumberFormattingTests: XCTestCase {

    // MARK: - integerPart

    func testIntegerPart_simple() {
        XCTAssertEqual(NumberFormatting.integerPart(1234.56), "1 234")
    }

    func testIntegerPart_zero() {
        XCTAssertEqual(NumberFormatting.integerPart(0), "0")
    }

    func testIntegerPart_negative() {
        // Uses absolute value
        XCTAssertEqual(NumberFormatting.integerPart(-9999.99), "9 999")
    }

    func testIntegerPart_large() {
        XCTAssertEqual(NumberFormatting.integerPart(1_234_567.89), "1 234 567")
    }

    // MARK: - decimalPart

    func testDecimalPart_normal() {
        XCTAssertEqual(NumberFormatting.decimalPart(1234.56), ".56")
    }

    func testDecimalPart_zero() {
        XCTAssertEqual(NumberFormatting.decimalPart(100.0), ".00")
    }

    func testDecimalPart_smallFraction() {
        XCTAssertEqual(NumberFormatting.decimalPart(10.05), ".05")
    }

    func testDecimalPart_negative() {
        XCTAssertEqual(NumberFormatting.decimalPart(-50.75), ".75")
    }

    // MARK: - balanceSign

    func testBalanceSign_positive() {
        XCTAssertEqual(NumberFormatting.balanceSign(100), "+")
    }

    func testBalanceSign_negative() {
        XCTAssertEqual(NumberFormatting.balanceSign(-100), "-")
    }

    func testBalanceSign_zero() {
        XCTAssertEqual(NumberFormatting.balanceSign(0), "-")
    }
}

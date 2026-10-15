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

    // MARK: - Values with more than two decimals (even-split shares)
    //
    // 38.99 / 3 = 12.996666… used to render as "12" + ".00": the integer
    // part was truncated while the cents were rounded separately. Both
    // pieces now come from the same rounding, so it reads "13" + ".00".

    func testIntegerPart_roundsUpWhenCentsCarry() {
        XCTAssertEqual(NumberFormatting.integerPart(12.996666), "13")
        XCTAssertEqual(NumberFormatting.integerPart(0.996666), "1")
        XCTAssertEqual(NumberFormatting.integerPart(999.995), "1 000")
    }

    func testDecimalPart_whenCentsCarry() {
        XCTAssertEqual(NumberFormatting.decimalPart(12.996666), ".00")
        XCTAssertEqual(NumberFormatting.decimalPart(33.333333), ".33")
        XCTAssertEqual(NumberFormatting.decimalPart(16.995), ".00")
    }

    func testDecimalPartIfAny_whenCentsCarry() {
        XCTAssertEqual(NumberFormatting.decimalPartIfAny(12.996666), "")
        XCTAssertEqual(NumberFormatting.decimalPartIfAny(12.50), ".50")
        XCTAssertEqual(NumberFormatting.decimalPartIfAny(12.004), "")
        XCTAssertEqual(NumberFormatting.decimalPartIfAny(12.005), ".01")
    }

    func testAmount_combinesBothPartsConsistently() {
        XCTAssertEqual(NumberFormatting.amount(12.996666), "13")
        XCTAssertEqual(NumberFormatting.amount(1234.5), "1 234.50")
        XCTAssertEqual(NumberFormatting.amount(-7.25), "7.25")
        XCTAssertEqual(NumberFormatting.amountWithCents(12.996666), "13.00")
        XCTAssertEqual(NumberFormatting.amountWithCents(1234.5), "1 234.50")
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

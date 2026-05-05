import XCTest
@testable import non_bank

final class ImportFieldParserTests: XCTestCase {

    // MARK: - parseAmount

    func testParseAmount_integer() {
        XCTAssertEqual(ImportFieldParser.parseAmount(1000), 1000)
    }

    func testParseAmount_double() {
        XCTAssertEqual(ImportFieldParser.parseAmount(99.99), 99.99)
    }

    func testParseAmount_stringSimple() {
        XCTAssertEqual(ImportFieldParser.parseAmount("1000"), 1000)
    }

    func testParseAmount_stringWithCommaDecimal() {
        // "1.000,50" → 1000.50
        XCTAssertEqual(ImportFieldParser.parseAmount("1.000,50"), 1000.50)
    }

    func testParseAmount_stringWithDotDecimal() {
        // "1,000.50" → 1000.50
        XCTAssertEqual(ImportFieldParser.parseAmount("1,000.50"), 1000.50)
    }

    func testParseAmount_stringWithSpaces() {
        XCTAssertEqual(ImportFieldParser.parseAmount("1 000"), 1000)
    }

    func testParseAmount_negative() {
        XCTAssertEqual(ImportFieldParser.parseAmount("-500"), -500)
    }

    func testParseAmount_positive_sign() {
        XCTAssertEqual(ImportFieldParser.parseAmount("+500"), 500)
    }

    func testParseAmount_nil() {
        XCTAssertNil(ImportFieldParser.parseAmount(nil))
    }

    func testParseAmount_emptyString() {
        XCTAssertNil(ImportFieldParser.parseAmount(""))
    }

    func testParseAmount_commaAsDecimal_twoDigits() {
        // "99,50" → 99.50 (comma with ≤2 digits after = decimal)
        XCTAssertEqual(ImportFieldParser.parseAmount("99,50"), 99.50)
    }

    func testParseAmount_commaAsThousand() {
        // "1,000" → 1000 (3 digits after comma = thousand separator)
        XCTAssertEqual(ImportFieldParser.parseAmount("1,000"), 1000)
    }

    // MARK: - parseCurrency

    func testParseCurrency_valid() {
        XCTAssertEqual(ImportFieldParser.parseCurrency("usd"), "USD")
        XCTAssertEqual(ImportFieldParser.parseCurrency("EUR"), "EUR")
    }

    func testParseCurrency_invalid() {
        XCTAssertNil(ImportFieldParser.parseCurrency("XYZ123"))
        XCTAssertNil(ImportFieldParser.parseCurrency(nil))
    }

    // MARK: - parseDate

    func testParseDate_isoFormat() {
        let date = ImportFieldParser.parseDate("2024-01-15")
        XCTAssertNotNil(date)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.year, from: date!), 2024)
        XCTAssertEqual(cal.component(.month, from: date!), 1)
        XCTAssertEqual(cal.component(.day, from: date!), 15)
    }

    func testParseDate_dotFormat() {
        let date = ImportFieldParser.parseDate("15.01.2024")
        XCTAssertNotNil(date)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: date!), 15)
        XCTAssertEqual(cal.component(.month, from: date!), 1)
    }

    func testParseDate_slashFormat_dayFirst() {
        let date = ImportFieldParser.parseDate("15/01/2024", hint: .dayFirst)
        XCTAssertNotNil(date)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: date!), 15)
        XCTAssertEqual(cal.component(.month, from: date!), 1)
    }

    func testParseDate_slashFormat_monthFirst() {
        let date = ImportFieldParser.parseDate("01/15/2024", hint: .monthFirst)
        XCTAssertNotNil(date)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.day, from: date!), 15)
        XCTAssertEqual(cal.component(.month, from: date!), 1)
    }

    func testParseDate_monthName() {
        let date = ImportFieldParser.parseDate("April 2, 2026")
        XCTAssertNotNil(date)
        let cal = Calendar.current
        XCTAssertEqual(cal.component(.month, from: date!), 4)
        XCTAssertEqual(cal.component(.day, from: date!), 2)
    }

    func testParseDate_unixTimestamp() {
        let date = ImportFieldParser.parseDate(1_700_000_000.0)
        XCTAssertNotNil(date)
    }

    func testParseDate_unixTimestampMillis() {
        let date = ImportFieldParser.parseDate(1_700_000_000_000)
        XCTAssertNotNil(date)
    }

    func testParseDate_nil() {
        XCTAssertNil(ImportFieldParser.parseDate(nil))
    }

    func testParseDate_isoWithTime() {
        let date = ImportFieldParser.parseDate("2024-01-15T14:30:00")
        XCTAssertNotNil(date)
    }

    // MARK: - parseType

    func testParseType_expense_variants() {
        let expenseKeywords = ["expense", "expenses", "out", "debit", "withdrawal", "spending", "outgoing"]
        for keyword in expenseKeywords {
            XCTAssertEqual(ImportFieldParser.parseType(keyword), .expenses, "Failed for: \(keyword)")
        }
    }

    func testParseType_income_variants() {
        let incomeKeywords = ["income", "in", "credit", "deposit", "incoming", "topup", "top up"]
        for keyword in incomeKeywords {
            XCTAssertEqual(ImportFieldParser.parseType(keyword), .income, "Failed for: \(keyword)")
        }
    }

    func testParseType_unknown() {
        XCTAssertNil(ImportFieldParser.parseType("unknown"))
        XCTAssertNil(ImportFieldParser.parseType(nil))
    }

    // MARK: - parseEmoji

    func testParseEmoji_valid() {
        XCTAssertEqual(ImportFieldParser.parseEmoji("🍕"), "🍕")
    }

    func testParseEmoji_nonEmoji() {
        XCTAssertNil(ImportFieldParser.parseEmoji("A"))
    }

    func testParseEmoji_multipleChars() {
        XCTAssertNil(ImportFieldParser.parseEmoji("🍕🍔"))
    }

    func testParseEmoji_nil() {
        XCTAssertNil(ImportFieldParser.parseEmoji(nil))
    }

    // MARK: - parseTitle / parseDescription

    func testParseTitle_valid() {
        XCTAssertEqual(ImportFieldParser.parseTitle("  Lunch  "), "Lunch")
    }

    func testParseTitle_empty() {
        XCTAssertNil(ImportFieldParser.parseTitle(""))
        XCTAssertNil(ImportFieldParser.parseTitle("   "))
    }

    func testParseDescription_valid() {
        XCTAssertEqual(ImportFieldParser.parseDescription("Some note"), "Some note")
    }

    func testParseDescription_nil() {
        XCTAssertNil(ImportFieldParser.parseDescription(nil))
    }

    // MARK: - parseRow

    func testParseRow_minimalRecord() {
        let record: [String: Any] = ["amount": 100.0]
        let mapping: [AppField: String] = [.amount: "amount"]
        let row = ImportFieldParser.parseRow(
            record: record,
            mapping: mapping,
            defaultCurrency: "USD",
            dateHint: .dayFirst,
            existingCategories: TestFixtures.sampleCategories,
            hasNegativeAmounts: false
        )
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.amount, 100.0)
        XCTAssertEqual(row?.currency, "USD")
        XCTAssertEqual(row?.category, "General")
        XCTAssertEqual(row?.type, .expenses)
    }

    func testParseRow_fullRecord() {
        let record: [String: Any] = [
            "amount": "50.00",
            "title": "Coffee",
            "currency": "EUR",
            "category": "Food",
            "date": "2024-01-15",
            "type": "expense",
        ]
        let mapping: [AppField: String] = [
            .amount: "amount", .title: "title", .currency: "currency",
            .category: "category", .date: "date", .type: "type",
        ]
        let row = ImportFieldParser.parseRow(
            record: record,
            mapping: mapping,
            defaultCurrency: "USD",
            dateHint: .dayFirst,
            existingCategories: TestFixtures.sampleCategories,
            hasNegativeAmounts: false
        )
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.title, "Coffee")
        XCTAssertEqual(row?.amount, 50.0)
        XCTAssertEqual(row?.currency, "EUR")
        XCTAssertEqual(row?.category, "Food")
        XCTAssertEqual(row?.type, .expenses)
    }

    func testParseRow_negativeAmount_infersType() {
        let record: [String: Any] = ["amount": "-50"]
        let mapping: [AppField: String] = [.amount: "amount"]
        let row = ImportFieldParser.parseRow(
            record: record,
            mapping: mapping,
            defaultCurrency: "USD",
            dateHint: .dayFirst,
            existingCategories: [],
            hasNegativeAmounts: true
        )
        XCTAssertNotNil(row)
        XCTAssertEqual(row?.type, .expenses)
        XCTAssertEqual(row?.amount, 50.0) // absolute value
    }

    func testParseRow_invalidAmount_returnsNil() {
        let record: [String: Any] = ["amount": "not a number"]
        let mapping: [AppField: String] = [.amount: "amount"]
        let row = ImportFieldParser.parseRow(
            record: record,
            mapping: mapping,
            defaultCurrency: "USD",
            dateHint: .dayFirst,
            existingCategories: [],
            hasNegativeAmounts: false
        )
        XCTAssertNil(row)
    }

    // MARK: - parseAll

    func testParseAll_countsFailures() {
        let records: [[String: Any]] = [
            ["amount": 100],
            ["amount": "invalid"],
            ["amount": 200],
        ]
        let mapping: [AppField: String] = [.amount: "amount"]
        let (rows, failed) = ImportFieldParser.parseAll(
            records: records,
            mapping: mapping,
            defaultCurrency: "USD",
            dateHint: .dayFirst,
            existingCategories: []
        )
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(failed, 1)
    }

    // MARK: - autoDetectMapping

    func testAutoDetectMapping_exactNameMatch() {
        let fields = ["amount", "title", "date", "currency"]
        let records: [[String: Any]] = [
            ["amount": 100, "title": "Test", "date": "2024-01-01", "currency": "USD"],
        ]
        let result = ImportFieldParser.autoDetectMapping(
            jsonFields: fields,
            records: records,
            existingCategories: []
        )
        XCTAssertEqual(result[.amount], "amount")
        XCTAssertEqual(result[.title], "title")
        XCTAssertEqual(result[.date], "date")
        XCTAssertEqual(result[.currency], "currency")
    }

    func testAutoDetectMapping_smartDetection() {
        let fields = ["sum", "name", "when"]
        let records: [[String: Any]] = Array(repeating: [
            "sum": 100.5,
            "name": "Test",
            "when": "2024-01-15",
        ], count: 10)
        let result = ImportFieldParser.autoDetectMapping(
            jsonFields: fields,
            records: records,
            existingCategories: []
        )
        // "sum" should be detected as amount (numeric values)
        XCTAssertEqual(result[.amount], "sum")
        // "when" should be detected as date (parseable dates)
        XCTAssertEqual(result[.date], "when")
    }
}

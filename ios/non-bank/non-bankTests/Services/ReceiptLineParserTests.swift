import XCTest
@testable import non_bank

/// Tests for `ReceiptLineParser` — the regex-driven fallback that
/// turns a single OCR line into a `ParsedLineItem` when no Foundation
/// Models / cloud LLM is available. Focus areas:
///  - `parsePrice` recognises every numeric format we see in the wild
///  - `parseItemLine` strips quantities, tax markers, and the actual
///    price out of the name, and bails on lines without enough text
///  - both reject the date / time / cashier-ID false-positives that
///    plain "rightmost number" matching trips on
final class ReceiptLineParserTests: XCTestCase {

    // MARK: - parsePrice — numeric formats

    func testParsePrice_plainDecimal() {
        XCTAssertEqual(ReceiptLineParser.parsePrice("12.50"), 12.50)
        XCTAssertEqual(ReceiptLineParser.parsePrice("0.99"), 0.99)
    }

    func testParsePrice_euCommaDecimal() {
        XCTAssertEqual(ReceiptLineParser.parsePrice("12,50"), 12.50)
        XCTAssertEqual(ReceiptLineParser.parsePrice("5,5"), 5.5)
    }

    func testParsePrice_euThousandsSeparator() {
        // EU style: dot for thousands, comma for decimal.
        XCTAssertEqual(ReceiptLineParser.parsePrice("1.100,00"), 1100.00)
        XCTAssertEqual(ReceiptLineParser.parsePrice("12.345"), 12345)
    }

    func testParsePrice_usThousandsSeparator() {
        // US style: comma for thousands, dot for decimal.
        XCTAssertEqual(ReceiptLineParser.parsePrice("1,100.00"), 1100.00)
        XCTAssertEqual(ReceiptLineParser.parsePrice("1,100"), 1100)
    }

    func testParsePrice_negativeForDiscountLines() {
        XCTAssertEqual(ReceiptLineParser.parsePrice("-5,00"), -5.0)
        // Unicode minus (U+2212) — common from OCR of "−5,00".
        XCTAssertEqual(ReceiptLineParser.parsePrice("\u{2212}5,00"), -5.0)
    }

    func testParsePrice_stripsCurrencyGlyphs() {
        XCTAssertEqual(ReceiptLineParser.parsePrice("€12.50"), 12.50)
        XCTAssertEqual(ReceiptLineParser.parsePrice("12,50 €"), 12.50)
        XCTAssertEqual(ReceiptLineParser.parsePrice("$9.99"), 9.99)
        XCTAssertEqual(ReceiptLineParser.parsePrice("1500 RSD"), 1500)
    }

    func testParsePrice_rejectsGarbage() {
        XCTAssertNil(ReceiptLineParser.parsePrice(""))
        XCTAssertNil(ReceiptLineParser.parsePrice("abc"))
        XCTAssertNil(ReceiptLineParser.parsePrice("12.50.30"))
    }

    // MARK: - parseItemLine — happy paths

    func testParseItemLine_extractsNameAndPrice() {
        let item = ReceiptLineParser.parseItemLine("Pizza Margherita 12,50")
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.name, "Pizza Margherita")
        XCTAssertEqual(item?.lineTotal, 12.50)
        XCTAssertEqual(item?.quantity, 1)
    }

    func testParseItemLine_leadingQuantity() {
        let item = ReceiptLineParser.parseItemLine("2 Salad 8,00")
        XCTAssertEqual(item?.name, "Salad")
        XCTAssertEqual(item?.quantity, 2)
        XCTAssertEqual(item?.lineTotal, 8.0)
        XCTAssertEqual(item?.unitPrice, 4.0)
    }

    func testParseItemLine_trailingQuantitySuffix() {
        // "3x" pattern at the end after the name.
        let item = ReceiptLineParser.parseItemLine("Espresso 3x 9,00")
        XCTAssertEqual(item?.name, "Espresso")
        XCTAssertEqual(item?.quantity, 3)
        XCTAssertEqual(item?.lineTotal, 9.0)
        XCTAssertEqual(item?.unitPrice, 3.0)
    }

    func testParseItemLine_stripsTaxMarkerSuffix() {
        // Serbian / EU receipts often print a single-letter tax band
        // (Б, A, B, *) after the price.
        let item = ReceiptLineParser.parseItemLine("Bread 250 B")
        XCTAssertEqual(item?.name, "Bread")
        XCTAssertEqual(item?.lineTotal, 250)
    }

    func testParseItemLine_normalisesCommaSpaceArtifact() {
        // OCR artifact: "3, 88" with a space between comma and the
        // cents should normalise to "3,88".
        let item = ReceiptLineParser.parseItemLine("Latte 3, 88")
        XCTAssertEqual(item?.lineTotal, 3.88)
    }

    func testParseItemLine_cyrillicNamePreserved() {
        let item = ReceiptLineParser.parseItemLine("Хлеб 50,00")
        XCTAssertEqual(item?.name, "Хлеб")
        XCTAssertEqual(item?.lineTotal, 50.0)
    }

    // MARK: - parseItemLine — rejections

    func testParseItemLine_rejectsTooShort() {
        XCTAssertNil(ReceiptLineParser.parseItemLine(""))
        XCTAssertNil(ReceiptLineParser.parseItemLine("ab"))
    }

    func testParseItemLine_rejectsLineWithoutLetters() {
        // Numbers-only / dates / phone numbers must NOT parse as items
        // even when they happen to contain something price-shaped.
        XCTAssertNil(ReceiptLineParser.parseItemLine("12.04.2026"))
        XCTAssertNil(ReceiptLineParser.parseItemLine("999 888 777"))
    }

    func testParseItemLine_rejectsDateLookingPrice() {
        // Date `11.04.2026` previously broke through and matched `11.04`
        // as the price. The lookahead/lookbehind guards must reject it.
        XCTAssertNil(ReceiptLineParser.parseItemLine("Date 11.04.2026"))
    }

    func testParseItemLine_rejectsTimeLookingPrice() {
        // `13:37` previously matched `37` as a bare integer.
        XCTAssertNil(ReceiptLineParser.parseItemLine("Closed 13:37"))
    }
}

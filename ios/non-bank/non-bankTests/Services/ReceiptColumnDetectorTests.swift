import XCTest
import CoreGraphics
@testable import non_bank

final class ReceiptColumnDetectorTests: XCTestCase {

    // MARK: - Single-line items

    func testExtractItems_singleLineItem_emitsOne() {
        let row = makeRow(text: "Bread 5,00", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].item.name, "Bread")
        XCTAssertEqual(items[0].item.lineTotal, 5.0, accuracy: 0.01)
    }

    func testExtractItems_multipleSingleLineItems() {
        let rows = [
            makeRow(text: "Latte 4,50", y: 0.8),
            makeRow(text: "Croissant 3,00", y: 0.75),
            makeRow(text: "Bread 2,00", y: 0.70)
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.item.name), ["Latte", "Croissant", "Bread"])
    }

    // MARK: - Two-row item pairing

    func testExtractItems_namePriceOnSeparateRows_pairsByYProximity() {
        // OCR split the receipt into two rows when name and price columns
        // had a wide gap. Y-distance is small (1.5%) so they pair.
        let nameRow = makeRow(text: "BREAD WHITE", y: 0.500, x: 0.05, width: 0.4)
        let priceRow = makeRow(text: "5,00", y: 0.485, x: 0.65, width: 0.2)
        let items = ReceiptColumnDetector.extractItems(from: [nameRow, priceRow])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].item.name, "BREAD WHITE")
        XCTAssertEqual(items[0].item.lineTotal, 5.0, accuracy: 0.01)
        XCTAssertEqual(items[0].rowIDs.count, 2)
    }

    func testExtractItems_namePriceTooFarApart_dropsBoth() {
        // Y difference = 0.40, far beyond the 0.06 pairing threshold.
        let nameRow = makeRow(text: "BREAD", y: 0.7)
        let priceRow = makeRow(text: "5,00", y: 0.3)
        let items = ReceiptColumnDetector.extractItems(from: [nameRow, priceRow])
        XCTAssertEqual(items.count, 0)
    }

    func testExtractItems_pendingNameClearedByNoise() {
        // A non-product row (VAT) breaks the chain — the price below
        // belongs to nobody and is dropped.
        let name = makeRow(text: "BREAD", y: 0.700)
        let noise = makeRow(text: "VAT 18% 12,50", y: 0.685)
        let price = makeRow(text: "5,00", y: 0.670)
        let items = ReceiptColumnDetector.extractItems(from: [name, noise, price])
        XCTAssertEqual(items.count, 0)
    }

    // MARK: - Filter integration

    func testExtractItems_skipsNonProductRowsBetweenItems() {
        let rows = [
            makeRow(text: "Bread 5,00", y: 0.700),
            makeRow(text: "VAT 18% 12,50", y: 0.650),     // skipNonProduct
            makeRow(text: "Cheese 10,00", y: 0.600),
            makeRow(text: "Card **** 1234 27,00", y: 0.550) // pattern match
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows)
        XCTAssertEqual(items.map(\.item.name), ["Bread", "Cheese"])
    }

    func testExtractItems_stopsAtAnchorTotal() {
        // Rows below the anchor (TOTAL) are footer and never emit items —
        // even legitimate-looking item lines (a duplicate "Cash 10,00" that
        // could otherwise parse as an item).
        let rows = [
            makeRow(text: "Bread 5,00", y: 0.700),
            makeRow(text: "Cheese 5,00", y: 0.650),
            makeRow(text: "TOTAL 10,00", y: 0.500),       // anchor
            makeRow(text: "Pizza 999,00", y: 0.450),      // would-be item, ignored
            makeRow(text: "Cash 10,00", y: 0.400)
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows)
        XCTAssertEqual(items.map(\.item.name), ["Bread", "Cheese"])
    }

    // MARK: - Realistic mixed receipt

    func testExtractItems_realisticReceipt_pickOnlyItems() {
        let rows = [
            makeRow(text: "Coffee Bean Cafe", y: 0.95),                       // header text
            makeRow(text: "12.05.2024 14:30", y: 0.90),                       // date pattern
            makeRow(text: "Latte vanilla 4,50", y: 0.80),                     // item
            makeRow(text: "Croissant 3,00", y: 0.75),                         // item
            makeRow(text: "ESPRESSO", y: 0.700, x: 0.05, width: 0.4),         // name-only
            makeRow(text: "2,50", y: 0.685, x: 0.65, width: 0.2),             // price-only, pairs above
            makeRow(text: "TOTAL 10,00", y: 0.55),                            // anchor
            makeRow(text: "VAT 18%", y: 0.50),                                // footer
            makeRow(text: "Card *1234 10,00", y: 0.45)                        // footer
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items.map(\.item.name), ["Latte vanilla", "Croissant", "ESPRESSO"])
    }

    // MARK: - Discount rows (Round C-1)

    func testExtractItems_discountRow_emittedAsNegativeItem() {
        // Round C-1: discount rows used to be silently dropped. Now they're
        // emitted as items with a negative line total so the downstream sum
        // matches the receipt's grand total.
        let rows = [
            makeRow(text: "Pizza 20,00", y: 0.700),
            makeRow(text: "Discount -5,00", y: 0.650),
            makeRow(text: "Coke 3,00", y: 0.600)
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows).map(\.item)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[1].lineTotal, -5.0, accuracy: 0.01)
        // Discount item keeps its name so downstream code (review sheet,
        // post-process) can re-classify if needed.
        XCTAssertEqual(items[1].name, "Discount")
    }

    func testExtractItems_discountWithPositivePrice_isStillNegative() {
        // OCR sometimes loses the leading minus sign. The detector must
        // force the line total negative regardless of the parsed sign,
        // because the keyword tells us what the row means.
        let row = makeRow(text: "Скидка 5,00", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].lineTotal, -5.0, accuracy: 0.01)
    }

    // MARK: - Integer / 1-decimal / currency-suffix prices (Round C-1)

    func testExtractItems_integerPrice_RSD() {
        // RSD/JPY/HUF receipts typically have integer prices and no currency
        // glyph on each line. Round C-1 accepts these.
        let row = makeRow(text: "Кафа 250", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Кафа")
        XCTAssertEqual(items[0].lineTotal, 250.0, accuracy: 0.01)
    }

    func testExtractItems_oneDecimalPrice() {
        // EU receipts sometimes have prices like "Espresso 2,5" — should
        // not require a second decimal digit.
        let row = makeRow(text: "Espresso 2,5", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].lineTotal, 2.5, accuracy: 0.01)
    }

    func testExtractItems_priceWithCurrencyCode_suffix() {
        let row = makeRow(text: "Burger 12 EUR", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].name, "Burger")
        XCTAssertEqual(items[0].lineTotal, 12.0, accuracy: 0.01)
    }

    func testExtractItems_priceWithCurrencyCode_prefix() {
        let row = makeRow(text: "Espresso RSD 250", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].lineTotal, 250.0, accuracy: 0.01)
    }

    // MARK: - Round C-2: last-anchor cutoff (regression)

    func testExtractItems_anchorAtTopThenItems_processesItemsBelow() {
        // Wolt-style screenshot: order summary card has TOTAL at top, items
        // listed below. Round C-1 broke on first anchor → 0 items emitted.
        // Round C-2 uses LAST anchor as cutoff so the items survive.
        let rows = [
            makeRow(text: "Restaurant Name", y: 0.95),
            makeRow(text: "Всего RSD", y: 0.85),         // top anchor — must NOT cut off
            makeRow(text: "4.709,40", y: 0.84),          // pricePart for top anchor
            makeRow(text: "Ваш заказ", y: 0.75),
            makeRow(text: "Šašlik 1.390,00", y: 0.65),   // legit item below top anchor
            makeRow(text: "Manti 1.190,00", y: 0.60),
            makeRow(text: "Pečeno povrće 690,00", y: 0.55),
            makeRow(text: "Всего 4.709,40", y: 0.30)     // last anchor — actual cutoff
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows).map(\.item)
        XCTAssertEqual(items.map(\.name), ["Šašlik", "Manti", "Pečeno povrće"])
        XCTAssertEqual(items.map(\.lineTotal), [1390, 1190, 690])
    }

    func testExtractItems_multiGuestReceipt_collectsAllGuests() {
        // Hotel guest bill with subtotal anchor between guests:
        // items, "Total guest 1", items, "Total guest 2", "GRAND TOTAL".
        // Round C-1 stopped at first "Total guest 1" — guest 2 lost.
        let rows = [
            makeRow(text: "Beef tartare 1100,00", y: 0.85),
            makeRow(text: "Total due Guest 1: 1100,00", y: 0.75),  // intermediate anchor
            makeRow(text: "Breakfast salmon 1450,00", y: 0.65),
            makeRow(text: "Cappuccino 350,00", y: 0.60),
            makeRow(text: "Total due Guest 2: 1800,00", y: 0.55),  // intermediate anchor
            makeRow(text: "TOTAL DUE: 2900,00", y: 0.40)           // last anchor (real cutoff)
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows).map(\.item)
        XCTAssertEqual(
            items.map(\.name),
            ["Beef tartare", "Breakfast salmon", "Cappuccino"]
        )
    }

    func testExtractItems_intermediateAnchorClearsPendingName() {
        // A name-only row above an intermediate anchor must NOT pair with a
        // price below the anchor — that would steal a price across a
        // subtotal boundary.
        let rows = [
            makeRow(text: "MysteryItem", y: 0.85, x: 0.05, width: 0.4),
            makeRow(text: "Total guest 1: 100,00", y: 0.80),  // anchor clears name
            makeRow(text: "999,00", y: 0.75, x: 0.65, width: 0.2),  // orphan price
            makeRow(text: "TOTAL DUE: 100,00", y: 0.50)
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows).map(\.item)
        XCTAssertEqual(items.count, 0)
    }

    // MARK: - Round C-2: multi-price row picks rightmost (regression)

    func testExtractItems_multiPriceRow_picksRightmostAsTotal() {
        // OCR sometimes glues unit-price and total on the same row:
        // "470.00 550.00" (unit | total). Round C-1 picked .first (unit
        // price); Round C-2 picks rightmost (total).
        let nameRow = makeRow(text: "Sandwich", y: 0.5, x: 0.05, width: 0.4)

        // Build a price-only row whose .lines list contains TWO price
        // observations at increasing X — that's how the OCR splits it.
        let leftPrice = ReceiptOCRService.RecognizedLine(
            text: "470.00",
            boundingBox: CGRect(x: 0.55, y: 0.488, width: 0.1, height: 0.03),
            confidence: 0.9
        )
        let rightPrice = ReceiptOCRService.RecognizedLine(
            text: "550.00",
            boundingBox: CGRect(x: 0.75, y: 0.488, width: 0.1, height: 0.03),
            confidence: 0.9
        )
        let priceRow = ReceiptOCRService.OCRRow(
            id: UUID(),
            lines: [leftPrice, rightPrice],
            boundingBox: CGRect(x: 0.55, y: 0.488, width: 0.3, height: 0.03),
            text: "470.00 550.00"
        )

        let items = ReceiptColumnDetector.extractItems(from: [nameRow, priceRow]).map(\.item)
        XCTAssertEqual(items.count, 1)
        // Rightmost price wins — 550 not 470.
        XCTAssertEqual(items[0].lineTotal, 550.0, accuracy: 0.01)
    }

    // MARK: - Round C-2: regex tightening (regression)

    func testExtractItems_dateInsideLine_doesNotBecomeItem() {
        // "11.04" used to match as 2-decimal price. With C-2 lookarounds
        // the trailing dot kills the match — and the date pattern in the
        // filter routes the whole row to skipNonProduct anyway.
        let row = makeRow(text: "Open: 11.04.2026 13:08 Order No. 261505", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 0)
    }

    func testExtractItems_versionStringInsideLine_doesNotBecomeItem() {
        // "Касир: Nemanja Stojicic 687/1.0.1" — the cashier-software version
        // suffix used to false-match as 1-decimal "1.0". Both the regex
        // tightening and the касир stem-filter must reject this.
        let row = makeRow(text: "Касир: Nemanja Stojicic 687/1.0.1", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 0)
    }

    func testExtractItems_clockTime_doesNotBecomeItem() {
        // "13:37" must not match as bare integer 37 (lookbehind rejects `:`).
        // The line itself is a textual date, so the filter also catches it.
        let row = makeRow(text: "27 АПРЕЛЯ 2026 Г. В 13:37", y: 0.5)
        let items = ReceiptColumnDetector.extractItems(from: [row]).map(\.item)
        XCTAssertEqual(items.count, 0)
    }

    // MARK: - Edge cases

    func testExtractItems_emptyInput_returnsEmpty() {
        let items = ReceiptColumnDetector.extractItems(from: [])
        XCTAssertEqual(items.count, 0)
    }

    func testExtractItems_priceWithoutNameAtTop_dropped() {
        // First row is a price with no preceding name — nothing to pair.
        let rows = [
            makeRow(text: "5,00", y: 0.7),
            makeRow(text: "Bread 3,00", y: 0.65)
        ]
        let items = ReceiptColumnDetector.extractItems(from: rows)
        XCTAssertEqual(items.map(\.item.name), ["Bread"])
    }

    func testExtractItems_currencySymbolPriceLine_paired() {
        let nameRow = makeRow(text: "Sandwich", y: 0.5, x: 0.05, width: 0.5)
        let priceRow = makeRow(text: "$8.50", y: 0.488, x: 0.7, width: 0.2)
        let items = ReceiptColumnDetector.extractItems(from: [nameRow, priceRow])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].item.name, "Sandwich")
        XCTAssertEqual(items[0].item.lineTotal, 8.5, accuracy: 0.01)
    }

    // MARK: - Helpers

    private func makeRow(
        text: String,
        y: CGFloat,
        x: CGFloat = 0.05,
        width: CGFloat = 0.9,
        height: CGFloat = 0.03
    ) -> ReceiptOCRService.OCRRow {
        let box = CGRect(x: x, y: y, width: width, height: height)
        let line = ReceiptOCRService.RecognizedLine(
            text: text,
            boundingBox: box,
            confidence: 0.9
        )
        return ReceiptOCRService.OCRRow(
            id: UUID(),
            lines: [line],
            boundingBox: box,
            text: text
        )
    }
}

import XCTest
@testable import non_bank

final class HybridReceiptParserTests: XCTestCase {

    // MARK: - totalsMatch

    func testTotalsMatch_noGrandTotal_returnsTrue() {
        // No grand total to compare against — fallback parser produces this
        // shape and we shouldn't penalize it.
        let receipt = ParsedReceipt(
            storeName: nil,
            date: nil,
            items: [makeItem(name: "A", total: 1.0)],
            totalAmount: nil,
            currency: nil
        )
        XCTAssertTrue(HybridReceiptParser.totalsMatch(in: receipt))
    }

    func testTotalsMatch_zeroGrandTotal_returnsTrue() {
        let receipt = ParsedReceipt(
            storeName: nil, date: nil,
            items: [makeItem(name: "A", total: 1.0)],
            totalAmount: 0,
            currency: nil
        )
        XCTAssertTrue(HybridReceiptParser.totalsMatch(in: receipt))
    }

    func testTotalsMatch_exactMatch_returnsTrue() {
        let receipt = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "A", total: 100),
                makeItem(name: "B", total: 50)
            ],
            totalAmount: 150,
            currency: nil
        )
        XCTAssertTrue(HybridReceiptParser.totalsMatch(in: receipt))
    }

    func testTotalsMatch_within1Percent_returnsTrue() {
        // 150.50 vs 150 = 0.33%, well within 1% tolerance.
        let receipt = ParsedReceipt(
            storeName: nil, date: nil,
            items: [makeItem(name: "A", total: 150.5)],
            totalAmount: 150,
            currency: nil
        )
        XCTAssertTrue(HybridReceiptParser.totalsMatch(in: receipt))
    }

    func testTotalsMatch_within50Cents_returnsTrue() {
        // For small totals the absolute floor (0.50) kicks in even when
        // the percentage is high.
        let receipt = ParsedReceipt(
            storeName: nil, date: nil,
            items: [makeItem(name: "A", total: 5.40)],
            totalAmount: 5.0,
            currency: nil
        )
        // Difference 0.40 < 0.50 floor → still a match.
        XCTAssertTrue(HybridReceiptParser.totalsMatch(in: receipt))
    }

    func testTotalsMatch_diverges_returnsFalse() {
        // 200 vs 150 → 33% off, far above tolerance.
        let receipt = ParsedReceipt(
            storeName: nil, date: nil,
            items: [makeItem(name: "A", total: 200)],
            totalAmount: 150,
            currency: nil
        )
        XCTAssertFalse(HybridReceiptParser.totalsMatch(in: receipt))
    }

    func testTotalsMatch_usesQuantityTimesPriceWhenTotalMissing() {
        // Item has no `total` but has quantity*price = 30 → matches grand 30.
        let receipt = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                ReceiptItem(name: "A", quantity: 3, price: 10, total: nil)
            ],
            totalAmount: 30,
            currency: nil
        )
        XCTAssertTrue(HybridReceiptParser.totalsMatch(in: receipt))
    }

    // MARK: - postProcess (filter + pruning)

    func testPostProcess_dropsFalsePositiveByKeyword() {
        // Foundation Models occasionally returns "Total" / a card line as
        // items. The filter strips those non-product lines out. A
        // "Service charge" is a FEE, not noise: fees/tips are kept (they
        // add to the total and the split-by-items calculator distributes
        // them proportionally), so it stays in the list.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Burger", total: 10),
                makeItem(name: "TOTAL", total: 18),
                makeItem(name: "Service charge", total: 3),
                makeItem(name: "Card **** 1234", total: 18),
                makeItem(name: "Fries", total: 5)
            ],
            totalAmount: 18,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.map(\.name), ["Burger", "Service charge", "Fries"])
    }

    func testPostProcess_pruningDropsOverstuffedItem() {
        // Sum 220 against grandTotal 200 — the "Service 10%" line at 20 is
        // the closest match to the overshoot and gets dropped.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Pizza", total: 100),
                makeItem(name: "Wine", total: 80),
                makeItem(name: "Salad", total: 20),
                makeItem(name: "Mystery line", total: 20)
            ],
            totalAmount: 200,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        let total = result.items.reduce(0) { $0 + $1.lineTotal }
        XCTAssertEqual(total, 200, accuracy: 0.5)
        XCTAssertEqual(result.items.count, 3)
    }

    func testPostProcess_keepsAllItemsWhenSumDramaticallyExceedsGrandTotal() {
        // Real-world Serbian grocery receipt: 7 legit products summing to
        // 11000 RSD, but Gemini parsed "11.243,86" as "1.243,86" because
        // of EU thousands-separator ambiguity. If we trusted the bad
        // grand_total here, prune would delete real products to match —
        // the exact bug observed in production. Safety guard triggers
        // when items_sum > grand_total × 3 and keeps every item.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Maslinovo ulje", total: 1500),
                makeItem(name: "Rib eye steak", total: 3000),
                makeItem(name: "Maline", total: 800),
                makeItem(name: "Kinder cokolada", total: 200),
                makeItem(name: "Šargarepa 500g", total: 150),
                makeItem(name: "Paprika Mix", total: 350),
                makeItem(name: "Borovnica 250g", total: 1200),
                makeItem(name: "Pečeni pistaci", total: 1800),
                makeItem(name: "Ementaler sir", total: 2000),
            ],
            totalAmount: 1244,  // misread by Gemini; real total ~11000
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.count, 9,
            "Items must not be deleted when grand_total is wildly inconsistent with the items' sum")
    }

    func testPostProcess_keepsAllWhenSumAlreadyFits() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Coffee", total: 3),
                makeItem(name: "Croissant", total: 4)
            ],
            totalAmount: 7,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.count, 2)
    }

    func testPostProcess_skipsPruningWhenGrandTotalMissing() {
        // Without a grand total there's nothing to prune against.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Coffee", total: 3),
                makeItem(name: "Croissant", total: 4),
                makeItem(name: "Bread", total: 5)
            ],
            totalAmount: nil,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.count, 3)
    }

    func testPostProcess_doesNotPruneWhenGapWontShrink() {
        // Sum 100, grand 50, single item at 100 — dropping it would make sum 0,
        // which is *farther* from 50 than 100 is. We must keep the item.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [makeItem(name: "Big bill", total: 100)],
            totalAmount: 50,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.count, 1)
    }

    func testPostProcess_filterAndPruneTogether() {
        // Both passes apply: drop the keyword-matched "Total" line, then
        // prune the surviving overshoot.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Burger", total: 10),
                makeItem(name: "Fries", total: 5),
                makeItem(name: "Drink", total: 3),
                makeItem(name: "TOTAL", total: 22),    // filtered out
                makeItem(name: "Tax", total: 4)        // filtered out
            ],
            totalAmount: 18,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.map(\.name), ["Burger", "Fries", "Drink"])
        let sum = result.items.reduce(0) { $0 + $1.lineTotal }
        XCTAssertEqual(sum, 18, accuracy: 0.5)
    }

    // MARK: - Discount handling (Round C-1)

    func testPostProcess_positiveDiscountWordLine_staysPositiveItem() throws {
        // THE regression guard. A positively-priced line whose name contains
        // a marketing word ("Super Deal") — a combo/meal deal whose
        // components print at 0.00 while the combo carries the price — must
        // be kept as a POSITIVE item, never negated. This is the exact bug:
        // "Super Deal 380,00" was shown as "−380" and broke the totals
        // (items 770 + 200 + 380 should sum to 1350, not 590).
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Chicken Bucket", total: 770),
                makeItem(name: "Drinks", total: 200),
                makeItem(name: "Super Deal", total: 380)
            ],
            totalAmount: 1350,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.count, 3)
        let deal = try XCTUnwrap(result.items.first { $0.name == "Super Deal" })
        // Stays POSITIVE — sign beats name.
        XCTAssertEqual(deal.lineTotal, 380, accuracy: 0.01)
        // And the receipt now balances.
        let sum = result.items.reduce(0) { $0 + $1.lineTotal }
        XCTAssertEqual(sum, 1350, accuracy: 0.01)
    }

    func testPostProcess_positiveExplicitDiscountWord_staysPositive() throws {
        // Even an unambiguous discount WORD does not flip a POSITIVELY-priced
        // line. A positive amount is the strong signal — the customer paid
        // it. (e.g. a "Discount bundle" product priced at 50.)
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Pasta", total: 100),
                makeItem(name: "Discount bundle", total: 50)
            ],
            totalAmount: 150,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        let bundle = try XCTUnwrap(result.items.first { $0.name == "Discount bundle" })
        XCTAssertEqual(bundle.lineTotal, 50, accuracy: 0.01)
        let sum = result.items.reduce(0) { $0 + $1.lineTotal }
        XCTAssertEqual(sum, 150, accuracy: 0.01)
    }

    func testPostProcess_discountItem_negativeInput_staysNegative() throws {
        // Defensive: even if FM correctly emitted -3, postProcess must NOT
        // accidentally double-negate to +3.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Pizza", total: 20),
                makeItem(name: "Скидка", total: -5)
            ],
            totalAmount: 15,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        let discount = try XCTUnwrap(result.items.first { $0.name == "Скидка" })
        XCTAssertEqual(discount.lineTotal, -5.0, accuracy: 0.01)
    }

    func testPostProcess_pruningSkipsDiscountVictims() {
        // Sum of items = 100+50+(-10)+30 = 170, grand = 100. Overshoot 70.
        // Naive prune would pick the item closest to 70 — but if "Discount"
        // (-10) were eligible, removing it would *raise* sum to 180. The
        // Round C-1 fix excludes discounts from victim candidates.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Pizza", total: 100),
                makeItem(name: "Wine", total: 50),
                makeItem(name: "Скидка", total: -10),   // .discount verdict
                makeItem(name: "Mystery", total: 30)
            ],
            totalAmount: 100,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        // Discount is preserved (negative).
        XCTAssertNotNil(result.items.first { $0.name == "Скидка" })
        // Sum should be at most grand + tolerance.
        let sum = result.items.reduce(0) { $0 + $1.lineTotal }
        XCTAssertLessThanOrEqual(sum, 100.5)
    }

    // MARK: - Helpers

    private func makeItem(name: String, total: Double) -> ReceiptItem {
        ReceiptItem(name: name, quantity: 1, price: total, total: total)
    }
}

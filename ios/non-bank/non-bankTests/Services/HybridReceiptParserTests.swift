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
        // Sum 220 against grandTotal 200 — the trailing 20 explains the
        // excess exactly and gets dropped; the "Salad" above it, at the
        // same price, stays (stray lines sit under the items).
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
        XCTAssertEqual(result.items.map(\.name), ["Pizza", "Wine", "Salad"])
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
        // Sum = 100 + (-10) + 30 = 120, grand = 90: the trailing "Mystery"
        // explains the excess. The discount is never a candidate —
        // removing it would *raise* the sum.
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Pizza", total: 100),
                makeItem(name: "Скидка", total: -10),   // .discount verdict
                makeItem(name: "Mystery", total: 30)
            ],
            totalAmount: 90,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.map(\.name), ["Pizza", "Скидка"])
    }

    // MARK: - Nothing bought is removed to make the sum fit

    /// An excess no trailing line explains is a misread, not a stray line:
    /// here one price read 100 too high. Every item stays, and the
    /// mismatch is left for the review screen to show. (The old prune
    /// removed the bread — the item closest to the excess — and reported
    /// a receipt that added up.)
    func testPostProcess_keepsEveryItemWhenNoLineExplainsTheExcess() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Sir gauda 300g", total: 559.99),   // printed 459.99
                makeItem(name: "Mleko 1L", total: 149.99),
                makeItem(name: "Hleb beli", total: 89.99),
                makeItem(name: "Jogurt 1kg", total: 179.99)
            ],
            totalAmount: 879.96,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.count, 4)
        XCTAssertFalse(HybridReceiptParser.totalsMatch(in: result))
    }

    /// The same, with the excess from a discount the model didn't carry:
    /// the cheap items near its size (the bag, the roll) are not eaten to
    /// absorb it.
    func testPostProcess_keepsCheapItemsWhenADiscountWasMissed() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Piletina 1kg", total: 899.99),
                makeItem(name: "Kifla", total: 45),
                makeItem(name: "Kesa", total: 10),
                makeItem(name: "Sok 1L", total: 189.99)
            ],
            totalAmount: 1084.98,   // 60 off at the till
            currency: nil
        )
        XCTAssertEqual(HybridReceiptParser.postProcess(raw).items.count, 4)
    }

    /// A total and the card line under it, in a language the blacklist
    /// doesn't know: both go, the items stay.
    func testPostProcess_prunesTrailingTotalAndPaymentLines() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Φέτα 400g", total: 300),
                makeItem(name: "Ελιές", total: 200),
                makeItem(name: "Ψωμί", total: 100),
                makeItem(name: "Σύνολο", total: 600),
                makeItem(name: "Κάρτα", total: 600)
            ],
            totalAmount: 600,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.map(\.name), ["Φέτα 400g", "Ελιές", "Ψωμί"])
    }

    /// Only the last few lines are candidates: an item higher up that
    /// happens to cost exactly the excess is not a stray line.
    func testPrune_lineAboveTheTailIsNeverRemoved() {
        let items = [
            makeItem(name: "Limun", total: 20),
            makeItem(name: "Pizza", total: 100),
            makeItem(name: "Wine", total: 80),
            makeItem(name: "Pasta", total: 55),
            makeItem(name: "Salad", total: 45),
            makeItem(name: "Water", total: 30)
        ]
        let result = HybridReceiptParser.pruneOverstuffedItems(items, grandTotal: 310)
        XCTAssertEqual(result.count, 6)
    }

    /// A trailing line as large as the receipt is a total or cash line
    /// even when the receipt was rounded for cash and nothing is exact.
    func testPrune_totalSizedTrailingLineGoesWithinTolerance() {
        let items = [
            makeItem(name: "Kaffe", total: 32.40),
            makeItem(name: "Bulle", total: 27.30),
            makeItem(name: "Summa", total: 60)
        ]
        let result = HybridReceiptParser.pruneOverstuffedItems(items, grandTotal: 60)
        XCTAssertEqual(result.map(\.name), ["Kaffe", "Bulle"])
    }

    // MARK: - Products named like labels

    /// The blacklist's words inside product names ("Total", "Table",
    /// "card", "mesa", "kartica"): the model read them as items, the
    /// receipt adds up with them, they stay. One-word ones too ("Merci",
    /// the chocolates).
    func testPostProcess_keepsProductsNamedLikeLabelsWhenTheReceiptAddsUp() {
        let names = [
            "Colgate Total 75ml", "Table salt 1kg", "Greeting card", "Supa od mesa",
            "SIM kartica", "Merci", "Bus ticket", "Hleb beli"
        ]
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: names.enumerated().map { makeItem(name: $0.element, total: 100 + Double($0.offset) * 10) },
            totalAmount: 1080,
            currency: nil
        )
        XCTAssertEqual(HybridReceiptParser.postProcess(raw).items.map(\.name), names)
    }

    /// Where the total can't decide (tax added on top, so the items never
    /// add up to it), the name does: a product with a label's word in it
    /// stays, a bare label goes.
    func testPostProcess_withoutAMatchingTotalTheNameDecides() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Table salt", total: 1.99),
                makeItem(name: "Gift card", total: 25),
                makeItem(name: "Eggs", total: 3.49),
                makeItem(name: "Subtotal", total: 30.48),
                makeItem(name: "Change", total: 7.08)
            ],
            totalAmount: 32.92,   // 30.48 + 2.44 sales tax
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(result.items.map(\.name), ["Table salt", "Gift card", "Eggs"])
    }

    /// A payment line with more words than the label goes too: it is as
    /// large as the receipt, and the receipt adds up without it.
    func testPostProcess_dropsPaymentLineWithExtraWords() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Burger", total: 10),
                makeItem(name: "Fries", total: 8),
                makeItem(name: "Card payment", total: 18),
                makeItem(name: "Change due", total: 2)
            ],
            totalAmount: 18,
            currency: nil
        )
        XCTAssertEqual(HybridReceiptParser.postProcess(raw).items.map(\.name), ["Burger", "Fries"])
    }

    /// A one-word product the total doesn't account for is still a label
    /// as far as anyone can tell: "Total" under items that already add up.
    func testPostProcess_bareLabelGoesWhenTheReceiptAddsUpWithoutIt() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Merci", total: 459.99),
                makeItem(name: "Mleko", total: 149.99),
                makeItem(name: "Ukupno", total: 609.98)
            ],
            totalAmount: 609.98,
            currency: nil
        )
        XCTAssertEqual(HybridReceiptParser.postProcess(raw).items.map(\.name), ["Merci", "Mleko"])
    }

    /// Tax lines are dropped as before, whatever the total says.
    func testPostProcess_taxLineIsStillDropped() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Dinner", total: 42.50),
                makeItem(name: "Tip", total: 9),
                makeItem(name: "Sales tax", total: 3.51)
            ],
            totalAmount: 55.01,
            currency: nil
        )
        XCTAssertEqual(HybridReceiptParser.postProcess(raw).items.map(\.name), ["Dinner", "Tip"])
    }

    /// One band of a tall receipt (or one photo of several): the total on
    /// it is the whole receipt's, so it decides nothing and nothing is
    /// pruned. Names still do: the product stays, the total line goes.
    func testPostProcess_partOfAReceipt_totalIsNotAChecksum() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Table salt", total: 100),
                makeItem(name: "Brot", total: 5000),          // costs what the receipt totals
                makeItem(name: "Card payment", total: 5000),
                makeItem(name: "UKUPNO", total: 5000)
            ],
            totalAmount: 5000,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw, totalIsChecksum: false)
        XCTAssertEqual(result.items.map(\.name), ["Table salt", "Brot"])
    }

    /// The OCR fallback keeps its strict filter: there the names come from
    /// raw lines, not from a model's pick of the items.
    func testPostProcess_ocrFallbackDropsEveryFlaggedName() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                makeItem(name: "Table salt", total: 100),
                makeItem(name: "Hleb", total: 90)
            ],
            totalAmount: nil,
            currency: nil
        )
        let result = HybridReceiptParser.postProcess(raw, totalIsChecksum: false, readByModel: false)
        XCTAssertEqual(result.items.map(\.name), ["Hleb"])
    }

    // MARK: - Helpers

    private func makeItem(name: String, total: Double) -> ReceiptItem {
        ReceiptItem(name: name, quantity: 1, price: total, total: total)
    }
}

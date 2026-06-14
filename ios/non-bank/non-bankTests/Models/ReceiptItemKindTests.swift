import XCTest
@testable import non_bank

/// Tests for `ReceiptItem.Kind.classify` — the single source of truth for
/// the icon shown next to a parsed line and how the split-by-items
/// calculator treats it.
///
/// The load-bearing invariant under test: SIGN BEATS NAME. A line is a
/// discount only when it REDUCES the total (negative amount). A
/// positively-priced line is a regular `.item` even when its name carries a
/// marketing word ("Super Deal", "Combo Menu", "Promo Box"). This is the
/// regression guard for the bug where a positive "Super Deal 380,00" combo
/// line was shown as a "−380" discount and broke the totals.
final class ReceiptItemKindTests: XCTestCase {

    private func kind(_ name: String, _ lineTotal: Double) -> ReceiptItem.Kind {
        ReceiptItem.Kind.classify(name: name, lineTotal: lineTotal)
    }

    // MARK: - Sign beats name (the bug)

    func testPositivePromoLine_isItem_notDiscount() {
        // The exact shape of the reported bug: a combo/meal "deal" priced
        // positively must be a regular item, never a negative discount.
        XCTAssertEqual(kind("Super Deal", 380), .item)
        XCTAssertEqual(kind("Combo Meal", 12.99), .item)
        XCTAssertEqual(kind("Lunch Deal", 8.50), .item)
        XCTAssertEqual(kind("Offer of the day", 5.00), .item)
        XCTAssertEqual(kind("Family Bundle", 24.00), .item)
        XCTAssertEqual(kind("Promo Box", 15.00), .item)
    }

    func testPositiveExplicitDiscountWord_isItem() {
        // Even an unambiguous discount WORD ("Discount", "Скидка") does not
        // make a POSITIVELY-priced line a discount — the printed positive
        // sign wins. (A real discount on its own row prints negative.)
        XCTAssertEqual(kind("Discount package", 50), .item)
        XCTAssertEqual(kind("Скидочный набор", 200), .item)
    }

    // MARK: - Genuine discounts still classify as .discount

    func testNegativeLine_isDiscount_regardlessOfName() {
        // A negative amount is ALWAYS a discount — the sign alone decides,
        // no name keyword needed.
        XCTAssertEqual(kind("Super Deal", -380), .discount)
        XCTAssertEqual(kind("Anything at all", -5), .discount)
        XCTAssertEqual(kind("Member benefit", -1), .discount)
    }

    func testExplicitDiscountWord_withNonPositiveAmount_isDiscount() {
        // Sign-less / zero-amount discount-named rows: the keyword is the
        // only available signal, so they remain `.discount`.
        XCTAssertEqual(kind("Loyalty discount", -30), .discount)
        XCTAssertEqual(kind("Скидка по карте", -50), .discount)
        XCTAssertEqual(kind("Voucher AB12", 0), .discount)
    }

    // MARK: - Other kinds unaffected

    func testFeeAndTipLines() {
        XCTAssertEqual(kind("Service fee", 3.50), .fee)
        XCTAssertEqual(kind("Tip", 10.00), .tip)
    }

    func testPlainItem() {
        XCTAssertEqual(kind("Cappuccino", 4.50), .item)
        XCTAssertEqual(kind("Burger Deluxe", 12.99), .item)
    }
}

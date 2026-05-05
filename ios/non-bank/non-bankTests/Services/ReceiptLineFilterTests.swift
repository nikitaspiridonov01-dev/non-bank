import XCTest
@testable import non_bank

final class ReceiptLineFilterTests: XCTestCase {

    // MARK: - Anchor (grand total)

    func testClassify_total_isAnchor() {
        XCTAssertEqual(ReceiptLineFilter.classify("TOTAL 1500,00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("Total: 50.00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("Итого 1500"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("К ОПЛАТЕ 1500,00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("UKUPNO 250,00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("Razem 50,00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("GESAMT 80,00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("Totale 30,00"), .anchorTotal)
    }

    // MARK: - Non-product keywords (English)

    func testClassify_subtotalIsNonProduct_notAnchor() {
        // Sub-total is footer noise but not the body terminator.
        XCTAssertEqual(ReceiptLineFilter.classify("SUBTOTAL 1200.00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Sub-total $35"), .skipNonProduct)
    }

    func testClassify_taxesAcrossLanguages() {
        XCTAssertEqual(ReceiptLineFilter.classify("VAT 18% 12.50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Tax 5.00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("TVA 20%"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("IVA 21,00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("MwSt. 7,50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("НДС 18% 12,50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("PDV 50,00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Podatek VAT 5,00"), .skipNonProduct)
    }

    func testClassify_paymentMethodsAcrossLanguages() {
        XCTAssertEqual(ReceiptLineFilter.classify("CASH 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Card 1500.00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Visa 1500"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Картой 1500"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Наличные 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Gotovina 50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Kartica 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Espèces 30,00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Carte bancaire 50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Efectivo 80"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Tarjeta 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Dinheiro 80"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Cartão 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Contanti 30"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Gotówka 50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Apple Pay 1500"), .skipNonProduct)
    }

    func testClassify_changeAndRefund_areNonProduct() {
        XCTAssertEqual(ReceiptLineFilter.classify("Change 5.00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Сдача 5"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Rückgeld 2,00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Reszta 1,50"), .skipNonProduct)
    }

    // MARK: - Discount lines (kept as negative items)

    func testClassify_discountWords_returnDiscountVerdict() {
        // Round C-1: discount lines used to be silently dropped via the
        // nonProductWords list. Now they're kept as their own verdict so
        // downstream code can emit them as negative line items.
        XCTAssertEqual(ReceiptLineFilter.classify("Discount -5.00"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Скидка 10"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Sconto 5"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Rabatt -2,50"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Remise 3,00"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Descuento -1,50"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Desconto 4,00"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Rabat 5,00"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Popust 10"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Voucher -10,00"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("Promo code -3,00"), .discount)
    }

    func testClassify_discountTakesPrecedenceOverAnchor() {
        // A line containing both "discount" and "total" must NOT become an
        // anchorTotal — discount routing has to win to keep the line as an
        // item, otherwise `Total discount: -5,00` gets wrongly treated as
        // the receipt's grand total cutoff.
        XCTAssertEqual(ReceiptLineFilter.classify("Total discount -5,00"), .discount)
    }

    func testClassify_tipsAndService() {
        XCTAssertEqual(ReceiptLineFilter.classify("Tip 10.00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Service charge 15%"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Чаевые 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Mancia 5"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Napojnica 2"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Napiwek 5"), .skipNonProduct)
    }

    func testClassify_loyaltyPoints() {
        XCTAssertEqual(ReceiptLineFilter.classify("Points earned: 25"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Бонусы 50"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Loyalty +12"), .skipNonProduct)
    }

    // MARK: - Patterns

    func testClassify_maskedCardNumber() {
        XCTAssertEqual(ReceiptLineFilter.classify("**** 1234 1500.00"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("xxxx 5678 100"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Visa ending in 4321"), .skipNonProduct)
    }

    func testClassify_phoneNumber() {
        XCTAssertEqual(ReceiptLineFilter.classify("+1 (555) 123-4567"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("+7 916 123 45 67"), .skipNonProduct)
    }

    func testClassify_pureDateTime() {
        XCTAssertEqual(ReceiptLineFilter.classify("12.05.2024 14:30"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("01/02/24"), .skipNonProduct)
    }

    func testClassify_urlOrEmail() {
        XCTAssertEqual(ReceiptLineFilter.classify("https://example.com"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("contact@store.com"), .skipNonProduct)
    }

    // MARK: - Real items (must keep)

    func testClassify_realItems_returnKeep() {
        XCTAssertEqual(ReceiptLineFilter.classify("Apple pie 5,00"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Burger Deluxe 12.99"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Coca Cola 0,5L 2,50"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Bread White 250g"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Хлеб белый 60,00"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Latte vanilla 4.50"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Кофе американо 250"), .keep)
    }

    func testClassify_emptyOrWhitespace_skipped() {
        XCTAssertEqual(ReceiptLineFilter.classify(""), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("   "), .skipNonProduct)
    }

    // MARK: - Edge cases

    func testClassify_taxiNotMatchingTax() {
        // "Taxi" must NOT match the "tax" keyword (word-boundary check).
        XCTAssertEqual(ReceiptLineFilter.classify("Taxi service 25,00"), .keep)
    }

    func testClassify_cardamomNotMatchingCard() {
        // "Cardamom" must NOT match the "card" keyword.
        XCTAssertEqual(ReceiptLineFilter.classify("Cardamom 100g 5,50"), .keep)
    }

    func testClassify_serviceWithoutChargeIsItem() {
        // "Service charge" is a stop phrase; "Service" alone with item context
        // must remain an item (e.g. "Cleaning service 50").
        XCTAssertEqual(ReceiptLineFilter.classify("Cleaning service 50,00"), .keep)
    }

    // MARK: - Round C-2: Serbian Cyrillic admin labels (regression)

    func testClassify_serbianCyrillicCashier_isNonProduct() {
        // Real OCR from a fiscal receipt:
        // "Касир: Nemanja Stojicic 687/1.0.1"
        // Round C-1 wrongly emitted this as item (1.0 from 1.0.1).
        XCTAssertEqual(
            ReceiptLineFilter.classify("Касир: Nemanja Stojicic 687/1.0.1"),
            .skipNonProduct
        )
        // Case-form variants (Slavic declension).
        XCTAssertEqual(ReceiptLineFilter.classify("Касира 12345"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Касиром Nemanja"), .skipNonProduct)
    }

    func testClassify_serbianCyrillicWaiter_isNonProduct() {
        XCTAssertEqual(ReceiptLineFilter.classify("Конобар: Marko"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Конобара: Marko"), .skipNonProduct)
    }

    func testClassify_serbianCyrillicTaxAndAdmin_isNonProduct() {
        // Sub-headers and tax words on Serbian fiscal receipts.
        XCTAssertEqual(ReceiptLineFilter.classify("Артикли промет продаја"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Назив Кол. Укупно"), .skipNonProduct)  // promet would also match... actually "укупно" is an anchor — but "артикли"/"назив" stems should win first
        XCTAssertEqual(ReceiptLineFilter.classify("Ознака Име О-ПДВ Стопа"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("ПФР време: 12345"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Броач рачуна: 72983"), .skipNonProduct)
        // Tax line: "Порез" + "пореза" forms.
        XCTAssertEqual(ReceiptLineFilter.classify("Укупан износ пореза: 3.743,33"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("20,00% 3.743,33 Порез"), .skipNonProduct)
    }

    func testClassify_serbianCyrillicGrandTotal_isAnchor() {
        // "Укупан износ" alone (without "пореза") IS the grand total anchor.
        XCTAssertEqual(ReceiptLineFilter.classify("Укупан износ: 22.460,00"), .anchorTotal)
        XCTAssertEqual(ReceiptLineFilter.classify("Укупно 1500,00"), .anchorTotal)
    }

    // MARK: - Round C-2: English / hotel admin labels (regression)

    func testClassify_hotelBillStaffLabels_isNonProduct() {
        // From "Waiter: Anna Sh Open: 11.04.2026 13:08 Order No. 261505"
        XCTAssertEqual(ReceiptLineFilter.classify("Waiter: Anna"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Server: Marko"), .skipNonProduct)
        // From "Table: 31"
        XCTAssertEqual(ReceiptLineFilter.classify("Table: 31"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Guest: 2"), .skipNonProduct)
        // "Open: 11.04.2026" — both `open` keyword AND date pattern would catch.
        XCTAssertEqual(ReceiptLineFilter.classify("Open: 11.04.2026 13:08"), .skipNonProduct)
        // "Order No. 261505" via "order no" stop phrase
        XCTAssertEqual(ReceiptLineFilter.classify("Order No. 261505"), .skipNonProduct)
    }

    // MARK: - Round C-2: Date patterns (regression)

    func testClassify_textualRussianDate_isNonProduct() {
        // From Wolt screenshot: "27 АПРЕЛЯ 2026 Г. В 13:37"
        // Round C-1 wrongly parsed "37" (from 13:37) as the line total.
        XCTAssertEqual(
            ReceiptLineFilter.classify("27 АПРЕЛЯ 2026 Г. В 13:37"),
            .skipNonProduct
        )
        XCTAssertEqual(
            ReceiptLineFilter.classify("12 January 2026 14:30"),
            .skipNonProduct
        )
    }

    func testClassify_numericDateAnywhere_isNonProduct() {
        // Date glued to other tokens — was missed by the old "whole-line"
        // date pattern.
        XCTAssertEqual(
            ReceiptLineFilter.classify("Open: 11.04.2026 invoice"),
            .skipNonProduct
        )
        XCTAssertEqual(
            ReceiptLineFilter.classify("Issued 2026-04-27 by cashier"),
            .skipNonProduct
        )
    }
}

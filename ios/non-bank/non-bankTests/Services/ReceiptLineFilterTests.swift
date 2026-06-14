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

    func testClassify_taxesAcrossLanguages_areSkippedNonProduct() {
        // Tax / VAT / sales-tax lines used to be kept as their own
        // `.tax` verdict and distributed across split participants.
        // Reclassified as `.skipNonProduct` because tax is store-side
        // metadata already baked into the grand total — never a
        // separate buyer expense. Tax-like buyer charges (city tax,
        // tourist tax) would have to be added manually under "Fee".
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

    func testClassify_marketingWords_areNotDiscounts() {
        // Sign beats name. Marketing words that double as PRODUCT names were
        // removed from the discount list so a positively-priced combo/deal
        // line is never deducted. A line named "Super Deal" is a normal item
        // (a meal deal whose components print at 0.00 while the combo line
        // carries the price). It must classify as `.keep`, NOT `.discount`.
        XCTAssertEqual(ReceiptLineFilter.classify("Super Deal 380,00"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Combo Meal 12.99"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Lunch Deal 8,50"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Family Bundle 24,00"), .keep)
        // Bare "off" / "save" / "saved" were too generic and are gone; they
        // must not trip the discount verdict inside ordinary item names.
        XCTAssertEqual(ReceiptLineFilter.classify("Off-road tyre 99,00"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Save-A-Lot Soap 3,20"), .keep)
    }

    func testClassify_explicitPercentOff_isStillDiscount() {
        // The explicit "% off" markers stay — they're unambiguous discount
        // labels, unlike the bare "off" token we removed.
        XCTAssertEqual(ReceiptLineFilter.classify("20% off -5,00"), .discount)
        XCTAssertEqual(ReceiptLineFilter.classify("10%off -2,00"), .discount)
    }

    func testClassify_discountTakesPrecedenceOverAnchor() {
        // A line containing both "discount" and "total" must NOT become an
        // anchorTotal — discount routing has to win to keep the line as an
        // item, otherwise `Total discount: -5,00` gets wrongly treated as
        // the receipt's grand total cutoff.
        XCTAssertEqual(ReceiptLineFilter.classify("Total discount -5,00"), .discount)
    }

    func testClassify_tipsAndService_returnTipVerdict() {
        // Phase 2: tip / gratuity / service-charge lines now route to the
        // `.tip` verdict (they're kept in the items list so the
        // by-items split calculator distributes them proportionally).
        XCTAssertEqual(ReceiptLineFilter.classify("Tip 10.00"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Service charge 15%"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Чаевые 100"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Mancia 5"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Napojnica 2"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Napiwek 5"), .tip)
    }

    func testClassify_feesAcrossLanguages_returnFeeVerdict() {
        // Phase 2: fee / surcharge lines are kept as `.fee`-kinded items
        // so they're distributed proportionally in the split calculator.
        XCTAssertEqual(ReceiptLineFilter.classify("Service fee 3.50"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Delivery fee 2,00"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Сбор 1,50"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Gebühr 4,00"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Frais de service 2,50"), .fee)
    }

    // MARK: - Round C-3: fragile OCR separator + missing-keyword coverage

    func testClassify_serviceChargeFlexibleSeparator_returnsTipVerdict() {
        // Real OCR often emits multi-word phrases with mangled
        // whitespace (double space, tab) or a hyphen between words.
        // The `[\s\-]+` separator in `WordRegex` keeps the literal
        // single-space match working while picking these up too.
        XCTAssertEqual(ReceiptLineFilter.classify("Service  Charge 5,00"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Service\tCharge 5,00"), .tip)
        XCTAssertEqual(ReceiptLineFilter.classify("Service-Charge 5,00"), .tip)
        // Abbreviated fee forms — "svc fee" / "svc. charge"
        XCTAssertEqual(ReceiptLineFilter.classify("Svc fee 2,00"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Svc. charge 2,00"), .fee)
    }

    func testClassify_russianServiceFee_returnsFeeVerdict() {
        // "Обслуживание" / "За обслуживание" are the most common
        // Russian service-fee phrasings on cafe and restaurant
        // receipts and weren't matched by any of the explicit fee
        // literals (which all use "сбор" or "доставка"). Covered now
        // by the `обслуживан` Cyrillic stem.
        XCTAssertEqual(ReceiptLineFilter.classify("Обслуживание 5%"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("За обслуживание 200"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Обслуживания 150"), .fee)
    }

    func testClassify_xChargeCompoundsAreFee() {
        // The bare word "charge" is too risky to add globally (real
        // items like "Charging pad" would collide), so the specific
        // "... charge" fee compounds we see on receipts are
        // enumerated explicitly.
        XCTAssertEqual(ReceiptLineFilter.classify("Cover charge 3,00"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Booking charge 5,00"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Extra charge 2,00"), .fee)
        XCTAssertEqual(ReceiptLineFilter.classify("Minimum charge 10,00"), .fee)
    }

    func testClassify_chargingPad_isItem_notFee() {
        // Regression guard for the false-positive risk we accepted
        // when adding "... charge" compounds. An item whose name
        // contains "charging" or "charger" must still classify as
        // `.keep` since the compound list requires a qualifier word
        // and the bare `charge` token is not on it.
        XCTAssertEqual(ReceiptLineFilter.classify("Charging pad 19,99"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Phone charger 25,00"), .keep)
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

    /// Regression: EU/Balkan fiscal printers embed a 7-digit code + a
    /// single-letter tax marker in the item name. The phone-number pattern
    /// used to match the "9004375 (" run and drop these REAL grocery items
    /// as non-products. They must classify as `.keep`.
    func testClassify_fiscalProductCode_isKept() {
        XCTAssertEqual(ReceiptLineFilter.classify("Nutella sladoled/KOM/9004375 (Б)"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Rib eye steak/KG/9004639 (E)"), .keep)
        XCTAssertEqual(ReceiptLineFilter.classify("Paprika Mix, süß/0082531 (E)"), .keep)
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

    func testClassify_serbianCyrillicAdmin_isNonProduct() {
        // Sub-headers on Serbian fiscal receipts that aren't tax — these
        // stay routed to `.skipNonProduct` (they're admin labels, not
        // splittable items).
        XCTAssertEqual(ReceiptLineFilter.classify("Артикли промет продаја"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Назив Кол. Укупно"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Ознака Име О-ПДВ Стопа"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("ПФР време: 12345"), .skipNonProduct)
        XCTAssertEqual(ReceiptLineFilter.classify("Броач рачуна: 72983"), .skipNonProduct)
    }

    func testClassify_serbianCyrillicTax_isSkippedNonProduct() {
        // Same change as the multi-language tax test above — Serbian
        // Cyrillic tax stems (порез, пореска) classify as
        // `.skipNonProduct` so the line never reaches the items list.
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

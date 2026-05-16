import XCTest
@testable import non_bank

/// Tests for `ReceiptNLPService` — language detection, currency
/// inference, and keyword dictionary lookups. All public methods
/// are static and pure (no I/O), so the suite is just input →
/// output assertions.
final class ReceiptNLPServiceTests: XCTestCase {

    // MARK: - Language detection

    func testDetectLanguage_englishText() {
        let lang = ReceiptNLPService.detectLanguage(
            text: "Subtotal 12.50 Tax 1.25 Total 13.75"
        )
        XCTAssertEqual(lang, "en")
    }

    func testDetectLanguage_serbianCyrillic_overridesRussianMisclassification() {
        // NLLanguageRecognizer often classifies Serbian Cyrillic as
        // Russian. The service has an explicit override for receipts
        // containing >=2 uniquely-Serbian words.
        let lang = ReceiptNLPService.detectLanguage(
            text: "Артикли укупно: 1500 РСД, Београд"
        )
        XCTAssertEqual(lang, "sr", "Serbian Cyrillic must NOT fall back to Russian")
    }

    func testDetectLanguage_russianText() {
        let lang = ReceiptNLPService.detectLanguage(
            text: "Итого 1500 рублей, кассир Иванов, ндс 250"
        )
        XCTAssertEqual(lang, "ru")
    }

    func testDetectLanguage_germanText() {
        let lang = ReceiptNLPService.detectLanguage(
            text: "Zwischensumme 12.50 EUR, MwSt. enthalten, Gesamtbetrag 13.75"
        )
        XCTAssertEqual(lang, "de")
    }

    func testDetectLanguage_unknownGarbage_returnsSomething() {
        // Anything plausibly detectable returns a code; junk falls back
        // to "und". We don't pin the exact value for short strings —
        // the contract is "non-empty 2-3 char string", not specific code.
        let lang = ReceiptNLPService.detectLanguage(text: "12345 67890")
        XCTAssertFalse(lang.isEmpty)
    }

    // MARK: - Currency detection — explicit glyphs

    func testDetectCurrency_euroGlyph_wins() {
        // €/EUR overrides language inference even on an English receipt.
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(text: "Total: €12.50", language: "en"),
            "EUR"
        )
    }

    func testDetectCurrency_dollarGlyph() {
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(text: "Subtotal: $9.99", language: "en"),
            "USD"
        )
    }

    func testDetectCurrency_rubleGlyphSuppressesDollarFalsePositive() {
        // A receipt with both `₽` and an incidental `$` (e.g. price-tag
        // metadata) must lean RUB, not USD.
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(
                text: "Цена: 100$₽ за услугу",
                language: "ru"
            ),
            "RUB"
        )
    }

    func testDetectCurrency_serbianDinar_byKeyword() {
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(text: "1500 дин", language: "sr"),
            "RSD"
        )
    }

    // MARK: - Currency detection — language inference (no glyph)

    func testDetectCurrency_serbianFallback_isRSD() {
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(text: "Račun 1500", language: "sr"),
            "RSD"
        )
    }

    func testDetectCurrency_eurozoneLanguages_fallToEUR() {
        for lang in ["de", "fr", "es", "it", "pt", "nl"] {
            XCTAssertEqual(
                ReceiptNLPService.detectCurrency(text: "Total 12.50", language: lang),
                "EUR",
                "Language \(lang) without a glyph should fall to EUR"
            )
        }
    }

    func testDetectCurrency_englishWithoutGlyph_fallsToUSD() {
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(text: "Total 12.50", language: "en"),
            "USD"
        )
    }

    func testDetectCurrency_englishWithVAT_inferGBP() {
        // UK receipts often print "VAT" without the £ glyph — bias
        // toward GBP rather than USD in that case.
        XCTAssertEqual(
            ReceiptNLPService.detectCurrency(text: "VAT included Total 12.50", language: "en"),
            "GBP"
        )
    }

    // MARK: - Keyword dictionaries

    func testTotalKeywords_baseSetAlwaysPresent() {
        for lang in ["en", "de", "fr", "ru", "und"] {
            let kws = ReceiptNLPService.totalKeywords(for: lang)
            XCTAssertTrue(kws.contains("total"), "Missing 'total' for \(lang)")
            XCTAssertTrue(kws.contains("sum"), "Missing 'sum' for \(lang)")
        }
    }

    func testTotalKeywords_serbianAndCroatianShareSet() {
        let sr = ReceiptNLPService.totalKeywords(for: "sr")
        let hr = ReceiptNLPService.totalKeywords(for: "hr")
        XCTAssertEqual(Set(sr), Set(hr), "sr and hr must use the same total-keyword set")
        XCTAssertTrue(sr.contains("укупно"))
        XCTAssertTrue(sr.contains("ukupno"))
    }

    func testReceiptStructureKeywords_baseAlwaysIncludesTaxLabels() {
        let kws = ReceiptNLPService.receiptStructureKeywords(for: "en")
        for required in ["subtotal", "tax", "vat", "change", "card"] {
            XCTAssertTrue(kws.contains(required), "Missing '\(required)' in en")
        }
    }

    func testReceiptStructureKeywords_unknownLanguageStillReturnsBase() {
        // A receipt in a language with no dedicated dictionary should
        // still get the base English/global set rather than an empty
        // array — avoids degenerate downstream filtering.
        let kws = ReceiptNLPService.receiptStructureKeywords(for: "zz")
        XCTAssertFalse(kws.isEmpty)
        XCTAssertTrue(kws.contains("tax"))
    }
}

import XCTest
@testable import non_bank

/// Name matching for "the same receipt line read twice" — at the seams of
/// a tall receipt's bands and between scroll screenshots. Cases from a real
/// Serbian receipt (Veropoulos, 15 items) read in three slices.
@MainActor
final class ReceiptNameMatchTests: XCTestCase {

    private func same(_ a: String, _ b: String) -> Bool {
        ReceiptNameMatch.similarKeys(ReceiptNameMatch.key(a), ReceiptNameMatch.key(b))
    }

    func testKey_foldsCaseDiacriticsSpacingAndPunctuation() {
        XCTAssertEqual(ReceiptNameMatch.key("Ćufte sa PIRE, 350 g"), "cuftesapire350g")
        XCTAssertEqual(ReceiptNameMatch.key("PREMIU M 45%"), ReceiptNameMatch.key("PREMIUM 45 %"))
    }

    func testKey_mapsCyrillicLookalikesToLatin() {
        // "GAUDА" with a Cyrillic А, as a model wrote it in one slice.
        XCTAssertEqual(ReceiptNameMatch.key("SIR GAUDА"), ReceiptNameMatch.key("SIR GAUDA"))
        XCTAssertEqual(ReceiptNameMatch.key("КОМ"), "kom")
    }

    func testSameLine_readTwiceAcrossASeam() {
        XCTAssertTrue(same("CIPS DORITOS SWEET CHILI 160GR M ARBO", "CIPS DORITOS SWEET CHILI 160GR ARBO"))
        XCTAssertTrue(same("SIRU GAUDU MLEKOVITA SECENA 150GR", "SIRU GAUDAMLEKOVITA SECENA 150GR"))
        XCTAssertTrue(same("SIR GAUDA MLEKOVITA SECENA 150GR", "SIR GAUDА MLEKOVITA SECENA 150GR"))
        // A misread letter AND a name cut short by the slice edge.
        XCTAssertTrue(same("SIR BISER SELEKIA TRAPIST PREMIUM M 45% MM 2", "SIR BISER SELEKTA TRAPIST PREMIUM 45% MM 200"))
        // Cut short only — the old prefix rule.
        XCTAssertTrue(same("MUSLI PROTEIN 250", "MUSLI PROTEIN 250GR FUN & FIT"))
    }

    func testDifferentProducts_doNotMatch() {
        XCTAssertFalse(same("JOGURT JAGODA 1L", "JOGURT BOROVNICA 1L"))
        XCTAssertFalse(same("COCA COLA 0.5L", "COCA COLA 1.5L"))
        XCTAssertFalse(same("SIR GAUDA 150GR", "SIR EDAMER 150GR"))
        XCTAssertFalse(same("MLEKO ALPSKO 3,5%MM 1L", "MLEKO KRAV.3.5%MM 1L"))
        XCTAssertFalse(same("ZVAKE ORBIT WHITE SPEARMINT PELLETS", "ZVAKE ORBIT WHITE PEPPERMINT PELLETS"))
        XCTAssertFalse(same("", "MLEKO"))
    }

    func testShortNames_needAnExactOrPrefixMatch() {
        // Under 12 characters a single edit is too likely another product.
        XCTAssertFalse(same("VODA 0.5L", "VODA 1.5L"))
        XCTAssertFalse(same("SOK 1L", "SOL 1L"))
        XCTAssertTrue(same("VODA", "VODA 0.5L"))
    }

    func testPrefixEditDistance_isExactWithinTheLimit() {
        func d(_ a: String, _ b: String, _ k: Int) -> Int? {
            ReceiptNameMatch.prefixEditDistance(Array(a), Array(b), limit: k)
        }
        XCTAssertEqual(d("abc", "abc", 2), 0)
        XCTAssertEqual(d("abc", "abcdef", 2), 0)      // the longer one's tail is free
        XCTAssertEqual(d("abxc", "abcdef", 2), 1)     // one extra letter
        XCTAssertEqual(d("axc", "abcdef", 2), 1)      // one substitution
        XCTAssertNil(d("xyz", "abcdef", 2))           // three edits
        XCTAssertEqual(d("", "abc", 1), 0)
    }
}

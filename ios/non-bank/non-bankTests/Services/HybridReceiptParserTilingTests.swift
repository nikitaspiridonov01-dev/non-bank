import XCTest
@testable import non_bank

/// Tests for the tall-receipt tiling merge — the overlap-aware
/// `mergeBandItems` dedup that stitches per-band parse results back into
/// one item list without double-counting the overlap region.
final class HybridReceiptParserTilingTests: XCTestCase {

    private func item(_ name: String, _ total: Double) -> ReceiptItem {
        ReceiptItem(name: name, quantity: 1, price: total, total: total)
    }

    /// The overlap crop makes band A's tail reappear as band B's head;
    /// the duplicated run must be removed exactly once.
    func testMergeDedupesSeamOverlap() {
        let bandA = [item("A", 1), item("B", 2), item("C", 3), item("D", 4)]
        let bandB = [item("C", 3), item("D", 4), item("E", 5), item("F", 6)]
        let merged = HybridReceiptParser.mergeBandItems([bandA, bandB])
        XCTAssertEqual(merged.map(\.name), ["A", "B", "C", "D", "E", "F"])
    }

    /// An item that legitimately repeats far from the seam must NOT be
    /// collapsed — only the contiguous boundary run is deduped.
    func testMergeKeepsLegitDuplicatesAwayFromSeam() {
        let bandA = [item("Banana", 1), item("Milk", 2)]
        let bandB = [item("Bread", 3), item("Banana", 1)]
        let merged = HybridReceiptParser.mergeBandItems([bandA, bandB])
        XCTAssertEqual(merged.map(\.name), ["Banana", "Milk", "Bread", "Banana"])
    }

    /// Same name but different totals at the seam = different items, no
    /// dedup (the strict total check protects against false merges).
    func testMergeDoesNotDedupeWhenTotalsDiffer() {
        let bandA = [item("Coffee", 4.5)]
        let bandB = [item("Coffee", 3.0)]
        let merged = HybridReceiptParser.mergeBandItems([bandA, bandB])
        XCTAssertEqual(merged.count, 2)
    }

    func testMergeConcatenatesWhenNoOverlap() {
        let bandA = [item("A", 1), item("B", 2)]
        let bandB = [item("C", 3), item("D", 4)]
        let merged = HybridReceiptParser.mergeBandItems([bandA, bandB])
        XCTAssertEqual(merged.map(\.name), ["A", "B", "C", "D"])
    }

    func testMergeThreeBandsChained() {
        let a = [item("A", 1), item("B", 2)]
        let b = [item("B", 2), item("C", 3)]   // overlap [B]
        let c = [item("C", 3), item("D", 4)]   // overlap [C]
        let merged = HybridReceiptParser.mergeBandItems([a, b, c])
        XCTAssertEqual(merged.map(\.name), ["A", "B", "C", "D"])
    }

    func testSeamOverlapReportsLongestRun() {
        let a = [item("X", 1), item("C", 3), item("D", 4)]
        let b = [item("C", 3), item("D", 4), item("E", 5)]
        let (dropTail, dropHead) = HybridReceiptParser.seamOverlap(tailOf: a, headOf: b)
        XCTAssertEqual(dropTail, 0)
        XCTAssertEqual(dropHead, 2)   // drop [C, D] off b's head
    }

    /// The band crop slices an item at the seam, so a's last and b's first
    /// items are partials that don't match. The skew search must step over
    /// both and still dedup the real [C, D] overlap.
    func testMergeToleratesEdgeCutPartials() {
        let bandA = [item("A", 1), item("B", 2), item("C", 3), item("D", 4), item("Xcut", 9)]
        let bandB = [item("Ycut", 8), item("C", 3), item("D", 4), item("E", 5), item("F", 6)]
        let merged = HybridReceiptParser.mergeBandItems([bandA, bandB])
        XCTAssertEqual(merged.map(\.name), ["A", "B", "C", "D", "E", "F"])
    }

    /// Model variance: one band truncates a long name and folds diacritics
    /// differently. A solid shared prefix + equal price must still dedup.
    func testMergeDedupesFuzzyTruncatedDiacriticName() {
        let bandA = [item("Coca", 1), item("Mammi Cufte sa pire krompirom", 5)]
        let bandB = [item("Mammi Ćufte sa pire kro.", 5), item("Banana", 2)]
        let merged = HybridReceiptParser.mergeBandItems([bandA, bandB])
        XCTAssertEqual(merged.map(\.name), ["Coca", "Mammi Cufte sa pire krompirom", "Banana"])
    }

    /// Guard against over-dedup: a short shared token must NOT collapse two
    /// different items (prefix rule needs ≥4 chars; "Tea"/"Tea" is fine
    /// only on exact-equal, but different prices keep them apart).
    func testSeamOverlapDoesNotMergeDifferentPricedSameName() {
        let a = [item("Bread", 2.00)]
        let b = [item("Bread", 3.50)]
        let (_, dropHead) = HybridReceiptParser.seamOverlap(tailOf: a, headOf: b)
        XCTAssertEqual(dropHead, 0)
    }

    func testMergeEmptyAndSingle() {
        XCTAssertEqual(HybridReceiptParser.mergeBandItems([]).count, 0)
        let single = [item("A", 1), item("B", 2)]
        XCTAssertEqual(HybridReceiptParser.mergeBandItems([single]).map(\.name), ["A", "B"])
    }

    // MARK: - Fiscal-suffix name normalisation

    /// "Name/UNIT/code (taxLetter)" → "Name". The embedded 7-digit code
    /// otherwise reads as a phone number and the real item is dropped.
    func testNormalizingFiscalSuffix_stripsCodeUnitAndTaxMarker() {
        let cleaned = HybridReceiptParser.normalizingFiscalSuffix(item("Nutella sladoled/KOM/9004375 (Б)", 549))
        XCTAssertEqual(cleaned.name, "Nutella sladoled")
        XCTAssertEqual(cleaned.total, 549)   // other fields preserved
    }

    func testNormalizingFiscalSuffix_stripsUnitlessCode() {
        let cleaned = HybridReceiptParser.normalizingFiscalSuffix(item("Paprika Mix, süß/0082531 (E)", 120))
        XCTAssertEqual(cleaned.name, "Paprika Mix, süß")
    }

    /// Conservative: ordinary names that merely contain a slash or a
    /// trailing "(X)" must be left exactly as-is.
    func testNormalizingFiscalSuffix_leavesOrdinaryNamesUntouched() {
        XCTAssertEqual(HybridReceiptParser.normalizingFiscalSuffix(item("5/8 inch bolt", 3)).name, "5/8 inch bolt")
        XCTAssertEqual(HybridReceiptParser.normalizingFiscalSuffix(item("Vitamin C (E)", 8)).name, "Vitamin C (E)")
        XCTAssertEqual(HybridReceiptParser.normalizingFiscalSuffix(item("Milk 1L", 2)).name, "Milk 1L")
    }

    /// Integration through the real pipeline: fiscal-coded items must
    /// survive `postProcess` (not be dropped as "phone numbers") AND come
    /// out with clean names — exactly the band-1 failure from the logs.
    func testPostProcessKeepsAndCleansFiscalItems() {
        let raw = ParsedReceipt(
            storeName: nil, date: nil,
            items: [
                item("Nutella sladoled/KOM/9004375 (Б)", 549),
                item("Rib eye steak/KG/9004639 (E)", 1200)
            ],
            totalAmount: nil, currency: nil
        )
        let cleaned = HybridReceiptParser.postProcess(raw)
        XCTAssertEqual(cleaned.items.count, 2)
        XCTAssertEqual(cleaned.items.map(\.name), ["Nutella sladoled", "Rib eye steak"])
    }

    // MARK: - A real Serbian receipt (Veropoulos, 15 items) read in slices

    /// Seam items as two slices read them: one dropped an "M", one split
    /// "PREMIUM", one wrote "GAUDА" with a Cyrillic А. Each pair is the same
    /// printed line and must be counted once.
    func testMergeDedupesSeamItemsReadWithSmallDifferences() {
        let bandA = [item("KIKIRIKI JUMBO SUVOPECENI OLJUSTENI SLANI 180G", 169.99),
                     item("MUSLI PROTEIN 250GR FUN & FIT", 374.99),
                     item("CIPS DORITOS SWEET CHILI 160GR M ARBO", 197.99)]
        let bandB = [item("MUSLI PROTEIN 250GR FUN & FIT", 374.99),
                     item("CIPS DORITOS SWEET CHILI 160GR ARBO", 197.99),
                     item("SOK VOCNI 100% JABUKA CR.GROZDE ARONIJA", 217.99)]
        XCTAssertEqual(HybridReceiptParser.mergeBandItems([bandA, bandB]).map(\.lineTotal),
                       [169.99, 374.99, 197.99, 217.99])

        let bandC = [item("SIR BISER SELEKTA TRAPIST PREMIUM 45% MM 200", 607.99),
                     item("SIR GAUDA MLEKOVITA SECENA 150GR", 219.99)]
        let bandD = [item("SIR BISER SELEKTA TRAPIST PREMIU M 45% MM 20", 607.99),
                     item("SIR GAUD\u{0410} MLEKOVITA SECENA 150GR", 219.99),
                     item("LIMUNTUS 6/1 60GR CENTROPROIZVOD", 124.99)]
        XCTAssertEqual(HybridReceiptParser.mergeBandItems([bandC, bandD]).map(\.lineTotal),
                       [607.99, 219.99, 124.99])
    }

    // MARK: - Whole image first, framed bands only when closer to the total

    private func result(_ totals: [Double], total: Double?) -> HybridReceiptParser.Result {
        HybridReceiptParser.Result(
            parsedReceipt: ParsedReceipt(
                storeName: nil, date: nil,
                items: totals.enumerated().map { item("Item \($0.offset)", $0.element) },
                totalAmount: total, currency: "RSD"
            ),
            confidence: .medium, totalsMatch: false,
            source: .cloud(provider: "test"), attemptedProvidersCount: 1
        )
    }

    func testTotalGap() {
        XCTAssertEqual(HybridReceiptParser.totalGap(result([100, 50.5], total: 150.5)), 0, accuracy: 1e-9)
        XCTAssertEqual(HybridReceiptParser.totalGap(result([100, 60], total: 150)), 10, accuracy: 1e-9)
        XCTAssertEqual(HybridReceiptParser.totalGap(result([100], total: nil)), .infinity)
        XCTAssertEqual(HybridReceiptParser.totalGap(result([100], total: 0)), .infinity)
    }

    /// The reported 1.0.5 case: the bands read 5 848.77 against a printed
    /// 3 805.83, the whole photo (prompt revision 2) exactly 3 805.83 — the
    /// whole read is kept.
    func testCloserToTotal_keepsTheWholeReadWhenItAddsUp() {
        let whole = result([449.98, 184.99, 169.99, 374.99, 197.99, 217.99, 399.99, 169.99,
                            35.98, 52.99, 506.99, 607.99, 219.99, 124.99, 90.99], total: 3805.83)
        let bands = result([449.98, 184.99, 184.99, 169.99, 374.99, 197.99, 169.99, 374.99, 197.99,
                            217.99, 399.99, 169.99, 35.98, 52.99, 506.99, 607.99, 506.99, 607.99,
                            219.99, 124.99, 90.99], total: 3805.83)
        XCTAssertEqual(HybridReceiptParser.totalGap(whole), 0, accuracy: 0.001)
        XCTAssertEqual(HybridReceiptParser.totalGap(bands), 2042.94, accuracy: 0.001)
        XCTAssertFalse(HybridReceiptParser.closerToTotal(bands, than: whole))
    }

    func testCloserToTotal_takesBandsThatAddUpWhenTheWholeReadDoesNot() {
        let whole = result([449.98, 184.99, 184.99, 169.99], total: 805.0)
        let bands = result([449.98, 184.99, 169.99], total: 804.96)
        XCTAssertTrue(HybridReceiptParser.closerToTotal(bands, than: whole))
    }

    func testCloserToTotal_tieOrNoTotalKeepsTheWholeRead() {
        XCTAssertFalse(HybridReceiptParser.closerToTotal(result([10, 20], total: 31), than: result([10, 22], total: 31)))
        XCTAssertFalse(HybridReceiptParser.closerToTotal(result([10, 20], total: nil), than: result([10, 25], total: 31)))
    }
}

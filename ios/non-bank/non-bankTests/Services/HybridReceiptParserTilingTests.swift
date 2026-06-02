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

    func testBoundaryOverlapMatchesLongestRun() {
        let a = [item("X", 1), item("C", 3), item("D", 4)]
        let b = [item("C", 3), item("D", 4), item("E", 5)]
        XCTAssertEqual(HybridReceiptParser.boundaryOverlap(tailOf: a, headOf: b), 2)
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
}

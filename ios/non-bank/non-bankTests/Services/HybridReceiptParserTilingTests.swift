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
}

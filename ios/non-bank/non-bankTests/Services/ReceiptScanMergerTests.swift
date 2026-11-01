import XCTest
@testable import non_bank

/// Multi-screenshot receipt merge: picking the printed grand total instead
/// of summing per-photo totals, removing scroll-overlap duplicates, and
/// using the total as a checksum for ambiguous lines.
@MainActor
final class ReceiptScanMergerTests: XCTestCase {

    // MARK: - Helpers

    private func item(_ name: String, _ total: Double) -> ReceiptItem {
        ReceiptItem(name: name, quantity: 1, price: total, total: total)
    }

    private func photo(
        _ items: [ReceiptItem],
        total: Double? = nil,
        source: HybridReceiptParser.Source = .cloud(provider: "test"),
        confidence: HybridReceiptParser.Confidence = .high
    ) -> HybridReceiptParser.Result {
        HybridReceiptParser.Result(
            parsedReceipt: ParsedReceipt(
                storeName: "Store",
                date: nil,
                items: items,
                totalAmount: total,
                currency: "RSD"
            ),
            confidence: confidence,
            totalsMatch: true,
            source: source,
            attemptedProvidersCount: 1
        )
    }

    private func names(_ result: HybridReceiptParser.Result) -> [String] {
        result.parsedReceipt.items.map(\.name)
    }

    private func itemsSum(_ result: HybridReceiptParser.Result) -> Double {
        result.parsedReceipt.items.reduce(0) { $0 + $1.lineTotal }
    }

    // MARK: - The reported Wolt case

    /// Two exact Wolt screenshots. The model reported 3 550 (the sum of the
    /// first screenshot's dishes) as that screenshot's "total"; the second
    /// carries the real 4 564.40. Summing them gave 8 114.40 and a false
    /// "Prices don't add up" banner.
    func testWoltScreenshots_useThePrintedTotal_noFalseMismatch() {
        let first = photo([
            item("Ćuretina u slatko-kiselom sosu sa boranijom 300 g (Gotovo smrznuto jelo)", 1000),
            item("Pileća jetrica u pavlaki sa pire krompirom 350g (gotovo smrznuto jelo)", 720),
            item("Piletina sa pečurkama u krem sosu sa heljdom 350 g (Gotovo smrznuto jelo)", 830),
            item("Krem čorba od bundeve (Крем-суп сливочный из тыквы)", 540),
            item("Corba-pire od sociva (Суп-пюре из чечевицы)", 460),
        ], total: 3550)
        let second = photo([
            item("Klasične kotlete sa heljdom i kremasto-mesnim sosom 350 g (Gotovo smrznuto jelo)", 870),
            item("Pečene ćufte sa kuvanom heljdom i paradajz povrćem 350 g (Gotovo smrznuto jelo)", 760),
            item("Тариф за сервис", 161.40),
            item("Скидки", -777),
        ], total: 4564.40)

        let merged = ReceiptScanMerger.merge([first, second])

        XCTAssertEqual(merged.parsedReceipt.items.count, 9)
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 4564.40, accuracy: 0.001)
        XCTAssertEqual(itemsSum(merged), 4564.40, accuracy: 0.001)
        XCTAssertTrue(merged.totalsMatch)
        XCTAssertEqual(merged.confidence, .high)
    }

    // MARK: - Scroll overlap

    func testScrollOverlap_isDeduped_andConfirmedByTheTotal() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Bread", 200), item("Cheese", 300)]),
            photo([item("Cheese", 300), item("Dates", 400), item("Service fee", 50)], total: 1050),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Bread", "Cheese", "Dates", "Service fee"])
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 1050, accuracy: 0.001)
        XCTAssertEqual(merged.confidence, .high)
    }

    func testScrollOverlap_withoutAnyTotal_isDeduped() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Bread", 200), item("Cheese", 300)]),
            photo([item("Bread", 200), item("Cheese", 300), item("Dates", 400)]),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Bread", "Cheese", "Dates"])
        XCTAssertNil(merged.parsedReceipt.totalAmount)
        XCTAssertEqual(merged.confidence, .high)
    }

    /// Per-photo "totals" that are just each screenshot's own items are not
    /// a grand total — neither alone nor summed (that would count the
    /// overlap twice) — so no total is shown and no mismatch is flagged.
    func testInventedPerScreenshotTotals_areNotTreatedAsTheGrandTotal() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Bread", 200), item("Cheese", 300)], total: 600),
            photo([item("Cheese", 300), item("Dates", 400), item("Service fee", 50)], total: 750),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Bread", "Cheese", "Dates", "Service fee"])
        XCTAssertNil(merged.parsedReceipt.totalAmount)
        XCTAssertTrue(merged.totalsMatch)
    }

    func testSameScreenshotAddedTwice_collapsesToOneCopy() {
        let lines = (0..<14).map { item("Dish \(Character(UnicodeScalar(65 + $0)!)) special", Double(100 + $0)) }
        let copy = lines.map { item($0.name, $0.lineTotal) }
        let merged = ReceiptScanMerger.merge([photo(lines), photo(copy)])
        XCTAssertEqual(names(merged), lines.map(\.name))
    }

    func testThreeChainedScreenshots() {
        let merged = ReceiptScanMerger.merge([
            photo([item("A1 item", 10), item("A2 item", 20), item("A3 item", 30)]),
            photo([item("A3 item", 30), item("B1 item", 40), item("B2 item", 50)]),
            photo([item("B2 item", 50), item("C1 item", 60), item("Fee", 5)], total: 215),
        ])
        XCTAssertEqual(names(merged), ["A1 item", "A2 item", "A3 item", "B1 item", "B2 item", "C1 item", "Fee"])
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 215, accuracy: 0.001)
    }

    /// The fees/discount block shows on the last two screenshots.
    func testTotalsSectionOnTwoScreenshots_isCountedOnce() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Bread", 200)]),
            photo([item("Cheese", 300), item("Fee", 50), item("Discount", -20)], total: 630),
            photo([item("Fee", 50), item("Discount", -20)], total: 630),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Bread", "Cheese", "Fee", "Discount"])
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 630, accuracy: 0.001)
    }

    // MARK: - Ambiguous lines settled by the total

    func testIdenticalLineAtTheSeam_keptWhenTheTotalSaysItWasOrderedTwice() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Burger", 900), item("Beer", 300)]),
            photo([item("Beer", 300), item("Fries", 250)], total: 1750),
        ])
        XCTAssertEqual(names(merged), ["Burger", "Beer", "Beer", "Fries"])
    }

    func testIdenticalLineAtTheSeam_droppedWhenTheTotalSaysItIsAScrollDuplicate() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Burger", 900), item("Beer", 300)]),
            photo([item("Beer", 300), item("Fries", 250)], total: 1450),
        ])
        XCTAssertEqual(names(merged), ["Burger", "Beer", "Fries"])
    }

    func testDoubleOrderInsideOneScreenshot_survivesTheOverlap() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Beer", 300), item("Beer", 300)]),
            photo([item("Beer", 300), item("Beer", 300), item("Chips", 150)], total: 850),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Beer", "Beer", "Chips"])
    }

    /// Only one of several seams is a coincidence: each seam is decided on
    /// its own, not all-or-nothing.
    func testEachSeamIsDecidedSeparately() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Soup", 400), item("Cola", 250)]),
            photo([item("Cola", 250), item("Pasta", 800)]),         // real overlap
            photo([item("Pasta", 800), item("Cake", 350)], total: 2600),  // a second pasta was ordered
        ])
        XCTAssertEqual(itemsSum(merged), 2600, accuracy: 0.001)
        XCTAssertEqual(names(merged), ["Soup", "Cola", "Pasta", "Pasta", "Cake"])
    }

    func testDuplicateAwayFromTheSeam_removedWhenTheTotalConfirms() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Bread", 200), item("Cheese", 300)]),
            photo([item("Dates", 400), item("Eggs", 50)]),
            photo([item("Bread", 200), item("Fig", 70)], total: 1120),
        ])
        XCTAssertEqual(itemsSum(merged), 1120, accuracy: 0.001)
        XCTAssertEqual(names(merged).filter { $0 == "Bread" }.count, 1)
    }

    // MARK: - Order and fuzzy matching

    func testScreenshotsPickedOutOfOrder_areStitchedInReceiptOrder() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Bread", 200), item("Cheese", 300), item("Dates", 400), item("Fee", 50)], total: 1050),
            photo([item("Apple", 100), item("Bread", 200), item("Cheese", 300)]),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Bread", "Cheese", "Dates", "Fee"])
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 1050, accuracy: 0.001)
    }

    func testShuffledThreeScreenshots_addUp() {
        let top = [item("A1 item", 10), item("A2 item", 20), item("A3 item", 30)]
        let middle = [item("A3 item", 30), item("B1 item", 40), item("B2 item", 50)]
        let bottom = [item("B2 item", 50), item("C1 item", 60), item("Fee", 5)]
        let merged = ReceiptScanMerger.merge([photo(middle), photo(top), photo(bottom, total: 215)])
        XCTAssertEqual(itemsSum(merged), 215, accuracy: 0.001)
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 215, accuracy: 0.001)
    }

    func testPhotoOrder_followsTheOverlap() {
        let top = [item("A1 item", 10), item("A2 item", 20), item("A3 item", 30)]
        let middle = [item("A2 item", 20), item("A3 item", 30), item("B1 item", 40), item("B2 item", 50)]
        let bottom = [item("B1 item", 40), item("B2 item", 50), item("C1 item", 60)]
        XCTAssertEqual(ReceiptScanMerger.photoOrder([bottom, top, middle]), [1, 2, 0])
        XCTAssertEqual(ReceiptScanMerger.photoOrder([top, middle, bottom]), [0, 1, 2])
    }

    func testNameCutAtTheScreenEdge_stillMatches() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Krem čorba od bund", 540)]),
            photo([item("Krem čorba od bundeve (Крем-суп сливочный из тыквы)", 540), item("Dates", 400)], total: 1040),
        ])
        XCTAssertEqual(names(merged), ["Apple", "Krem čorba od bundeve (Крем-суп сливочный из тыквы)", "Dates"])
        XCTAssertEqual(itemsSum(merged), 1040, accuracy: 0.001)
    }

    func testBilingualNameReadDifferently_stillMatches() {
        XCTAssertTrue(ReceiptScanMerger.sameLine(
            item("Krem čorba od bundeve", 540),
            item("(Крем-суп) Krem čorba od bundeve", 540)
        ))
        XCTAssertFalse(ReceiptScanMerger.sameLine(item("Coffee", 4.5), item("Coffee", 3.0)))
        XCTAssertFalse(ReceiptScanMerger.sameLine(item("Klasične kotlete", 870), item("Pečene ćufte", 870)))
    }

    // MARK: - Seam rules

    func testSeam_loneMatchThatNeedsASkip_isIgnored() {
        let seam = ReceiptScanMerger.seamOverlap(
            tailOf: [item("Beer", 300), item("Chips", 150)],
            headOf: [item("Beer", 300), item("Fries", 250)]
        )
        XCTAssertEqual(seam.run, 0)
    }

    func testSeam_matchSkippingBothSides_needsThreeLines() {
        let twoLine = ReceiptScanMerger.seamOverlap(
            tailOf: [item("Piletina", 830), item("Beer", 300), item("Cola", 250), item("Krem", 540)],
            headOf: [item("Voda", 180), item("Piletina", 830), item("Beer", 300), item("Kafa", 220)]
        )
        XCTAssertEqual(twoLine.run, 0)
    }

    func testStitch_keepsAPricedLineTheOtherScreenshotSkipped() {
        let stitched = ReceiptScanMerger.stitch([
            [item("Apple", 100), item("Bread", 200), item("Cheese", 300)],
            [item("Xylo", 80), item("Bread", 200), item("Cheese", 300), item("Dates", 400)],
        ])
        XCTAssertEqual(stitched.map(\.name), ["Apple", "Bread", "Cheese", "Xylo", "Dates"])
    }

    // MARK: - Genuine problems still surface

    func testRealMisread_isStillFlagged() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100), item("Bread", 200)]),
            photo([item("Cheese", 380), item("Dates", 400)], total: 1000),
        ])
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 1000, accuracy: 0.001)
        XCTAssertEqual(itemsSum(merged), 1080, accuracy: 0.001)
        XCTAssertFalse(merged.totalsMatch)
        XCTAssertEqual(merged.confidence, .medium)
    }

    func testSeparateReceipts_billIsTheSumOfTheirTotals() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Milk", 120), item("Eggs", 250)], total: 370),
            photo([item("Soap", 90), item("Towel", 400)], total: 490),
        ])
        XCTAssertEqual(names(merged), ["Milk", "Eggs", "Soap", "Towel"])
        XCTAssertEqual(merged.parsedReceipt.totalAmount ?? 0, 860, accuracy: 0.001)
    }

    func testLocalOCRScreenshot_keepsItsLowConfidence() {
        let merged = ReceiptScanMerger.merge([
            photo([item("Apple", 100)], source: .ocrFallback, confidence: .low),
            photo([item("Bread", 200)], total: 300),
        ])
        XCTAssertEqual(merged.confidence, .low)
        XCTAssertEqual(merged.source, .cloud(provider: "test"))
    }

    func testSingleScreenshot_isPassedThroughUnchanged() {
        let only = photo([item("Apple", 100), item("Bread", 200)], total: 999)
        let merged = ReceiptScanMerger.merge([only])
        XCTAssertEqual(names(merged), ["Apple", "Bread"])
        XCTAssertEqual(merged.parsedReceipt.totalAmount, 999)
    }

    /// Analytics: the merged scan reports the most involved way any of its
    /// photos went to the AI (framed > tiled > whole).
    func testLayout_reportsTheMostInvolvedPhoto() {
        var framed = photo([item("Apple", 100)])
        framed.layout = .framed
        var tiled = photo([item("Bread", 200)], total: 300)
        tiled.layout = .tiled
        XCTAssertEqual(ReceiptScanMerger.merge([photo([item("Milk", 50)]), framed, tiled]).layout, .framed)
        XCTAssertEqual(ReceiptScanMerger.merge([photo([item("Milk", 50)]), tiled]).layout, .tiled)
        XCTAssertEqual(ReceiptScanMerger.merge([photo([item("Milk", 50)]), photo([item("Egg", 20)])]).layout, .whole)
    }
}

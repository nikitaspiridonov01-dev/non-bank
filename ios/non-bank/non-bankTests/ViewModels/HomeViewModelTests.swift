import XCTest
@testable import non_bank

@MainActor
final class HomeViewModelTests: XCTestCase {

    private var sut: HomeViewModel!

    override func setUp() {
        super.setUp()
        sut = HomeViewModel()
    }

    // MARK: - Quick Filters

    func testToggleQuickFilter_category() {
        sut.toggleQuickFilter(.category("Food"))
        XCTAssertTrue(sut.activeCategories.contains("Food"))
        XCTAssertTrue(sut.isQuickFilterActive(.category("Food")))

        // Toggle off
        sut.toggleQuickFilter(.category("Food"))
        XCTAssertFalse(sut.activeCategories.contains("Food"))
    }

    // MARK: - hasActiveFilters

    func testHasActiveFilters_noFilters() {
        XCTAssertFalse(sut.hasActiveFilters)
    }

    func testHasActiveFilters_withCategory() {
        sut.activeCategories.insert("Food")
        XCTAssertTrue(sut.hasActiveFilters)
    }

    func testHasActiveFilters_withType() {
        sut.activeTypes.insert(.income)
        XCTAssertTrue(sut.hasActiveFilters)
    }

    // MARK: - clearAllFilters

    func testClearAllFilters() {
        sut.activeCategories = ["Food", "Transport"]
        sut.activeTypes = [.income]

        sut.clearAllFilters()

        XCTAssertTrue(sut.activeCategories.isEmpty)
        XCTAssertTrue(sut.activeTypes.isEmpty)
    }

    // MARK: - Filter Sheet

    func testPrepareFilterSheet_copiesState() {
        sut.activeCategories = ["Food"]
        sut.activeTypes = [.expenses]

        sut.prepareFilterSheet()

        XCTAssertEqual(sut.filterSheetCategories, ["Food"])
        XCTAssertEqual(sut.filterSheetTypes, [.expenses])
    }

    func testApplyFilterSheet_appliesState() {
        sut.filterSheetCategories = ["Transport"]
        sut.filterSheetTypes = [.income]

        sut.applyFilterSheet()

        XCTAssertEqual(sut.activeCategories, ["Transport"])
        XCTAssertEqual(sut.activeTypes, [.income])
    }

    // MARK: - Category Helpers

    func testValidatedCategory_knownCategory() {
        let categories = TestFixtures.sampleCategories
        let tx = TestFixtures.makeTransaction(category: "Food")
        XCTAssertEqual(sut.validatedCategory(for: tx, in: categories), "Food")
    }

    func testValidatedCategory_unknownCategory_fallsBackToGeneral() {
        let categories = TestFixtures.sampleCategories
        let tx = TestFixtures.makeTransaction(category: "NonExistent")
        XCTAssertEqual(sut.validatedCategory(for: tx, in: categories), "General")
    }

    func testValidatedEmoji_knownCategory() {
        let categories = TestFixtures.sampleCategories
        let tx = TestFixtures.makeTransaction(category: "Food")
        XCTAssertEqual(sut.validatedEmoji(for: tx, in: categories), "🍽️")
    }

    // MARK: - formattedSectionDate

    func testFormattedSectionDate_currentYear() {
        let cal = Calendar.current
        let thisYear = cal.component(.year, from: Date())
        var comps = DateComponents()
        comps.year = thisYear
        comps.month = 3
        comps.day = 15
        let date = cal.date(from: comps)!
        let result = sut.formattedSectionDate(date)
        // Should NOT contain the year
        XCTAssertFalse(result.contains(String(thisYear)))
        XCTAssertTrue(result.contains("MAR"))
    }

    func testFormattedSectionDate_differentYear() {
        var comps = DateComponents()
        comps.year = 2020
        comps.month = 6
        comps.day = 10
        let date = Calendar.current.date(from: comps)!
        let result = sut.formattedSectionDate(date)
        XCTAssertTrue(result.contains("2020"))
    }
}

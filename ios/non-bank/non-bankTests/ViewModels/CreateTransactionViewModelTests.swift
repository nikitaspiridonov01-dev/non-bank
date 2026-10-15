import XCTest
@testable import non_bank

@MainActor
final class CreateTransactionViewModelTests: XCTestCase {

    private var sut: CreateTransactionViewModel!

    override func setUp() {
        super.setUp()
        sut = CreateTransactionViewModel()
    }

    // MARK: - isAmountValid

    func testIsAmountValid_emptyString() {
        sut.amount = ""
        XCTAssertFalse(sut.isAmountValid)
    }

    func testIsAmountValid_zero() {
        sut.amount = "0"
        XCTAssertFalse(sut.isAmountValid)
    }

    func testIsAmountValid_validNumber() {
        sut.amount = "50"
        XCTAssertTrue(sut.isAmountValid)
    }

    func testIsAmountValid_decimalWithComma() {
        sut.amount = "50,5"
        XCTAssertTrue(sut.isAmountValid)
    }

    func testIsAmountValid_nonNumeric() {
        sut.amount = "abc"
        XCTAssertFalse(sut.isAmountValid)
    }

    // MARK: - formattedAmount

    func testFormattedAmount_empty() {
        sut.amount = ""
        XCTAssertEqual(sut.formattedAmount, "0")
    }

    func testFormattedAmount_leadingZeros() {
        sut.amount = "0050"
        XCTAssertEqual(sut.formattedAmount, "50")
    }

    func testFormattedAmount_decimalWithLeadingZero() {
        sut.amount = "0.5"
        XCTAssertEqual(sut.formattedAmount, "0.5")
    }

    func testFormattedAmount_normalValue() {
        sut.amount = "123"
        XCTAssertEqual(sut.formattedAmount, "123")
    }

    // MARK: - Font Sizes

    func testTitleDisplayFontSize_short() {
        sut.title = "Hi"
        XCTAssertEqual(sut.titleDisplayFontSize, 36)
    }

    func testTitleDisplayFontSize_medium() {
        sut.title = "Medium length"
        XCTAssertEqual(sut.titleDisplayFontSize, 30)
    }

    func testTitleDisplayFontSize_long() {
        sut.title = "This is a rather long title text"
        XCTAssertEqual(sut.titleDisplayFontSize, 22)
    }

    func testAmountFontSize_short() {
        sut.amount = "50"
        sut.selectedCurrency = "USD"
        // displayLength = 2 + 3 + 1 = 6 → 64
        XCTAssertEqual(sut.amountFontSize, 64)
    }

    func testAmountFontSize_long() {
        sut.amount = "12345678"
        sut.selectedCurrency = "USD"
        // displayLength = 8 + 3 + 1 = 12 → 40
        XCTAssertEqual(sut.amountFontSize, 40)
    }

    // MARK: - Keypad

    func testHandleKeyPress_digit() {
        sut.handleKeyPress("5") { }
        XCTAssertEqual(sut.amount, "5")
    }

    func testHandleKeyPress_dot_onEmpty() {
        sut.handleKeyPress(".") { }
        XCTAssertEqual(sut.amount, "0.")
    }

    func testHandleKeyPress_dot_noDuplicate() {
        sut.amount = "1.5"
        sut.handleKeyPress(".") { }
        XCTAssertEqual(sut.amount, "1.5")
    }

    func testHandleKeyPress_maxDecimalDigits() {
        sut.amount = "1.99"
        sut.handleKeyPress("9") { }
        XCTAssertEqual(sut.amount, "1.99") // No change — max 2 decimals
    }

    func testHandleKeyPress_replacesSingleZero() {
        sut.amount = "0"
        sut.handleKeyPress("5") { }
        XCTAssertEqual(sut.amount, "5")
    }

    func testHandleBackspace() {
        sut.amount = "123"
        sut.handleBackspace()
        XCTAssertEqual(sut.amount, "12")
    }

    func testHandleBackspace_empty() {
        sut.amount = ""
        sut.handleBackspace()
        XCTAssertEqual(sut.amount, "")
    }

    // MARK: - buildTransaction

    func testBuildTransaction_valid() {
        sut.amount = "100"
        sut.title = "Test"
        sut.selectedCurrency = "USD"
        sut.selectedCategory = TestFixtures.makeCategory(emoji: "🍽️", title: "Food")
        sut.isIncome = false
        sut.date = TestFixtures.fixedDate

        let tx = sut.buildTransaction(editingId: nil)
        XCTAssertNotNil(tx)
        XCTAssertEqual(tx?.amount, 100)
        XCTAssertEqual(tx?.category, "Food")
        XCTAssertEqual(tx?.type, .expenses)
        XCTAssertEqual(tx?.id, 0) // new transaction
    }

    func testBuildTransaction_withEditingId() {
        sut.amount = "50"
        sut.selectedCategory = TestFixtures.makeCategory()
        let tx = sut.buildTransaction(editingId: 42)
        XCTAssertEqual(tx?.id, 42)
    }

    func testBuildTransaction_noCategory_returnsNil() {
        sut.amount = "100"
        sut.selectedCategory = nil
        let tx = sut.buildTransaction(editingId: nil)
        XCTAssertNil(tx)
    }

    func testBuildTransaction_emptyTitle_usesDefault() {
        sut.amount = "100"
        sut.title = ""
        sut.selectedCategory = TestFixtures.makeCategory(emoji: "🍽️", title: "Food")
        let tx = sut.buildTransaction(editingId: nil)
        XCTAssertEqual(tx?.title, "My Food")
    }

    func testBuildTransaction_income() {
        sut.amount = "100"
        sut.isIncome = true
        sut.selectedCategory = TestFixtures.makeCategory(emoji: "💰", title: "Salary")
        let tx = sut.buildTransaction(editingId: nil)
        XCTAssertEqual(tx?.type, .income)
    }

    // MARK: - Even split in whole cents

    func testBuildTransaction_evenSplit_sharesAreWholeCentsAndSumToTotal() {
        // 38.99 between me and two friends. Before the fix each share was
        // 12.996666… (shown as "12"); now 13.00 / 13.00 / 12.99.
        sut.amount = "38.99"
        sut.selectedCategory = TestFixtures.makeCategory(emoji: "🍽️", title: "Food")
        sut.isSplitMode = true
        sut.splitMode = .evenly
        sut.youIncludedInSplit = true
        sut.selectedFriends = [Friend(id: "f1", name: "Lera"), Friend(id: "f2", name: "Max")]
        sut.setDefaultPayer()

        let split = sut.buildTransaction(editingId: nil)?.splitInfo
        XCTAssertNotNil(split)
        XCTAssertEqual(split?.myShare, 13.00)
        XCTAssertEqual(split?.friends.map(\.share), [13.00, 12.99])
        let sum = (split?.myShare ?? 0) + (split?.friends.reduce(0) { $0 + $1.share } ?? 0)
        XCTAssertEqual(sum, 38.99, accuracy: 1e-9)
        XCTAssertEqual(split?.lentAmount ?? 0, 25.99, accuracy: 1e-9)
    }

    func testBuildTransaction_evenSplit_userExcluded_friendsCarryTheCents() {
        sut.amount = "100"
        sut.selectedCategory = TestFixtures.makeCategory()
        sut.isSplitMode = true
        sut.splitMode = .evenly
        sut.youIncludedInSplit = false
        sut.selectedFriends = [Friend(id: "f1", name: "A"), Friend(id: "f2", name: "B"), Friend(id: "f3", name: "C")]
        sut.setDefaultPayer()

        let split = sut.buildTransaction(editingId: nil)?.splitInfo
        XCTAssertEqual(split?.myShare, 0)
        XCTAssertEqual(split?.friends.map(\.share), [33.34, 33.33, 33.33])
    }

    func testPerPersonPreview_matchesSavedShare() {
        sut.amount = "38.99"
        sut.isSplitMode = true
        sut.youIncludedInSplit = true
        sut.selectedFriends = [Friend(id: "f1", name: "Lera"), Friend(id: "f2", name: "Max")]
        XCTAssertEqual(sut.perPersonAmountFormatted, "13")
        XCTAssertEqual(sut.myShareAmount, 13.00)
        sut.setDefaultPayer()
        XCTAssertEqual(sut.netLentAmountFormatted, "25.99")
    }

    // MARK: - Populate

    func testPopulate_fromTransaction() {
        let tx = TestFixtures.makeTransaction(
            emoji: "🍽️",
            category: "Food",
            title: "Dinner",
            description: "Nice place",
            amount: 45.50,
            currency: "EUR",
            type: .expenses
        )
        sut.populate(from: tx, categories: TestFixtures.sampleCategories)
        XCTAssertEqual(sut.title, "Dinner")
        XCTAssertEqual(sut.note, "Nice place")
        XCTAssertEqual(sut.selectedCurrency, "EUR")
        XCTAssertEqual(sut.amount, "45.5")
        XCTAssertFalse(sut.isIncome)
        XCTAssertEqual(sut.selectedCategory?.title, "Food")
    }

    func testPopulate_wholeNumber_formatsWithoutDecimals() {
        let tx = TestFixtures.makeTransaction(amount: 100.0)
        sut.populate(from: tx, categories: TestFixtures.sampleCategories)
        XCTAssertEqual(sut.amount, "100")
    }
}

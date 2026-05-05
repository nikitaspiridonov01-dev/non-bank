import XCTest
@testable import non_bank

@MainActor
final class CategoryStoreTests: XCTestCase {

    private var mockRepo: MockCategoryRepository!

    override func setUp() {
        super.setUp()
        mockRepo = MockCategoryRepository()
    }

    // MARK: - Init with empty DB seeds General

    func testInit_emptyDB_seedsGeneral() async {
        let store = CategoryStore(defaults: [], repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(store.categories.contains(where: { $0.title == "General" }))
    }

    // MARK: - Init with defaults seeds when DB is empty

    func testInit_seedsDefaults_whenDBEmpty() async {
        let defaults = [
            Category(emoji: "🍽️", title: "Food"),
            Category(emoji: "🚗", title: "Transport"),
        ]
        let store = CategoryStore(defaults: defaults, repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(store.categories.contains(where: { $0.title == "Food" }))
        XCTAssertTrue(store.categories.contains(where: { $0.title == "Transport" }))
        XCTAssertTrue(store.categories.contains(where: { $0.title == "General" }))
    }

    // MARK: - Add Category

    func testAddCategory_valid() async {
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let newCat = Category(emoji: "🎮", title: "Gaming")
        store.addCategory(newCat)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(store.categories.contains(where: { $0.title == "Gaming" }))
    }

    func testAddCategory_duplicateTitle_rejected() async {
        mockRepo.categories = [Category(emoji: "🍽️", title: "Food")]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let duplicate = Category(emoji: "🥗", title: "Food")
        store.addCategory(duplicate)

        // Should still have only one "Food"
        let foodCount = store.categories.filter { $0.title.lowercased() == "food" }.count
        XCTAssertEqual(foodCount, 1)
    }

    func testAddCategory_duplicateEmoji_rejected() async {
        mockRepo.categories = [Category(emoji: "🍽️", title: "Food")]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let duplicate = Category(emoji: "🍽️", title: "Drinks")
        store.addCategory(duplicate)

        XCTAssertFalse(store.categories.contains(where: { $0.title == "Drinks" }))
    }

    func testAddCategory_invalid_rejected() async {
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let invalid = Category(emoji: "", title: "NoEmoji")
        store.addCategory(invalid)

        XCTAssertFalse(store.categories.contains(where: { $0.title == "NoEmoji" }))
    }

    // MARK: - Remove Category

    func testRemoveCategory_normal() async {
        let cat = Category(emoji: "🎮", title: "Gaming")
        mockRepo.categories = [cat, CategoryStore.uncategorized]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        store.removeCategory(cat)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertFalse(store.categories.contains(where: { $0.title == "Gaming" }))
    }

    func testRemoveCategory_general_protected() async {
        mockRepo.categories = [CategoryStore.uncategorized]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        store.removeCategory(CategoryStore.uncategorized)

        // General should still be there
        XCTAssertTrue(store.categories.contains(where: { $0.title == "General" }))
    }

    // MARK: - Validated Category

    func testValidatedCategory_known() async {
        mockRepo.categories = [
            Category(emoji: "🍽️", title: "Food"),
            CategoryStore.uncategorized,
        ]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let result = store.validatedCategory(for: "Food")
        XCTAssertEqual(result.title, "Food")
    }

    func testValidatedCategory_unknown_returnsGeneral() async {
        mockRepo.categories = [CategoryStore.uncategorized]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let result = store.validatedCategory(for: "NonExistent")
        XCTAssertEqual(result.title, "General")
    }

    // MARK: - Update Category

    func testUpdateCategory() async {
        let cat = Category(emoji: "🍽️", title: "Food")
        mockRepo.categories = [cat, CategoryStore.uncategorized]
        let store = CategoryStore(repo: mockRepo)
        try? await Task.sleep(for: .milliseconds(100))

        let updated = Category(id: cat.id, emoji: "🥗", title: "Healthy Food")
        store.updateCategory(updated)
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(store.categories.contains(where: { $0.title == "Healthy Food" }))
        XCTAssertFalse(store.categories.contains(where: { $0.title == "Food" }))
    }
}

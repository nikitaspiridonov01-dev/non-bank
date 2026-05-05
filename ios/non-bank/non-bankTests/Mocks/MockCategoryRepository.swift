import Foundation
@testable import non_bank

final class MockCategoryRepository: CategoryRepositoryProtocol, @unchecked Sendable {
    var categories: [Category] = []
    private(set) var insertCallCount = 0
    private(set) var updateCallCount = 0
    private(set) var deleteCallCount = 0

    func fetchAll() async -> [Category] { categories }

    func insert(_ category: Category) async {
        insertCallCount += 1
        categories.append(category)
    }

    func update(_ category: Category) async {
        updateCallCount += 1
        if let idx = categories.firstIndex(where: { $0.id == category.id }) {
            categories[idx] = category
        }
    }

    func delete(id: UUID) async {
        deleteCallCount += 1
        categories.removeAll { $0.id == id }
    }
}

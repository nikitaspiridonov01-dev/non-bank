import Foundation

/// Protocol for category data access.
protocol CategoryRepositoryProtocol {
    func fetchAll() async -> [Category]
    func insert(_ category: Category) async
    func update(_ category: Category) async
    func delete(id: UUID) async
}

/// Production implementation backed by DatabaseProtocol.
final class CategoryRepository: CategoryRepositoryProtocol {
    private let db: DatabaseProtocol

    init(db: DatabaseProtocol = SQLiteService.shared) {
        self.db = db
    }

    func fetchAll() async -> [Category] {
        await db.fetchAllCategories()
    }

    func insert(_ category: Category) async {
        await db.insertCategory(category)
    }

    func update(_ category: Category) async {
        await db.updateCategory(category)
    }

    func delete(id: UUID) async {
        await db.deleteCategory(id: id)
    }
}

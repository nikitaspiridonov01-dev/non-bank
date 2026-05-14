
import Foundation
import Combine

@MainActor
class CategoryStore: ObservableObject {
    @Published private(set) var categories: [Category] = []
    
    static let uncategorized = Category(emoji: "🙂", title: "General")

    static let defaultCategories: [Category] = [
        Category(emoji: "🍿", title: "Entertainment"),
        Category(emoji: "💻", title: "Electronics"),
        Category(emoji: "🛠️", title: "Maintenance"),
        Category(emoji: "🐶", title: "Pet"),
        Category(emoji: "🫂", title: "Family"),
        Category(emoji: "📚", title: "Education"),
        Category(emoji: "🏨", title: "Hotel"),
        Category(emoji: "🛒", title: "Groceries"),
        Category(emoji: "🍽️", title: "Food"),
        Category(emoji: "🚗", title: "Transport"),
        Category(emoji: "🏠", title: "Rent"),
        Category(emoji: "☁️", title: "Subscription"),
        Category(emoji: "💡", title: "Utilities"),
        Category(emoji: "👕", title: "Fashion"),
        Category(emoji: "💊", title: "Healthcare"),
        Category(emoji: "🎁", title: "Gift"),
        Category(emoji: "💰", title: "Salary"),
        Category(emoji: "📈", title: "Investments"),
    ]

    private let repo: CategoryRepositoryProtocol
    weak var syncManager: SyncManager?

    nonisolated init(defaults: [Category] = [], repo: CategoryRepositoryProtocol = CategoryRepository()) {
        self.repo = repo
        Task {
            await load(defaults: defaults)
        }
    }

    private func load(defaults: [Category]) async {
        var loaded = await repo.fetchAll()

        // Migrate legacy "Uncategorized" → "General"
        if let legacyIdx = loaded.firstIndex(where: { $0.title == "Uncategorized" }) {
            let legacy = loaded[legacyIdx]
            let migrated = Category(id: legacy.id, emoji: Self.uncategorized.emoji, title: Self.uncategorized.title)
            await repo.update(migrated)
            loaded[legacyIdx] = migrated
        }

        // Remove duplicate categories (keep first occurrence by title)
        var seenTitles = Set<String>()
        var deduped: [Category] = []
        for cat in loaded {
            let key = cat.title.lowercased()
            if seenTitles.contains(key) {
                // Delete the duplicate from DB
                await repo.delete(id: cat.id)
            } else {
                seenTitles.insert(key)
                deduped.append(cat)
            }
        }
        loaded = deduped

        // Seed default categories if none of them exist yet
        if !defaults.isEmpty {
            let hasAnyDefault = loaded.contains { cat in defaults.contains { $0.title == cat.title } }
            if !hasAnyDefault {
                for category in defaults {
                    await repo.insert(category)
                    loaded.append(category)
                }
            }
        }

        // Ensure reserved "General" category always exists
        if !loaded.contains(where: { $0.title == Self.uncategorized.title }) {
            await repo.insert(Self.uncategorized)
            loaded.append(Self.uncategorized)
        }
        self.categories = loaded
    }

    func reloadFromDB() async {
        let loaded = await repo.fetchAll()
        self.categories = loaded
    }

    func addCategory(_ category: Category) {
        guard category.isValid,
              !categories.contains(where: { $0.title.lowercased() == category.title.lowercased() || $0.emoji == category.emoji })
        else { return }
        categories.append(category)
        Task {
            await repo.insert(category)
            await syncManager?.pushCategory(category, action: .save)
        }
    }

    func removeCategory(_ category: Category) {
        // Reserved categories (General + the 18 defaults seeded on
        // first launch) cannot be deleted. They form a stable baseline
        // — receipt-scan category matching narrows to this set, so the
        // user can rename them (via the edit modal) but never remove
        // them entirely.
        guard !Self.isReserved(category) else { return }
        categories.removeAll { $0.id == category.id }
        Task {
            await repo.delete(id: category.id)
            await syncManager?.pushCategory(category, action: .delete)
        }
    }

    func updateCategory(_ category: Category) {
        if let idx = categories.firstIndex(where: { $0.id == category.id }) {
            categories[idx] = category
            Task {
                await repo.update(category)
                await syncManager?.pushCategory(category, action: .save)
            }
        }
    }

    func findCategory(byTitle title: String) -> Category? {
        categories.first { $0.title == title }
    }

    func findCategory(byEmoji emoji: String) -> Category? {
        categories.first { $0.emoji == emoji }
    }
    
    /// Returns the validated category for a transaction.
    /// If the category title doesn't exist in settings, returns "General".
    func validatedCategory(for title: String) -> Category {
        categories.first(where: { $0.title == title }) ?? Self.uncategorized
    }

    /// Reserved set: "General" + the 18 seeded defaults. Matched by
    /// `title` (case-insensitive) so a user-renamed reserved row would
    /// no longer count — that's intentional, the rename modal blocks
    /// reserved-row renames via this same check by surfacing the
    /// "Reserved" badge in the list. Receipt-scan category matching
    /// narrows to this set; see `reservedCategories`.
    static func isReserved(_ category: Category) -> Bool {
        if category.title.lowercased() == uncategorized.title.lowercased() {
            return true
        }
        let reservedTitles = Set(defaultCategories.map { $0.title.lowercased() })
        return reservedTitles.contains(category.title.lowercased())
    }

    /// Live snapshot of the currently-installed reserved categories.
    /// Use this (not `defaultCategories`) when you need real category
    /// records to match against — `defaultCategories` is the seed list,
    /// it doesn't carry the SQLite-assigned UUIDs / latest emoji edits.
    var reservedCategories: [Category] {
        categories.filter { Self.isReserved($0) }
    }
}

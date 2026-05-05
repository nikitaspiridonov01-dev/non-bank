import SwiftUI

// MARK: - Categories Sheet

struct CategoriesSheetView: View {
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @Binding var isPresented: Bool
    @State private var searchText: String = ""
    @State private var showCreateModal: Bool = false

    /// Categories sorted by usage frequency
    private var sortedCategories: [Category] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = query.isEmpty ? categoryStore.categories : categoryStore.categories.filter {
            $0.title.lowercased().contains(query) || $0.emoji.contains(query)
        }
        var stats: [String: Int] = [:]
        for tx in transactionStore.transactions {
            stats[tx.category, default: 0] += 1
        }
        return base.sorted { a, b in
            let fa = stats[a.title] ?? 0
            let fb = stats[b.title] ?? 0
            return fa > fb
        }
    }

    /// The highest usage count across all categories
    private var maxUsageCount: Int {
        var stats: [String: Int] = [:]
        for tx in transactionStore.transactions {
            stats[tx.category, default: 0] += 1
        }
        return stats.values.max() ?? 0
    }

    /// Usage count for a category
    private func usageCount(for title: String) -> Int {
        transactionStore.transactions.filter { $0.category == title }.count
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedCategories) { category in
                    HStack(spacing: 14) {
                        Text(category.emoji)
                            .font(AppFonts.emojiMedium)
                            .frame(width: 38)
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(category.title)
                                .font(AppFonts.labelPrimary)
                            if category.title == CategoryStore.uncategorized.title {
                                Text("Reserved")
                                    .font(AppFonts.captionSmall)
                                    .foregroundColor(.secondary)
                            } else if maxUsageCount > 0 && usageCount(for: category.title) == maxUsageCount {
                                Text("Most often used")
                                    .font(AppFonts.captionSmall)
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                    .padding(.vertical, AppSpacing.xxs)
                    // Block swipe-to-delete for reserved category
                    .deleteDisabled(category.title == CategoryStore.uncategorized.title)
                }
                .onDelete(perform: deleteCategory)
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
            .navigationTitle("Categories")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { isPresented = false }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showCreateModal = true }) {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showCreateModal) {
                CreateCategoryModal(isPresented: $showCreateModal)
                    .environmentObject(categoryStore)
                    .presentationDetents([.medium])
            }
        }
    }

    private func deleteCategory(at offsets: IndexSet) {
        for index in offsets {
            let category = sortedCategories[index]
            // Prevent deleting reserved category
            guard category.title != CategoryStore.uncategorized.title else { continue }
            categoryStore.removeCategory(category)
        }
    }
}

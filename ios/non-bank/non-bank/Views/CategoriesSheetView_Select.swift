import SwiftUI
import Combine

// MARK: - Категория-пикер для создания/редактирования транзакции
//
// Same row vocabulary as the profile-side `CategoriesSheetView` —
// elevated rounded cards, no dividers, "Most often used" subtitle on
// the top-frequency category. The only differences are the title
// ("Choose Category" vs. "Categories") and the tap behaviour (this
// sheet commits the picked category back through `onSelect`, the
// profile sheet supports swipe-to-delete instead).
struct CategoriesSheetView_Select: View {
    @Binding var isPresented: Bool
    @ObservedObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    var onSelect: (Category) -> Void
    @State private var searchText: String = ""
    @State private var showCreateModal: Bool = false

    /// Categories sorted by usage frequency, with optional name/emoji search.
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
            (stats[a.title] ?? 0) > (stats[b.title] ?? 0)
        }
    }

    /// The highest usage count across all categories — drives the
    /// "Most often used" subtitle on whichever category ties for top.
    private var maxUsageCount: Int {
        var stats: [String: Int] = [:]
        for tx in transactionStore.transactions {
            stats[tx.category, default: 0] += 1
        }
        return stats.values.max() ?? 0
    }

    private func usageCount(for title: String) -> Int {
        transactionStore.transactions.filter { $0.category == title }.count
    }

    var body: some View {
        NavigationStack {
            // Same `List + per-row elevated background` pattern as the
            // profile-side `CategoriesSheetView`. Earlier this picker
            // used `.insetGrouped` flat rows with system dividers,
            // which read as a different design language than the rest
            // of the app's pickers (`FriendPickerView`, the profile
            // categories list). Sharing the layout means there's only
            // one "category list" vocabulary across both create and
            // manage flows.
            List {
                if sortedCategories.isEmpty {
                    noResultsInline
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } else {
                    ForEach(sortedCategories) { category in
                        Button {
                            onSelect(category)
                        } label: {
                            categoryRow(category)
                        }
                        .buttonStyle(.plain)
                        .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .listRowInsets(EdgeInsets(
                            top: AppSpacing.xs,
                            leading: AppSpacing.pageHorizontal,
                            bottom: AppSpacing.xs,
                            trailing: AppSpacing.pageHorizontal
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            // No explicit `placement:` — matches `FriendPickerView`
            // ("Who to split with"). On iOS 26 the default places the
            // search bar at the bottom integrated with the toolbar
            // glass instead of pinning it under the title.
            .searchable(text: $searchText, prompt: "Search categories")
            .navigationTitle("Choose Category")
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

    private func categoryRow(_ category: Category) -> some View {
        HStack(spacing: 14) {
            Text(category.emoji)
                .font(AppFonts.emojiMedium)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(category.title)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                if category.title == CategoryStore.uncategorized.title {
                    Text("Reserved")
                        .font(AppFonts.captionSmall)
                        .foregroundColor(AppColors.textSecondary)
                } else if maxUsageCount > 0 && usageCount(for: category.title) == maxUsageCount {
                    Text("Most often used")
                        .font(AppFonts.captionSmall)
                        .foregroundColor(.accentColor)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.vertical, AppSpacing.md)
        // Floor matches the natural height of two-line rows so the
        // single-line ones pad to the same height and the list doesn't
        // visually jump as the user scrolls past the most-used row.
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var noResultsInline: some View {
        VStack(spacing: AppSpacing.md) {
            SearchIllustration(tint: .neutral, size: .standard)
            Text("No results")
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

import SwiftUI

// MARK: - Categories Sheet

struct CategoriesSheetView: View {
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @Binding var isPresented: Bool
    @State private var searchText: String = ""
    @State private var showCreateModal: Bool = false
    /// Drives the edit sheet. Optional so `.sheet(item:)` only presents
    /// when set; cleared on dismiss.
    @State private var editingCategory: Category?

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
            // List (instead of ScrollView + custom layout) so SwiftUI's
            // row diffing keeps scroll position stable when the user
            // types in the search field. Solid `backgroundElevated`
            // fill (matches `FriendPickerView`) — earlier per-row
            // `.glassEffect` pills produced inconsistent rendering in
            // dark mode where adjacent glass elements occasionally
            // merged into a brighter slab on some rows but not others.
            List {
                if sortedCategories.isEmpty {
                    noResultsInline
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } else {
                    ForEach(sortedCategories) { category in
                        // Reserved (General + the seeded defaults) are
                        // fully read-only — they render as plain
                        // content with no Button wrapper, so a tap is
                        // inert and the edit modal never opens. The
                        // "Reserved" subtitle inside `categoryRow` is
                        // the only affordance the user sees.
                        //
                        // Why the change: a previous iteration *did*
                        // open the edit modal for reserved rows
                        // (rename + emoji change cascaded through
                        // transactions). That created a confusing
                        // state — the modal's save button was disabled
                        // for some change combinations and the row
                        // surfaced as "broken sheet with an error" to
                        // users. Treating reserved as read-only end-
                        // to-end is the cleaner story; receipt-scan
                        // category matching still works because it
                        // reads `reservedCategories` from the live
                        // store, not the edit modal.
                        Group {
                            if CategoryStore.isReserved(category) {
                                categoryRow(category)
                            } else {
                                Button {
                                    editingCategory = category
                                } label: {
                                    categoryRow(category)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        // Fill on the content (not via
                        // `listRowBackground`, which would render
                        // edge-to-edge regardless of insets and
                        // make adjacent rows merge into one slab).
                        .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .listRowInsets(EdgeInsets(
                            top: AppSpacing.xs,
                            leading: AppSpacing.pageHorizontal,
                            bottom: AppSpacing.xs,
                            trailing: AppSpacing.pageHorizontal
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        // Custom swipe action so the destructive
                        // button picks up `AppColors.danger` (wine/
                        // rose) instead of iOS's `systemRed`.
                        // Reserved category gets no swipe — gating
                        // on title check skips registering the
                        // action entirely.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if !CategoryStore.isReserved(category) {
                                Button(role: .destructive) {
                                    categoryStore.removeCategory(category)
                                } label: {
                                    // `iconOnly` keeps the trash
                                    // affordance visually identical
                                    // to the Friends list — without
                                    // it iOS picks stacked vs inline
                                    // based on row height and the
                                    // two pages drift apart.
                                    Label("Delete", systemImage: "trash")
                                        .labelStyle(.iconOnly)
                                }
                                .tint(AppColors.danger)
                            }
                        }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            // No explicit `placement:` — matches `FriendPickerView`
            // ("Who to split with"). On iOS 26 the default places the
            // search bar at the bottom integrated with the toolbar
            // glass instead of pinning it under the title, which felt
            // visually heavier than the rest of the picker family.
            .searchable(text: $searchText, prompt: "Search categories")
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
            .sheet(item: $editingCategory) { category in
                EditCategoryModal(
                    isPresented: Binding(
                        get: { editingCategory != nil },
                        set: { if !$0 { editingCategory = nil } }
                    ),
                    category: category
                )
                .environmentObject(categoryStore)
                .environmentObject(transactionStore)
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
                if CategoryStore.isReserved(category) {
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
        // Floor matches the natural height of two-line rows (label +
        // "Most often used" / "Reserved" subtitle) so single-line rows
        // pad to the same height and the list doesn't visually jump.
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

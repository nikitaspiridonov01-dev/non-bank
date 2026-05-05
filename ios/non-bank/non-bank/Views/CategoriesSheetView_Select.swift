import SwiftUI
import Combine

// MARK: - Модалка выбора категории
struct CategoriesSheetView_Select: View {
    @Binding var isPresented: Bool
    @ObservedObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    var onSelect: (Category) -> Void
    @State private var searchText: String = ""
    @State private var showCreateModal: Bool = false

    var filteredCategories: [Category] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let base = query.isEmpty ? categoryStore.categories : categoryStore.categories.filter {
            $0.title.lowercased().contains(query) || $0.emoji.contains(query)
        }
        // Sort by usage frequency
        var stats: [String: Int] = [:]
        for tx in transactionStore.transactions {
            stats[tx.category, default: 0] += 1
        }
        return base.sorted { a, b in
            (stats[a.title] ?? 0) > (stats[b.title] ?? 0)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredCategories) { category in
                    Button(action: { onSelect(category) }) {
                        HStack(spacing: 14) {
                            Text(category.emoji)
                                .font(AppFonts.emojiMedium)
                                .frame(width: 38)
                            Text(category.title)
                                .font(AppFonts.labelPrimary)
                        }
                        .padding(.vertical, AppSpacing.xxs)
                    }
                    .foregroundColor(.primary)
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search categories")
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
}

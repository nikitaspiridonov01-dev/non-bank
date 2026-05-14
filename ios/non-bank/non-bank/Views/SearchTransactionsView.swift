import SwiftUI

struct SearchTransactionsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @State private var query: String = ""
    let transactions: [Transaction]
    var onSelect: ((Transaction) -> Void)?

    private var filtered: [Transaction] {
        guard !query.isEmpty else { return transactions }
        return transactions.filter { tx in
            tx.title.localizedCaseInsensitiveContains(query) ||
            (tx.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    /// Day-grouped results so each section can carry the same uppercase
    /// date header that the home screen uses — keeps the search surface
    /// visually identical to the main feed.
    private var grouped: [(date: Date, transactions: [Transaction])] {
        TransactionFilterService.groupByDay(filtered)
    }

    private func sectionLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = isCurrentYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return f.string(from: date).uppercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
                    if grouped.isEmpty {
                        VStack(spacing: AppSpacing.md) {
                            SearchIllustration(tint: .neutral, size: .standard)
                            Text(query.isEmpty ? "Type to search transactions" : "No results")
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 80)
                    } else {
                        ForEach(grouped, id: \.date) { group in
                            VStack(alignment: .leading, spacing: 0) {
                                Text(sectionLabel(for: group.date))
                                    .font(AppFonts.sectionHeader)
                                    .foregroundColor(AppColors.textSecondary)
                                    .tracking(AppFonts.sectionHeaderTracking)
                                    .padding(.horizontal, AppSpacing.pageHorizontal)
                                    .padding(.top, AppSpacing.xxl)
                                    .padding(.bottom, AppSpacing.sm)

                                ForEach(Array(group.transactions.enumerated()), id: \.element.id) { idx, tx in
                                    TransactionRowView(
                                        transaction: tx,
                                        emoji: categoryStore.validatedCategory(for: tx.category).emoji,
                                        isLast: idx == group.transactions.count - 1,
                                        onTap: {
                                            onSelect?(tx)
                                            isPresented = false
                                        },
                                        onDelete: {
                                            transactionStore.delete(id: tx.id)
                                        }
                                    )
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, AppSpacing.xxxl)
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            // No explicit `placement:` — on iOS 26 the default places
            // the search field at the bottom integrated with the
            // toolbar glass. Matches `CategoriesSheetView` /
            // `CurrencyRatesSheet` / `FriendPickerView`.
            .searchable(text: $query, prompt: "Search by title or notes")
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }
}

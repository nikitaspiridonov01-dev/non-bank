import SwiftUI

struct SearchTransactionsView: View {
    @Binding var isPresented: Bool
    @EnvironmentObject var categoryStore: CategoryStore
    @State private var query: String = ""
    let transactions: [Transaction]
    var onSelect: ((Transaction) -> Void)?

    var filtered: [Transaction] {
        guard !query.isEmpty else { return transactions }
        return transactions.filter { tx in
            tx.title.localizedCaseInsensitiveContains(query) || (tx.description?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List(filtered) { tx in
                Button(action: {
                    onSelect?(tx)
                    isPresented = false
                }) {
                    HStack(spacing: 14) {
                        Text(categoryStore.validatedCategory(for: tx.category).emoji)
                            .font(AppFonts.emojiMedium)
                            .frame(width: 38)
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(tx.title)
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let desc = tx.description, !desc.isEmpty {
                                Text(desc)
                                    .font(AppFonts.rowDescription)
                                    .foregroundColor(AppColors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                        }
                        .layoutPriority(0)
                        Spacer(minLength: 8)
                        AmountView(amount: tx.amount, isIncome: tx.isIncome, currency: tx.currency)
                            .layoutPriority(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, AppSpacing.rowVertical)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search by title or notes")
            .navigationTitle("Search")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }
}

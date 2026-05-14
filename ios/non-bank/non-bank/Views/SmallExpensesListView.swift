import SwiftUI

/// Sheet shown when the user taps "Take a look at these N expenses"
/// on the `SmallPurchasesCard`. Lists every small purchase that fell
/// into the savings analysis (qualifying-month purchases only — same
/// scope as the N count on the card).
///
/// **Layout** mirrors the home transaction list verbatim — same
/// `ScrollView` + `LazyVStack` skeleton, same uppercase day section
/// headers, same `TransactionRowView` for each row (emoji tile +
/// title + description + per-row divider + native swipe-to-delete +
/// amount in the transaction's own currency). Reusing the row
/// component keeps the small-expenses surface visually identical to
/// the main feed and avoids drift between two near-identical layouts.
///
/// Tapping a row pushes `TransactionDetailView` as a sub-sheet so
/// the user can drill into individual purchases without losing the
/// list.
struct SmallExpensesListView: View {

    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    /// Pre-sorted by date desc upstream — we re-bucket by day for
    /// section headers but trust the parent ordering otherwise.
    let purchases: [Transaction]

    /// `Transaction` is already `Identifiable` (Int id) so the
    /// `.sheet(item:)` binding works directly without a wrapper.
    @State private var selectedTransaction: Transaction?

    /// Stacks `CreateTransactionModal` *on top* of the detail sheet
    /// when the user taps Edit. Routing through the global
    /// `NavigationRouter` would present the editor from
    /// `MainTabView`, which sits behind the Insights sheet — the
    /// editor wouldn't appear until Insights was manually
    /// dismissed. Local state lets the editor stack above
    /// Insights for the "tap → edit immediately" flow.
    @State private var editingTransaction: Transaction? = nil

    // MARK: - Derived

    /// Day-grouped buckets, newest day first. Matches the order the
    /// home feed uses for its sections.
    private var grouped: [(date: Date, transactions: [Transaction])] {
        TransactionFilterService.groupByDay(purchases)
    }

    /// `WED, APR 29` (or `WED, APR 29, 2024` cross-year). Same
    /// formatting `HomeViewModel.formattedSectionDate` produces, so
    /// the headers read identically to the home feed.
    private func sectionLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = isCurrentYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return formatter.string(from: date).uppercased()
    }

    /// Live emoji from `CategoryStore` so a renamed/recoloured
    /// category shows its current glyph. Falls back to the
    /// transaction's stored emoji for categories that no longer
    /// exist.
    private func emoji(for tx: Transaction) -> String {
        categoryStore.findCategory(byTitle: tx.category)?.emoji ?? tx.emoji
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: []) {
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
                                    emoji: emoji(for: tx),
                                    isLast: idx == group.transactions.count - 1,
                                    onTap: {
                                        selectedTransaction = tx
                                    },
                                    onDelete: {
                                        transactionStore.delete(id: tx.id)
                                    }
                                )
                            }
                        }
                    }
                }
                .padding(.bottom, AppSpacing.xxxl)
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Small expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // Detail sheet hosts a *nested* edit sheet — same
            // pattern `TransactionDetailView` uses for its
            // `splitBreakdownTransaction` → `editingFromBreakdown`
            // chain. Two-`.sheet`-modifiers-on-the-same-view variant
            // hung the sheet stack when both states changed in one
            // tick (binding setter trying to dismiss two sheets at
            // once); nesting lets iOS handle stacking gracefully.
            .sheet(item: $selectedTransaction) { tx in
                TransactionDetailView(
                    transaction: tx,
                    onEdit: {
                        // Stack edit on top of detail instantly.
                        editingTransaction = tx
                    },
                    onDelete: {
                        transactionStore.delete(id: tx.id)
                        selectedTransaction = nil
                    },
                    onClose: {
                        selectedTransaction = nil
                    }
                )
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
                .environmentObject(receiptItemStore)
                .sheet(item: $editingTransaction) { editTx in
                    CreateTransactionModal(
                        isPresented: Binding(
                            get: { true },
                            set: { if !$0 { editingTransaction = nil } }
                        ),
                        editingTransaction: editTx
                    )
                    .environmentObject(transactionStore)
                    .environmentObject(categoryStore)
                    .environmentObject(currencyStore)
                    .environmentObject(friendStore)
                    .environmentObject(receiptItemStore)
                }
            }
            // After the editor dismisses (binding setter has
            // already zeroed `editingTransaction`), close the
            // detail sheet beneath it so the user lands back on
            // the small-expenses list. Small delay lets iOS finish
            // the editor's dismiss animation before tearing down
            // the parent — collapsing both simultaneously had
            // previously hung the sheet stack.
            .onChange(of: editingTransaction) { oldValue, newValue in
                if oldValue != nil && newValue == nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        selectedTransaction = nil
                    }
                }
            }
        }
    }
}

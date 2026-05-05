import SwiftUI

/// Sheet shown when the user taps "Take a look at these N expenses"
/// on the `SmallPurchasesCard`. Lists every small purchase that
/// fell into the savings analysis (qualifying-month purchases
/// only — same scope as the N count on the card).
///
/// **Layout** mirrors the home transaction list: rows grouped under
/// a per-day section header (`WED, APR 29`), each row showing
/// emoji + title + amount. The category name is intentionally
/// omitted from the row — the emoji already encodes the category,
/// and the date now lives in the section header instead of the
/// row's subtitle.
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

    /// Pre-sorted by date desc upstream — we re-bucket by day for
    /// section headers but trust the parent ordering otherwise.
    let purchases: [Transaction]

    /// `Transaction` is already `Identifiable` (Int id) so the
    /// `.sheet(item:)` binding works directly without a wrapper.
    @State private var selectedTransaction: Transaction?

    // MARK: - Derived

    /// Groups purchases by start-of-day, sorted newest-first.
    /// Each section in the list = one day of small purchases.
    private var groupedByDay: [(date: Date, purchases: [Transaction])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: purchases) { tx in
            calendar.startOfDay(for: tx.date)
        }
        return groups.keys.sorted(by: >).map { date in
            // Within a day, keep the original sort (newest moments
            // first — same as the home list's intra-day ordering).
            (date, groups[date]!.sorted { $0.date > $1.date })
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(groupedByDay, id: \.date) { group in
                        sectionHeader(date: group.date)
                        VStack(spacing: AppSpacing.sm) {
                            ForEach(group.purchases) { tx in
                                Button {
                                    selectedTransaction = tx
                                } label: {
                                    row(for: tx)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, AppSpacing.sm)
                    }
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.bottom, AppSpacing.xxl)
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Small expenses")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            // Sub-sheet for individual transaction detail. Same
            // env-object plumbing as the parent — sheets don't
            // auto-inherit so we forward explicitly.
            .sheet(item: $selectedTransaction) { tx in
                TransactionDetailView(transaction: tx)
                    .environmentObject(transactionStore)
                    .environmentObject(categoryStore)
                    .environmentObject(currencyStore)
                    .environmentObject(friendStore)
            }
        }
    }

    // MARK: - Section header

    /// `WED, APR 29` style header that visually separates day
    /// groups — same vocabulary the home transaction list uses for
    /// its sticky date headers (`AppFonts.sectionHeader` etc.).
    private func sectionHeader(date: Date) -> some View {
        SectionHeader(text: formatSectionDate(date))
            .padding(.top, AppSpacing.lg)
            .padding(.bottom, AppSpacing.sm)
    }

    /// "WED, APR 29" or "WED, APR 29, 2024" depending on whether
    /// the date is in the current calendar year. Year-suppression
    /// matches what the home screen does for its sticky headers.
    private func formatSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date)
            == calendar.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = isCurrentYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return formatter.string(from: date).uppercased()
    }

    // MARK: - Row

    /// Compact row: emoji + title + amount on a single line. No
    /// category subtitle (the emoji encodes the category already);
    /// no date subtitle (it's in the section header above).
    private func row(for tx: Transaction) -> some View {
        HStack(spacing: AppSpacing.md) {
            emojiTile(emoji(for: tx))

            Text(tx.title.isEmpty ? tx.category : tx.title)
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            amountText(for: tx)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .rowPill()
    }

    private func emojiTile(_ emoji: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(AppColors.backgroundChip)
            Text(emoji)
                .font(AppFonts.emojiMedium)
        }
        .frame(width: 40, height: 40)
    }

    /// Live emoji from `CategoryStore` so a renamed/recoloured
    /// category shows its current glyph. Falls back to the
    /// transaction's stored emoji for categories that no longer
    /// exist.
    private func emoji(for tx: Transaction) -> String {
        categoryStore.findCategory(byTitle: tx.category)?.emoji ?? tx.emoji
    }

    /// Single-Text concat — same pattern the rest of Insights
    /// uses so the natural width is measured atomically.
    private func amountText(for tx: Transaction) -> Text {
        let amount = currencyStore.convert(
            amount: tx.amount,
            from: tx.currency,
            to: currencyStore.selectedCurrency
        )
        return Text(NumberFormatting.integerPart(amount))
            .font(AppFonts.rowAmountInteger)
            .foregroundColor(AppColors.textPrimary)
        + Text(NumberFormatting.decimalPartIfAny(amount))
            .font(AppFonts.rowAmountCurrency)
            .foregroundColor(AppColors.textSecondary)
        + Text(" \(currencyStore.selectedCurrency)")
            .font(AppFonts.rowAmountCurrency)
            .foregroundColor(AppColors.textSecondary)
    }
}

import SwiftUI

/// "This purchase was X — Nx more than your usual <category> purchase."
///
/// Surfaces the **single most outstanding purchase** the user made
/// in the previous fully-completed calendar month, measured by
/// per-category z-score against their all-time history of that
/// category.
///
/// **Layout** mirrors the home transaction list at the top of the
/// card — emoji tile + title + (optional) description in a tappable
/// pill — so the card unambiguously refers to ONE specific purchase
/// (rather than the category total). Tapping the pill opens
/// `TransactionDetailView` as a sheet so the user can drill in.
///
/// Card hides itself when no transaction qualifies.
struct BigPurchaseCard: View {

    /// Pre-computed analytics context built once at the parent
    /// (`InsightsView`) and passed down. Replaces the
    /// `transactionStore` / `categoryStore` / `currencyStore` trio
    /// + the `convert` / `emojiByCategory` boilerplate that every
    /// Insights card used to duplicate.
    let context: AnalyticsContext

    /// Stores still injected for **sheet re-injection** only:
    /// `TransactionDetailView` reads them via `@EnvironmentObject`
    /// and sheets don't auto-inherit the parent's environment.
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore

    /// Drives the transaction-detail sheet. Toggled by the tappable
    /// pill at the top of the card; SwiftUI's sheet binding zeroes
    /// it back to false on drag-dismiss / Close-button.
    @State private var showTransactionDetail: Bool = false

    // MARK: - Derived

    private var purchase: CategoryAnalyticsService.BigPurchase? {
        context.biggestPurchaseInLastMonth
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let p = purchase {
                content(for: p)
            }
        }
    }

    private func content(for p: CategoryAnalyticsService.BigPurchase) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            transactionRow(for: p)
            narrative(for: p)
        }
        .insightCardShell()
        // Sheet is attached to the content (which has `p` in scope)
        // so the closure can capture the transaction without a
        // separate `selectedTransaction` state. Standard
        // modal-on-modal pattern matching `HomeView`'s usage of
        // `TransactionDetailView`.
        .sheet(isPresented: $showTransactionDetail) {
            TransactionDetailView(transaction: p.transaction)
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
        }
    }

    // MARK: - Tappable transaction row

    /// Mirrors the home transaction-list row layout (emoji tile +
    /// title + optional description) inside a rounded pill so the
    /// tappable region is unambiguous. The chevron on the trailing
    /// edge hints "this opens something" — without it the row reads
    /// as decorative.
    private func transactionRow(for p: CategoryAnalyticsService.BigPurchase) -> some View {
        Button {
            showTransactionDetail = true
        } label: {
            HStack(spacing: AppSpacing.md) {
                EmojiTile(emoji: p.categoryEmoji, size: .compact)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(displayTitle(for: p))
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let desc = p.transaction.description, !desc.isEmpty {
                        Text(desc)
                            .font(AppFonts.rowDescription)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(AppFonts.captionSmallStrong)
                    .foregroundColor(AppColors.textTertiary)
            }
            .rowPill()
        }
        .buttonStyle(.plain)
    }

    /// Falls back to the category title when the transaction has
    /// no title set — defensive, shouldn't happen for real data.
    private func displayTitle(for p: CategoryAnalyticsService.BigPurchase) -> String {
        p.transaction.title.isEmpty ? p.categoryTitle : p.transaction.title
    }

    // MARK: - Narrative

    /// Bold sentence with **amount** and **multiplier** emphasized
    /// in the warm accent. Wording reads as a single conversational
    /// statement: the date is woven into the subject ("This
    /// purchase, on Apr 15, was…"), and the comparison clause
    /// starts with "it's" so the second half flows naturally from
    /// the dash. "Your usual <category> purchase" keeps the
    /// per-purchase comparison transparent.
    private func narrative(for p: CategoryAnalyticsService.BigPurchase) -> some View {
        let amount = formatAmount(p.convertedAmount)
        let mult = formatMultiplier(p.multiplier)
        let date = formatDate(p.transaction.date)

        return (
            Text("This purchase, on ")
                .foregroundColor(AppColors.textPrimary)
            + Text(date)
                .foregroundColor(AppColors.textPrimary)
            + Text(", was ")
                .foregroundColor(AppColors.textPrimary)
            + Text(amount)
                .foregroundColor(AppColors.reminderAccent)
            + Text(" — it's ")
                .foregroundColor(AppColors.textPrimary)
            + Text("\(mult)× more")
                .foregroundColor(AppColors.reminderAccent)
            + Text(" than your usual ")
                .foregroundColor(AppColors.textPrimary)
            + Text(p.categoryTitle)
                .foregroundColor(AppColors.textPrimary)
            + Text(" purchase.")
                .foregroundColor(AppColors.textPrimary)
        )
        .font(AppFonts.titleSmall)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

    private func formatAmount(_ value: Double) -> String {
        let int = NumberFormatting.integerPart(value)
        let dec = NumberFormatting.decimalPartIfAny(value)
        return "\(int)\(dec) \(context.targetCurrency)"
    }

    private func formatMultiplier(_ mult: Double) -> String {
        if mult >= 10 {
            return String(format: "%.0f", mult)
        }
        return String(format: "%.1f", mult)
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let calendar = Calendar.current
        let yearOfDate = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        formatter.dateFormat = (yearOfDate == currentYear) ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: date)
    }
}

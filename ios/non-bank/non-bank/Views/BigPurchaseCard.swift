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
    /// `TransactionDetailView` and `CreateTransactionModal` read
    /// them via `@EnvironmentObject` and sheets don't auto-inherit
    /// the parent's environment.
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    /// Drives the transaction-detail sheet. Toggled by the tappable
    /// pill at the top of the card; SwiftUI's sheet binding zeroes
    /// it back to false on drag-dismiss / Close-button.
    @State private var showTransactionDetail: Bool = false

    /// Stacks `CreateTransactionModal` *on top* of the detail sheet
    /// when the user taps Edit. Routing through the global
    /// `NavigationRouter` (which is what `HomeView` does) doesn't
    /// work here — that router-driven sheet is hosted by
    /// `MainTabView`, which is hidden behind the Insights sheet,
    /// so the editor wouldn't appear until the user manually
    /// dismissed Insights. Presenting locally lets the editor
    /// stack on top of Insights and the detail sheet, exactly the
    /// "tap → edit immediately" flow the user expects.
    @State private var editingTransaction: Transaction? = nil

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
        // Detail sheet hosts a *nested* edit sheet — same pattern as
        // `TransactionDetailView`'s `splitBreakdownTransaction` →
        // `editingFromBreakdown` chain. Earlier two-`.sheet`-modifiers-
        // on-the-same-view variant hung the sheet stack when both
        // states changed in the same tick (binding setter trying to
        // dismiss two sheets at once); nesting the second sheet
        // inside the first sheet's content closure lets iOS handle
        // the stacking gracefully.
        .sheet(isPresented: $showTransactionDetail) {
            TransactionDetailView(
                transaction: p.transaction,
                onEdit: {
                    // Just open the editor on top of the detail —
                    // no dismiss-then-present dance. Stacking is
                    // instant, no perceptible delay before Edit.
                    editingTransaction = p.transaction
                },
                onDelete: {
                    transactionStore.delete(id: p.transaction.id)
                    showTransactionDetail = false
                },
                onClose: {
                    showTransactionDetail = false
                }
            )
            .environmentObject(transactionStore)
            .environmentObject(categoryStore)
            .environmentObject(currencyStore)
            .environmentObject(friendStore)
            .environmentObject(receiptItemStore)
            .sheet(item: $editingTransaction) { tx in
                CreateTransactionModal(
                    isPresented: Binding(
                        get: { true },
                        set: { if !$0 { editingTransaction = nil } }
                    ),
                    editingTransaction: tx
                )
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
                .environmentObject(receiptItemStore)
            }
        }
        // After the editor dismisses (binding setter has already
        // zeroed `editingTransaction`), tear down the detail sheet
        // beneath it so the user lands back on Insights in one
        // step. Small delay lets iOS finish the editor's dismiss
        // animation first — collapsing both at the same instant
        // had previously hung the sheet stack.
        .onChange(of: editingTransaction) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showTransactionDetail = false
                }
            }
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

    /// Bold single-paragraph narrative. Two-colour Insights
    /// vocabulary keeps the bright orange `accent` reserved for
    /// clickable elements; non-clickable emphasis (date, amount,
    /// multiplier, category) uses `accentBold` — the deep warm
    /// sienna variant of the accent, noticeable enough to make the
    /// numbers/nouns pop against the `textPrimary` prose, but
    /// muted enough that it doesn't compete with the clickable
    /// orange CTAs. Amount uses the transaction's own currency —
    /// the user thinks of a $400 ticket as "$400", not as the
    /// RSD-equivalent rounded number.
    private func narrative(for p: CategoryAnalyticsService.BigPurchase) -> some View {
        let amount = formatAmount(p.transaction.amount, currency: p.transaction.currency)
        let mult = formatMultiplier(p.multiplier)
        let date = formatDate(p.transaction.date)

        return (
            Text("This purchase, on ")
                .foregroundColor(AppColors.textPrimary)
            + Text(date)
                .foregroundColor(AppColors.accentBold)
            + Text(", was ")
                .foregroundColor(AppColors.textPrimary)
            + Text(amount)
                .foregroundColor(AppColors.accentBold)
            + Text(" — it's ")
                .foregroundColor(AppColors.textPrimary)
            + Text("\(mult)× more")
                .foregroundColor(AppColors.accentBold)
            + Text(" than your usual ")
                .foregroundColor(AppColors.textPrimary)
            + Text(p.categoryTitle)
                .foregroundColor(AppColors.accentBold)
            + Text(" purchase.")
                .foregroundColor(AppColors.textPrimary)
        )
        .font(AppFonts.titleSmall)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

    /// Glues integer/decimal/currency together with **non-breaking
    /// spaces** (`\u{00A0}`) so the entire amount wraps as one unit
    /// — when the narrative line breaks, "10 000 RSD" stays whole on
    /// whichever line it lands on rather than splitting between
    /// "10" and "000 RSD". `NumberFormatting.integerPart` itself
    /// emits a regular space as the group separator, so we sweep
    /// the assembled string to swap every space (group separator +
    /// the one before the currency code) for the non-breaking
    /// equivalent.
    private func formatAmount(_ value: Double, currency: String) -> String {
        let int = NumberFormatting.integerPart(value)
        let dec = NumberFormatting.decimalPartIfAny(value)
        return "\(int)\(dec) \(currency)".replacingOccurrences(of: " ", with: "\u{00A0}")
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

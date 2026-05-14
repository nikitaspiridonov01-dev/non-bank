import SwiftUI

/// "You could save up to X per month. Take a look at these N expenses."
///
/// Surfaces the user's recurring small-purchase habits — coffees,
/// snacks, vending machines — and shows the maximum monthly amount
/// they bleed on those, along with a tappable count linking to the
/// full list of qualifying transactions.
///
/// The "small" threshold is **adaptive**: it's derived from the
/// user's own typical-purchase distribution
/// (`min(Q1, mean × 0.4)`) and recomputed every render, so when
/// the user's spending pattern shifts the definition of "small"
/// auto-adjusts. See `CategoryAnalyticsService.smallPurchasesSavings`
/// for the full logic + the same-category-4+ qualifying rule.
///
/// Card hides itself when no qualifying habits surface.
struct SmallPurchasesCard: View {

    /// Pre-computed analytics context — replaces the
    /// `transactionStore` / `categoryStore` / `currencyStore` trio
    /// + the `convert` / `emojiByCategory` boilerplate.
    let context: AnalyticsContext

    /// Stores still injected for **sheet re-injection** only:
    /// `SmallExpensesListView` (and the `TransactionDetailView` it
    /// pushes per row) read them via `@EnvironmentObject`.
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore

    @State private var showExpensesList: Bool = false

    // MARK: - Derived

    private var savings: CategoryAnalyticsService.SmallPurchasesSavings? {
        context.smallPurchasesSavings
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let s = savings {
                content(for: s)
            }
        }
    }

    private func content(for s: CategoryAnalyticsService.SmallPurchasesSavings) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            EmojiTile(emoji: s.mostFrequentCategoryEmoji, size: .hero, background: AppColors.insightRowFill)
            narrative(for: s)
            subtitle
            expensesLink(for: s)
                .padding(.top, AppSpacing.xs)
        }
        .insightCardShell()
        .sheet(isPresented: $showExpensesList) {
            SmallExpensesListView(purchases: s.smallPurchases)
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
        }
    }

    // MARK: - Narrative

    /// Bold sentence — bright orange `accent` is reserved for
    /// clickable elements; the non-clickable savings amount uses
    /// `accentBold` (deep warm sienna) to draw the eye without
    /// competing with the clickable orange CTAs below.
    private func narrative(for s: CategoryAnalyticsService.SmallPurchasesSavings) -> some View {
        let amount = formatAmount(s.maxMonthlySavings)
        return (
            Text("You could save up to ")
                .foregroundColor(AppColors.textPrimary)
            + Text(amount)
                .foregroundColor(AppColors.accentBold)
            + Text(" per month.")
                .foregroundColor(AppColors.textPrimary)
        )
        .font(AppFonts.titleSmall)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Subtitle

    /// Small explanatory line under the headline. Sets the
    /// expectation that "small" is the point: each individual
    /// purchase is easy to dismiss, but collectively they're a
    /// real expense category.
    private var subtitle: some View {
        Text("Small purchases are easy to overlook on their own — but together they add up to a real expense category.")
            .font(AppFonts.caption)
            .foregroundColor(AppColors.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Expenses link (CTA)

    /// Tappable row pill ("Take a look at these N expenses →") that
    /// opens the detail sheet. Tinted with the orange `accentColor`
    /// — the only accent reserved for clickable affordances on the
    /// Insights surface, so this CTA reads as the primary action of
    /// the card.
    private func expensesLink(for s: CategoryAnalyticsService.SmallPurchasesSavings) -> some View {
        Button {
            showExpensesList = true
        } label: {
            HStack(spacing: AppSpacing.sm) {
                Text("Take a look at these \(s.totalQualifyingSmallPurchases) expenses")
                    .font(AppFonts.bodySmallEmphasized)
                    .foregroundColor(.accentColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                Image(systemName: "arrow.right")
                    .font(AppFonts.captionSmallStrong)
                    .foregroundColor(.accentColor)
            }
            .rowPill()
        }
        .buttonStyle(.plain)
    }

    // MARK: - Formatting

    /// Non-breaking spaces glue the amount together so it wraps as
    /// one unit — see the matching helper in `BigPurchaseCard` for
    /// the full reasoning.
    private func formatAmount(_ value: Double) -> String {
        let int = NumberFormatting.integerPart(value)
        let dec = NumberFormatting.decimalPartIfAny(value)
        return "\(int)\(dec) \(context.targetCurrency)".replacingOccurrences(of: " ", with: "\u{00A0}")
    }
}

import SwiftUI

/// Analytics screen reached from the Home period bar's "Insights"
/// button. Presented as a sheet so the user can dismiss back to the
/// transaction list with a single swipe.
///
/// v1 cards:
///  - **Top spending categories** ("Where did you spend the most
///    money in <period>?") — sum of `.expenses` per category, desc.
///  - **Top earning categories** ("Where did you earn the most money
///    in <period>?") — sum of `.income` per category, desc.
///
/// Each card shows a top-3 preview with a "See all" link that pushes
/// the full list (`InsightsDetailView`) onto the navigation stack.
/// Period is **shared** across both preview cards and either detail
/// screen — switching the month anywhere updates everything.
///
/// Default period is the most recent fully-completed calendar month
/// (so on April 17 → "March 2026"); users typically open analytics
/// to ask "where did last month go".
///
/// **Card visibility rule**: a card is hidden entirely when the user
/// has *never* recorded a transaction of that type. So a brand-new
/// account with only outflows won't show the empty "Top earning"
/// card — it just disappears until at least one income exists. This
/// is checked against the *full* transaction list, not the
/// period-filtered one, so picking a slow month doesn't cause the
/// other card to vanish too.
struct InsightsView: View {

    @Environment(\.dismiss) private var dismiss

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore

    /// Initialised on first body evaluation by the closure default —
    /// picks "previous full month" relative to whatever `Date()` is
    /// when the sheet opens.
    @State private var period: InsightsPeriod = .previousFullMonth()

    // MARK: - Derived data

    /// Built once per render. Carries the home-transactions feed,
    /// the active target currency + FX closure, and the live
    /// category→emoji map. Cards receive this and avoid repeating
    /// the 4-arg analytics call boilerplate.
    private var analyticsContext: AnalyticsContext {
        .from(
            transactionStore: transactionStore,
            currencyStore: currencyStore,
            categoryStore: categoryStore
        )
    }

    /// Period-filtered context for cards that respect the picker
    /// (CategoryTopCard previews). The trend / extreme cards run
    /// against the unfiltered feed by design — they need months
    /// of history regardless of the user's current period choice.
    private var filteredContext: AnalyticsContext {
        analyticsContext.filtered(by: period)
    }

    private var topIncome: [CategoryAnalyticsService.CategoryTotal] {
        filteredContext.topCategories(type: .income)
    }

    private var topExpense: [CategoryAnalyticsService.CategoryTotal] {
        filteredContext.topCategories(type: .expenses)
    }

    /// Has the user ever recorded an income transaction? Drives the
    /// "earning" card's visibility — if not, the card stays hidden
    /// regardless of the period the user picks.
    private var hasAnyIncome: Bool {
        transactionStore.transactions.contains { $0.type == .income }
    }

    /// Mirror of `hasAnyIncome` for expenses.
    private var hasAnyExpense: Bool {
        transactionStore.transactions.contains { $0.type == .expenses }
    }

    private var hasBigPurchase: Bool {
        analyticsContext.biggestPurchaseInLastMonth != nil
    }

    private var hasBigCategoryMonth: Bool {
        analyticsContext.biggestCategorySumInLastMonth != nil
    }

    private var hasSmallPurchasesSavings: Bool {
        analyticsContext.smallPurchasesSavings != nil
    }

    private var hasNetBalanceTrend: Bool {
        analyticsContext.monthlyTrend(.netBalance) != nil
    }

    private var hasExpensesTrend: Bool {
        analyticsContext.monthlyTrend(.expenses) != nil
    }

    private var hasIncomeTrend: Bool {
        analyticsContext.monthlyTrend(.income) != nil
    }

    private var hasCategoryCannibalization: Bool {
        analyticsContext.categoryCannibalization != nil
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if hasAnyExpense {
                        spendingCard
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.top, AppSpacing.sm)
                    }

                    if hasAnyIncome {
                        earningCard
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    // Monthly trend cards — each surfaces a
                    // bird's-eye view of how a value series is
                    // evolving over time. Hidden independently
                    // (each trend has its own data + threshold
                    // gates inside `MonthlyTrendCard.hasData`).
                    if hasNetBalanceTrend {
                        MonthlyTrendCard(kind: .netBalance, context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    if hasExpensesTrend {
                        MonthlyTrendCard(kind: .expenses, context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    if hasIncomeTrend {
                        MonthlyTrendCard(kind: .income, context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    // Statistical extremes — narrative cards that
                    // surface a single outstanding moment. Each
                    // card has its own gate so they appear
                    // independently (a user might have a single
                    // outlier purchase but no outlier category
                    // last month, or vice versa).
                    if hasBigPurchase {
                        BigPurchaseCard(context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    if hasBigCategoryMonth {
                        BigCategoryMonthCard(context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    // Substitution / cannibalization pattern —
                    // surfaces months where one category went up
                    // and another went down by similar amounts,
                    // suggesting the user redirected spend.
                    if hasCategoryCannibalization {
                        CategoryCannibalizationCard(context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    // Small-purchases savings hint — surfaces only
                    // when the user has enough recurring small
                    // purchases (≥ 4 same-category per month, ≥ 2
                    // such months, ≥ 2 distinct categories overall)
                    // for the savings analysis to be meaningful.
                    if hasSmallPurchasesSavings {
                        SmallPurchasesCard(context: analyticsContext)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    // Calendar heatmap — same gating as the spending
                    // card (hide when the user has zero expenses
                    // ever, since the whole thing is expense-only).
                    if hasAnyExpense {
                        SpendingCalendarCard(context: analyticsContext, period: $period)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                    }

                    if !hasAnyExpense && !hasAnyIncome {
                        nothingYet
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.top, 32)
                    }

                    Spacer(minLength: 32)
                }
                .padding(.bottom, AppSpacing.xxl)
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Cards

    private var spendingCard: some View {
        CategoryTopCard(
            questionPrefix: "Where did you spend the most money in",
            categories: topExpense,
            currency: currencyStore.selectedCurrency,
            type: .expenses,
            accentColor: spendingAccent,
            period: $period
        ) {
            // Detail view recomputes its own category list against
            // the live `period` binding, so switching months from
            // the detail screen updates rows on the fly.
            InsightsDetailView(
                navTitle: "Top spending",
                questionPrefix: "Where did you spend the most money in",
                type: .expenses,
                accentColor: spendingAccent,
                period: $period
            )
        }
    }

    private var earningCard: some View {
        CategoryTopCard(
            questionPrefix: "Where did you earn the most money in",
            categories: topIncome,
            currency: currencyStore.selectedCurrency,
            type: .income,
            accentColor: earningAccent,
            period: $period
        ) {
            InsightsDetailView(
                navTitle: "Top earning",
                questionPrefix: "Where did you earn the most money in",
                type: .income,
                accentColor: earningAccent,
                period: $period
            )
        }
    }

    // MARK: - Empty (no transactions ever)

    /// Shown only when the user has zero transactions of either type
    /// in the entire ledger — there's literally nothing to analyse,
    /// so we don't render either card and instead hint at the path
    /// to creating data.
    private var nothingYet: some View {
        // Pixel growing-plant figure encodes the "your data is the
        // seed" framing — softer than a chart icon for an empty-by-
        // necessity screen.
        EmptyStateView(
            figure: .growingPlant(),
            title: "Nothing to analyse yet",
            description: "Add a transaction to start seeing insights here.",
            size: .page
        )
    }

    // MARK: - Palette

    /// Warm orange that matches the `reminderAccent` already used for
    /// "outflow / heat" cues elsewhere in the app.
    private var spendingAccent: Color {
        AppColors.reminderAccent
    }

    /// Mint green that pairs with the "money in" semantic. Using the
    /// system green keeps it dynamic across light / dark mode.
    private var earningAccent: Color {
        Color.green
    }
}

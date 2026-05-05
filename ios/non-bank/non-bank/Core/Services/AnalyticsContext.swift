import Foundation

// MARK: - AnalyticsContext
//
// A bundle of the four pieces of state every Insights analytic needs:
//
//   - `transactions`      : the raw input list (already filtered to
//                           `homeTransactions` by default — past-dated,
//                           non-recurring-parent — so analytics ignore
//                           reminders / templates).
//   - `targetCurrency`    : ISO code that all multi-currency amounts
//                           are converted into before maths.
//   - `convert`           : rate-conversion closure that performs the
//                           per-amount FX lookup. Captured from
//                           `CurrencyStore` so live rate changes flow
//                           through automatically.
//   - `emojiByCategory`   : `title → emoji` map from `CategoryStore`,
//                           so analytics surface the *current* emoji
//                           rather than the one frozen on the first
//                           matching transaction.
//
// **Why this exists**: every Insights card duplicated the same 4-prop
// boilerplate — `@EnvironmentObject` for three stores, plus a private
// `convert` closure and a private `emojiByCategory` dictionary,
// rebuilt on every render. Eleven copies of `convert`, five of
// `emojiByCategory`. `AnalyticsContext` consolidates them into a
// single value type that:
//
//   1. Is built once at the parent screen (`InsightsView`) and
//      passed down.
//   2. Exposes one-line **facades** over `CategoryAnalyticsService`
//      so callers don't repeat the 4-arg call site for every metric.
//   3. Is `Equatable` (sans the closure) so SwiftUI can short-circuit
//      re-renders when the input data hasn't changed.
//
// Migration to `AnalyticsContext` happens in DS Step 5; this file
// just makes the new pattern available.

struct AnalyticsContext {
    let transactions: [Transaction]
    let targetCurrency: String
    let convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    let emojiByCategory: [String: String]

    /// Returns a new `AnalyticsContext` with `transactions` filtered
    /// down to the given `InsightsPeriod`. The other props (currency,
    /// convert, emoji map) carry over unchanged. Use for period-aware
    /// analytics that share the same baseline FX/emoji setup —
    /// `CategoryTopCard` filters per-period without rebuilding the
    /// other plumbing.
    func filtered(by period: InsightsPeriod) -> AnalyticsContext {
        AnalyticsContext(
            transactions: period.filter(transactions),
            targetCurrency: targetCurrency,
            convert: convert,
            emojiByCategory: emojiByCategory
        )
    }
}

// MARK: - Equatable
//
// Custom because `convert` is a closure (not Equatable). We compare
// the data members instead — for two contexts built from the same
// stores at different render passes, the closures are *equivalent*
// (both close over the same `CurrencyStore` reference) but never
// `==`. Comparing data is what SwiftUI's diffing actually wants.

extension AnalyticsContext: Equatable {
    static func == (lhs: AnalyticsContext, rhs: AnalyticsContext) -> Bool {
        lhs.transactions == rhs.transactions &&
        lhs.targetCurrency == rhs.targetCurrency &&
        lhs.emojiByCategory == rhs.emojiByCategory
    }
}

// MARK: - Construction from stores

extension AnalyticsContext {
    /// Builds an `AnalyticsContext` from the standard environment
    /// stores. Intended for use inside SwiftUI views that already
    /// have all three injected.
    ///
    /// - Parameter useHomeTransactions: when `true` (default), uses
    ///   `transactionStore.homeTransactions` — past-dated, non-parent
    ///   transactions only, matching what every Insights card
    ///   currently does. Pass `false` for surfaces that need the
    ///   raw full list (debt screens, share-link encoding, ...).
    @MainActor
    static func from(
        transactionStore: TransactionStore,
        currencyStore: CurrencyStore,
        categoryStore: CategoryStore,
        useHomeTransactions: Bool = true
    ) -> AnalyticsContext {
        let txs = useHomeTransactions
            ? transactionStore.homeTransactions
            : transactionStore.transactions
        let emojiMap = Dictionary(
            uniqueKeysWithValues: categoryStore.categories.map { ($0.title, $0.emoji) }
        )
        return AnalyticsContext(
            transactions: txs,
            targetCurrency: currencyStore.selectedCurrency,
            convert: { [currencyStore] amount, from, to in
                currencyStore.convert(amount: amount, from: from, to: to)
            },
            emojiByCategory: emojiMap
        )
    }
}

// MARK: - Insights facades
//
// One-line wrappers over `CategoryAnalyticsService` that bind the 4
// standard arguments from the context. Adding a new analytic is a
// 5-line addition here; callers stay clean.

extension AnalyticsContext {

    // MARK: Top categories

    /// Top-N expense categories for the given period (or all
    /// transactions if no period filter has been applied to the
    /// context). Sorted by descending total.
    func topCategories(type: TransactionType) -> [CategoryAnalyticsService.CategoryTotal] {
        CategoryAnalyticsService.topCategories(
            transactions: transactions,
            type: type,
            targetCurrency: targetCurrency,
            convert: convert,
            emojiByCategory: emojiByCategory
        )
    }

    // MARK: Single-purchase / single-month extremes

    /// The single most-outstanding purchase in the previous
    /// fully-completed month, by per-category z-score.
    /// `nil` when no transaction qualifies.
    var biggestPurchaseInLastMonth: CategoryAnalyticsService.BigPurchase? {
        CategoryAnalyticsService.biggestPurchaseInLastMonth(
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert,
            emojiByCategory: emojiByCategory
        )
    }

    /// The single category whose previous-full-month total most
    /// exceeded its prior-months baseline. `nil` when no category
    /// qualifies.
    var biggestCategorySumInLastMonth: CategoryAnalyticsService.BigCategoryMonth? {
        CategoryAnalyticsService.biggestCategorySumInLastMonth(
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert,
            emojiByCategory: emojiByCategory
        )
    }

    // MARK: Patterns

    /// Habit-driven savings opportunity: small recurring purchases
    /// that add up to a meaningful monthly bleed. `nil` when the
    /// activity floor / category-variety gates fail.
    var smallPurchasesSavings: CategoryAnalyticsService.SmallPurchasesSavings? {
        CategoryAnalyticsService.smallPurchasesSavings(
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert,
            emojiByCategory: emojiByCategory
        )
    }

    /// Substitution / cannibalization pattern — one category up,
    /// another down by similar magnitude in the same month. `nil`
    /// when no pair across the recent window qualifies.
    var categoryCannibalization: CategoryAnalyticsService.CategoryCannibalization? {
        CategoryAnalyticsService.categoryCannibalization(
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert,
            emojiByCategory: emojiByCategory
        )
    }

    // MARK: Trends

    /// Linear-regression-based monthly trend (signed % per month)
    /// for the chosen value series. `nil` when the trend is too
    /// small to surface or the user lacks enough months of data.
    /// `convert` is bound but `emojiByCategory` isn't used here —
    /// trends operate on aggregate sums, not per-category.
    func monthlyTrend(_ kind: CategoryAnalyticsService.TrendKind) -> CategoryAnalyticsService.MonthlyTrend? {
        CategoryAnalyticsService.monthlyTrend(
            kind: kind,
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert
        )
    }

    // MARK: Calendar / heatmap

    /// Per-day expense aggregates for the given calendar month. One
    /// entry per day, zero-filled where the user spent nothing —
    /// the calendar grid renders evenly without holes.
    func dailyExpenses(in monthDate: Date) -> [CategoryAnalyticsService.DailyExpense] {
        CategoryAnalyticsService.dailyExpenses(
            in: monthDate,
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert
        )
    }

    /// Average expense per day-of-month (1…31) across the user's
    /// full expense history. Days 29-31 use only months that
    /// calendrically have those days as the denominator.
    var averageDailyByDayOfMonth: [CategoryAnalyticsService.DayOfMonthAverage] {
        CategoryAnalyticsService.averageDailyByDayOfMonth(
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert
        )
    }

    /// All-time max single-day expense total. Anchors the heatmap
    /// colour scale so cell intensity is comparable across months.
    var maxDailyExpenseEver: Double {
        CategoryAnalyticsService.maxDailyExpenseEver(
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert
        )
    }

    // MARK: Per-category history

    /// Per-month aggregate for a specific category — drives the
    /// `CategoryHistoryView` chart + list. See
    /// `CategoryAnalyticsService.monthlyHistory` for the
    /// `monthCount` / `skipCurrentMonth` semantics.
    func monthlyHistory(
        for categoryTitle: String,
        type: TransactionType,
        monthCount: Int = 12,
        skipCurrentMonth: Bool = true
    ) -> [CategoryAnalyticsService.MonthlyTotal] {
        CategoryAnalyticsService.monthlyHistory(
            for: categoryTitle,
            type: type,
            transactions: transactions,
            targetCurrency: targetCurrency,
            convert: convert,
            monthCount: monthCount,
            skipCurrentMonth: skipCurrentMonth
        )
    }
}

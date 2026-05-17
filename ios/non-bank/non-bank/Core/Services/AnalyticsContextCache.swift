import Combine
import Foundation

// MARK: - AnalyticsContextCache
//
// Memoises `AnalyticsContext.from(...)` for a single host view. Built
// because `InsightsView`'s body reads `analyticsContext` ~14 times per
// pass (every card-visibility gate calls into it: `hasAnyExpense`,
// `hasBigPurchase`, `hasNetBalanceTrend`, ...), and `from(...)` runs
// `normaliseForInsights` over every transaction plus rebuilds the
// emoji map each time. At 500 transactions that was hundreds of
// alloc + filter operations per render pass; on a sheet-open + period
// nav this was a measurable ~100ms hit.
//
// The cache invalidates only when one of the four inputs changes:
//   - `transactionStore.version` bumps on every add/edit/delete
//   - `categoryStore.categories` array (emoji map depends on it)
//   - `currencyStore.selectedCurrency` (target FX currency)
//   - `InsightsSettings.includePotentialExpenses` (toggles split-aware
//      amount substitution in `normaliseForInsights`)
//
// Why an `ObservableObject` (rather than plain `@State`): SwiftUI
// can hold reference types via `@StateObject`, which keeps the cache
// alive across renders without triggering re-renders on mutations
// (this cache has no `@Published`). `@State` with a reference type
// is officially discouraged and doesn't survive certain identity
// changes; `@StateObject` is the right tool.
@MainActor
final class AnalyticsContextCache: ObservableObject {

    struct Identity: Equatable {
        let txVersion: UInt64
        let categories: [Category]
        let currency: String
        let includePotential: Bool
    }

    private var cached: AnalyticsContext?
    private var lastIdentity: Identity?

    /// Returns the memoised context. Recomputes only when the four
    /// inputs that `AnalyticsContext.from(...)` reads have changed.
    func context(
        transactionStore: TransactionStore,
        currencyStore: CurrencyStore,
        categoryStore: CategoryStore,
        insightsSettings: InsightsSettings
    ) -> AnalyticsContext {
        let id = Identity(
            txVersion: transactionStore.version,
            categories: categoryStore.categories,
            currency: currencyStore.selectedCurrency,
            includePotential: insightsSettings.includePotentialExpenses
        )
        if id == lastIdentity, let cached {
            return cached
        }
        let fresh = AnalyticsContext.from(
            transactionStore: transactionStore,
            currencyStore: currencyStore,
            categoryStore: categoryStore
        )
        cached = fresh
        lastIdentity = id
        return fresh
    }
}

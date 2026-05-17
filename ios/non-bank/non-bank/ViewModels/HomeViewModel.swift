import Foundation
import Combine

// MARK: - Quick Filter

enum QuickFilter: Equatable, Hashable {
    case category(String)
    var label: String {
        switch self {
        case .category(let name): return name
        }
    }
}

// MARK: - HomeViewModel

@MainActor
class HomeViewModel: ObservableObject {

    // MARK: - Filter State

    @Published var dateFilter: DateFilterType = .all
    @Published var activeDateFilter: DateFilterType = .all
    @Published var searchText: String = ""
    @Published var activeCategories: Set<String> = []
    @Published var activeTypes: Set<TransactionType> = []

    // Filter sheet mirror (synced on open/dismiss)
    @Published var filterSheetCategories: Set<String> = []
    @Published var filterSheetTypes: Set<TransactionType> = []

    // Quick filter caches
    @Published private(set) var cachedTopCategories: [String] = []

    // Trend
    let trendBarsCount = AppSizes.trendBarsCount
    @Published var hoveredBarIdx: Int? = nil

    // MARK: - Async filter pipeline
    //
    // `filtered` / `grouped` are the **cached** output of the filter
    // chain, computed off the main actor by `recomputeFiltered`. Body
    // reads these instead of running the synchronous filter inline so
    // typing in the search bar doesn't block the main thread on each
    // keystroke. Phase-7 hoist removed the within-body redundant
    // computations; this layer removes the per-keystroke 40 ms cost
    // measured on 10k-transaction stores.
    //
    // The legacy synchronous `filteredTransactions(from:resolveCategory:)`
    // method stays defined for the rare path that needs an inline
    // result (debug paths, future test fixtures); HomeView uses the
    // cached form exclusively.
    @Published private(set) var filtered: [Transaction] = []
    @Published private(set) var grouped: [(date: Date, transactions: [Transaction])] = []
    /// `true` after the first `recomputeFiltered` completes. The view
    /// suppresses the "No transactions match the selected filters"
    /// empty-state until this flips — otherwise the first body eval
    /// (cache empty, store non-empty, filter still in flight) would
    /// flash the wrong message.
    @Published private(set) var hasInitialFilter: Bool = false

    /// Handle for the in-flight filter pass. Cancelled when a new
    /// trigger arrives so rapid input (typing in search) coalesces:
    /// the previous task's `Task.sleep` debounce returns
    /// `CancellationError`, the new task is the only one that lands
    /// a result.
    private var filterTask: Task<Void, Never>?

    // MARK: - Computed

    var hasActiveFilters: Bool {
        !activeCategories.isEmpty || !activeTypes.isEmpty
    }

    // MARK: - Filtering

    func filteredTransactions(
        from allTransactions: [Transaction],
        resolveCategory: @escaping (Transaction) -> String
    ) -> [Transaction] {
        // Defensive double-filter: callers should already be passing
        // `transactionStore.homeTransactions` (past + non-parent), but
        // we re-apply the future cut here so any future-dated row that
        // slips through an import / sync / share path can't surface on
        // Home — it stays out of sight until its `date` becomes the
        // present, at which point the same filter lets it through.
        let now = Date()
        let pastOnly = allTransactions.filter { $0.date <= now }
        let dateFiltered = TransactionFilterService.filterByDate(
            transactions: pastOnly, filter: activeDateFilter
        )
        let criteria = TransactionFilterService.FilterCriteria(
            searchText: searchText,
            categories: activeCategories,
            types: activeTypes,
            resolveCategory: resolveCategory
        )
        return TransactionFilterService.apply(criteria: criteria, to: dateFiltered)
    }

    func groupedTransactions(
        from filtered: [Transaction]
    ) -> [(date: Date, transactions: [Transaction])] {
        TransactionFilterService.groupByDay(filtered)
    }

    // MARK: - Balance & Trends

    func filteredBalanceTransactions(from allTransactions: [Transaction]) -> [Transaction] {
        TransactionFilterService.filterByDate(transactions: allTransactions, filter: dateFilter)
    }

    func balanceForPeriod(
        allTransactions: [Transaction],
        currency: String,
        convert: @escaping (Double, String, String) -> Double
    ) -> Double {
        let filtered = filteredBalanceTransactions(from: allTransactions)
        return TransactionFilterService.balance(
            transactions: filtered, targetCurrency: currency, convert: convert
        )
    }

    func trendBars(
        allTransactions: [Transaction],
        currency: String,
        convert: @escaping (Double, String, String) -> Double
    ) -> [TrendBarPoint] {
        let filtered = filteredBalanceTransactions(from: allTransactions)
        return TransactionFilterService.calculateTrendBars(
            transactions: filtered,
            count: trendBarsCount,
            filter: dateFilter,
            targetCurrency: currency,
            convert: convert
        )
    }

    // MARK: - Quick Filters

    func refreshQuickFilters(
        allTransactions: [Transaction],
        resolveCategory: @escaping (Transaction) -> String
    ) {
        let dateFiltered = TransactionFilterService.filterByDate(
            transactions: allTransactions, filter: activeDateFilter
        )
        cachedTopCategories = TransactionFilterService.topCategories(
            from: dateFiltered, resolveCategory: resolveCategory
        )
    }

    func toggleQuickFilter(_ filter: QuickFilter) {
        switch filter {
        case .category(let cat):
            if activeCategories.contains(cat) {
                activeCategories.remove(cat)
            } else {
                activeCategories.insert(cat)
            }
        }
    }

    func isQuickFilterActive(_ filter: QuickFilter) -> Bool {
        switch filter {
        case .category(let cat): return activeCategories.contains(cat)
        }
    }

    // MARK: - Filter Sheet

    func prepareFilterSheet() {
        filterSheetCategories = activeCategories
        filterSheetTypes = activeTypes
    }

    func applyFilterSheet() {
        activeCategories = filterSheetCategories
        activeTypes = filterSheetTypes
    }

    func clearAllFilters() {
        activeCategories.removeAll()
        activeTypes.removeAll()
    }

    // MARK: - Category Helpers

    func validatedCategory(for tx: Transaction, in categories: [Category]) -> String {
        (categories.first(where: { $0.title == tx.category }) ?? CategoryStore.uncategorized).title
    }

    func validatedEmoji(for tx: Transaction, in categories: [Category]) -> String {
        (categories.first(where: { $0.title == tx.category }) ?? CategoryStore.uncategorized).emoji
    }

    func getEmoji(for category: String, in categories: [Category], transactions: [Transaction]) -> String? {
        categories.first(where: { $0.title == category })?.emoji
            ?? transactions.first(where: { $0.category == category })?.emoji
    }

    // MARK: - Debt Summary

    func debtSummary(
        allTransactions: [Transaction],
        currency: String,
        convert: @escaping (Double, String, String) -> Double
    ) -> DebtSummary {
        let home = ReminderService.homeTransactions(from: allTransactions)
        return SplitDebtService.calculateDebt(
            transactions: home,
            targetCurrency: currency,
            convert: convert
        )
    }

    // MARK: - Reminders

    func reminderCount(from allTransactions: [Transaction]) -> Int {
        ReminderService.reminders(from: allTransactions).count
    }

    // MARK: - Async filter pipeline impl

    /// Trigger an off-main filter + group pass and publish the result
    /// back to `filtered` / `grouped` when it completes. Cancels any
    /// in-flight pass — the cancellation lets keystroke-driven calls
    /// coalesce: the new call's 100 ms `Task.sleep` debounce runs
    /// while the previous task's `Task.sleep` throws `CancellationError`,
    /// so only the most recent input ever runs the actual filter.
    ///
    /// The first call (when `hasInitialFilter == false`) skips the
    /// debounce so the view doesn't flash an empty list on appear.
    ///
    /// `categoryTitles` is a pre-resolved snapshot of
    /// `CategoryStore.categories.map(\.title)`. Built on the main
    /// actor BEFORE the detached task fires so the off-main filter
    /// never reaches into the `@MainActor`-isolated `CategoryStore`.
    func recomputeFiltered(
        allTransactions: [Transaction],
        categoryTitles: Set<String>,
        uncategorizedTitle: String
    ) {
        filterTask?.cancel()
        let skipDebounce = !hasInitialFilter
        let activeDateFilter = self.activeDateFilter
        let searchText = self.searchText
        let activeCategories = self.activeCategories
        let activeTypes = self.activeTypes
        filterTask = Task.detached(priority: .userInitiated) { [weak self] in
            if !skipDebounce {
                try? await Task.sleep(for: .milliseconds(100))
                if Task.isCancelled { return }
            }
            let result = Self.computeFilteredAndGrouped(
                allTransactions: allTransactions,
                activeDateFilter: activeDateFilter,
                searchText: searchText,
                activeCategories: activeCategories,
                activeTypes: activeTypes,
                categoryTitles: categoryTitles,
                uncategorizedTitle: uncategorizedTitle
            )
            if Task.isCancelled { return }
            await MainActor.run {
                guard let self else { return }
                self.filtered = result.filtered
                self.grouped = result.grouped
                self.hasInitialFilter = true
            }
        }
    }

    /// Pure value-type filter chain — `nonisolated` so it's callable
    /// from `Task.detached`. Captures nothing from `self`; every input
    /// is passed explicitly. Mirror of the synchronous
    /// `filteredTransactions(...)` + `groupedTransactions(...)` pair
    /// above, refactored to take `categoryTitles` instead of a
    /// `resolveCategory` closure (closures capturing the
    /// `@MainActor`-isolated `CategoryStore` can't cross the actor
    /// boundary into the detached task).
    nonisolated private static func computeFilteredAndGrouped(
        allTransactions: [Transaction],
        activeDateFilter: DateFilterType,
        searchText: String,
        activeCategories: Set<String>,
        activeTypes: Set<TransactionType>,
        categoryTitles: Set<String>,
        uncategorizedTitle: String
    ) -> (filtered: [Transaction], grouped: [(date: Date, transactions: [Transaction])]) {
        let now = Date()
        let pastOnly = allTransactions.filter { $0.date <= now }
        let dateFiltered = TransactionFilterService.filterByDate(
            transactions: pastOnly, filter: activeDateFilter
        )
        // Re-implementation of `CategoryStore.validatedCategory(for:).title`
        // that operates on the snapshot set — no `@MainActor` reach.
        let resolveCategory: (Transaction) -> String = { tx in
            categoryTitles.contains(tx.category) ? tx.category : uncategorizedTitle
        }
        let criteria = TransactionFilterService.FilterCriteria(
            searchText: searchText,
            categories: activeCategories,
            types: activeTypes,
            resolveCategory: resolveCategory
        )
        let filtered = TransactionFilterService.apply(criteria: criteria, to: dateFiltered)
        let grouped = TransactionFilterService.groupByDay(filtered)
        return (filtered, grouped)
    }
}

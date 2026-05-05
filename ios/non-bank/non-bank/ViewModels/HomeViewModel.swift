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

    // MARK: - Computed

    var hasActiveFilters: Bool {
        !activeCategories.isEmpty || !activeTypes.isEmpty
    }

    // MARK: - Filtering

    func filteredTransactions(
        from allTransactions: [Transaction],
        resolveCategory: @escaping (Transaction) -> String
    ) -> [Transaction] {
        let dateFiltered = TransactionFilterService.filterByDate(
            transactions: allTransactions, filter: activeDateFilter
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

    // MARK: - Formatting

    func formattedSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = isCurrentYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return formatter.string(from: date).uppercased()
    }
}

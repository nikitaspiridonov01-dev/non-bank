import Foundation
import SwiftUI

/// Pure business logic for filtering, grouping, and computing trends.
/// No UI dependencies — can be unit-tested independently.
enum TransactionFilterService {

    // MARK: - Date Filtering

    static func filterByDate(
        transactions: [Transaction],
        filter: DateFilterType,
        now: Date = Date()
    ) -> [Transaction] {
        let calendar = Calendar.current
        switch filter {
        case .all:
            return transactions
        case .today:
            return transactions.filter { calendar.isDateInToday($0.date) }
        case .week:
            if let weekAgo = calendar.date(byAdding: .day, value: -7, to: now) {
                return transactions.filter { $0.date >= weekAgo && $0.date <= now }
            }
            return transactions
        case .month:
            return transactions.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .month) }
        case .year:
            return transactions.filter { calendar.isDate($0.date, equalTo: now, toGranularity: .year) }
        }
    }

    // MARK: - Multi-criteria Filtering

    struct FilterCriteria {
        var searchText: String = ""
        var categories: Set<String> = []
        var types: Set<TransactionType> = []

        /// Resolves category title for a transaction. Caller provides the closure
        /// so this service doesn't depend on CategoryStore.
        var resolveCategory: (Transaction) -> String = { $0.category }
    }

    static func apply(
        criteria: FilterCriteria,
        to transactions: [Transaction]
    ) -> [Transaction] {
        transactions.filter { tx in
            let matchesSearch = criteria.searchText.isEmpty
                || tx.title.localizedCaseInsensitiveContains(criteria.searchText)
                || (tx.description ?? "").localizedCaseInsensitiveContains(criteria.searchText)
            let matchesCategory = criteria.categories.isEmpty
                || criteria.categories.contains(criteria.resolveCategory(tx))
            let matchesType = criteria.types.isEmpty
                || criteria.types.contains(tx.type)
            return matchesSearch && matchesCategory && matchesType
        }
    }

    // MARK: - Grouping by Day

    static func groupByDay(
        _ transactions: [Transaction]
    ) -> [(date: Date, transactions: [Transaction])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: transactions) { tx in
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            return calendar.date(from: comps) ?? tx.date
        }
        return grouped.keys.sorted(by: >).map { date in
            (date, grouped[date]!.sorted { $0.date > $1.date })
        }
    }

    // MARK: - Balance Calculation

    /// Computes net balance for a set of transactions, converting to a target currency.
    static func balance(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> Double {
        transactions.reduce(0) { sum, tx in
            let converted = convert(tx.amount, tx.currency, targetCurrency)
            return sum + (tx.isIncome ? converted : -converted)
        }
    }

    /// Computes balance only from home-eligible transactions (excludes future + recurring parents).
    static func homeBalance(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        now: Date = Date()
    ) -> Double {
        let homeOnly = ReminderService.homeTransactions(from: transactions, now: now)
        return balance(transactions: homeOnly, targetCurrency: targetCurrency, convert: convert)
    }

    // MARK: - Trend Bars

    static func calculateTrendBars(
        transactions: [Transaction],
        count: Int,
        filter: DateFilterType,
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> [TrendBarPoint] {
        let isDateOnly = (filter == .all || filter == .year)
        let calendar = Calendar.current
        let now = Date()

        let converted = transactions.map { tx -> (date: Date, signedAmount: Double) in
            let amountInTarget = convert(tx.amount, tx.currency, targetCurrency)
            return (tx.date, tx.isIncome ? amountInTarget : -amountInTarget)
        }.sorted { $0.date < $1.date }

        var startMs: TimeInterval
        var endMs: TimeInterval

        if let first = converted.first, let last = converted.last {
            if isDateOnly {
                startMs = calendar.startOfDay(for: first.date).timeIntervalSince1970
                endMs = calendar.startOfDay(for: last.date).timeIntervalSince1970
            } else {
                startMs = first.date.timeIntervalSince1970
                endMs = last.date.timeIntervalSince1970
            }
        } else {
            (startMs, endMs) = emptyDateRange(filter: filter, calendar: calendar, now: now)
        }

        let stepMs = count > 1 ? (endMs - startMs) / Double(count - 1) : 0
        var filledPoints: [(label: String, balance: Double)] = []
        var runningBalance: Double = 0
        var entryIdx = 0

        for i in 0..<count {
            let pointMs = startMs + (stepMs * Double(i))
            let pointDate = Date(timeIntervalSince1970: pointMs)

            let lookupMs: TimeInterval
            if isDateOnly {
                lookupMs = (calendar.date(bySettingHour: 23, minute: 59, second: 59, of: pointDate) ?? pointDate).timeIntervalSince1970
            } else {
                lookupMs = pointMs
            }

            while entryIdx < converted.count && converted[entryIdx].date.timeIntervalSince1970 <= lookupMs {
                runningBalance += converted[entryIdx].signedAmount
                entryIdx += 1
            }

            filledPoints.append((
                label: formatTrendLabel(pointDate, filter: filter),
                balance: runningBalance
            ))
        }

        let values = filledPoints.map { $0.balance }
        let minBal = values.min() ?? 0
        let maxBal = values.max() ?? 0
        let range = maxBal - minBal

        return filledPoints.map { point in
            let height: CGFloat
            if range == 0 {
                height = 12
            } else {
                let norm = (point.balance - minBal) / range
                height = 6 + CGFloat(norm) * 58
            }
            return TrendBarPoint(height: height, balance: point.balance, label: point.label)
        }
    }

    // MARK: - Top Categories / Tags (Quick Filters)

    static func topCategories(
        from transactions: [Transaction],
        resolveCategory: (Transaction) -> String,
        limit: Int = 2
    ) -> [String] {
        var stats: [String: (count: Int, lastDate: Date)] = [:]
        for tx in transactions {
            let cat = resolveCategory(tx)
            if let prev = stats[cat] {
                stats[cat] = (prev.count + 1, max(prev.lastDate, tx.date))
            } else {
                stats[cat] = (1, tx.date)
            }
        }
        return stats.sorted {
            if $0.value.count != $1.value.count { return $0.value.count > $1.value.count }
            return $0.value.lastDate > $1.value.lastDate
        }.prefix(limit).map { $0.key }
    }

    // MARK: - Private Helpers

    private static func emptyDateRange(
        filter: DateFilterType,
        calendar: Calendar,
        now: Date
    ) -> (start: TimeInterval, end: TimeInterval) {
        switch filter {
        case .today:
            let s = calendar.startOfDay(for: now).timeIntervalSince1970
            let e = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now)?.timeIntervalSince1970 ?? now.timeIntervalSince1970
            return (s, e)
        case .week:
            let startOfDay = calendar.startOfDay(for: now)
            let weekAgo = calendar.date(byAdding: .day, value: -7, to: startOfDay) ?? startOfDay
            let e = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now)?.timeIntervalSince1970 ?? now.timeIntervalSince1970
            return (weekAgo.timeIntervalSince1970, e)
        case .month:
            let comps = calendar.dateComponents([.year, .month], from: now)
            let startOfMonth = calendar.date(from: comps) ?? now
            let endOfMonth = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: startOfMonth) ?? now
            let e = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endOfMonth)?.timeIntervalSince1970 ?? now.timeIntervalSince1970
            return (startOfMonth.timeIntervalSince1970, e)
        case .year:
            let comps = calendar.dateComponents([.year], from: now)
            let startOfYear = calendar.date(from: comps) ?? now
            let endOfYear = calendar.date(byAdding: DateComponents(year: 1, day: -1), to: startOfYear) ?? now
            let e = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: endOfYear)?.timeIntervalSince1970 ?? now.timeIntervalSince1970
            return (startOfYear.timeIntervalSince1970, e)
        case .all:
            let endOfDay = calendar.date(bySettingHour: 23, minute: 59, second: 59, of: now) ?? now
            let start = calendar.date(byAdding: .day, value: -43, to: endOfDay) ?? endOfDay
            return (calendar.startOfDay(for: start).timeIntervalSince1970, endOfDay.timeIntervalSince1970)
        }
    }

    private static func formatTrendLabel(_ date: Date, filter: DateFilterType) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        if filter == .all || filter == .year {
            formatter.dateFormat = "EEE, MMM d, yyyy"
        } else {
            formatter.dateFormat = "EEE, MMM d, yyyy, hh:mm a"
        }
        return formatter.string(from: date)
    }
}

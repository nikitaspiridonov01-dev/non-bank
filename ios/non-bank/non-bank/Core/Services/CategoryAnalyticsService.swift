import Foundation

// MARK: - Time period for the Insights screen

/// Time window the Insights screen aggregates over. Independent from
/// `DateFilterType` (the Home period filter) so picking "last 6
/// months" of analytics doesn't disturb the period the user had
/// selected on Home.
///
/// Two flavours:
///  - `.month(year:month:)` — a specific calendar month. The default
///    when the screen opens is the *previous* fully-completed month
///    (so on April 17 → "March 2026"); users navigate to other months
///    via the headline's tap-to-pick menu.
///  - Rolling ranges (`.last3Months`, `.last6Months`, `.lastYear`,
///    `.allTime`) — for users who want a multi-month view rather
///    than a specific month. These are *rolling* (last N months
///    counting back from `now`), not calendar-aligned.
enum InsightsPeriod: Equatable, Hashable {
    case month(year: Int, month: Int)
    case last3Months
    case last6Months
    case lastYear
    case allTime
    /// User-defined inclusive date range. `from`/`to` are stored at
    /// arbitrary times-of-day (whatever the date picker emitted);
    /// `filter(_:)` normalises the bounds to start-of-day on `from`
    /// and end-of-day on `to` so the user's intent ("the whole 1st
    /// through the whole 15th") matches what gets included.
    case customRange(from: Date, to: Date)

    /// Returns the most recent fully-completed calendar month. Used as
    /// the default selection when the Insights sheet first appears —
    /// users overwhelmingly want to look at "last month" first, and
    /// "previous full month" sidesteps the awkward "we're 3 days into
    /// April so April only has 3 days of data" problem that a rolling
    /// 30-day window has.
    static func previousFullMonth(now: Date = Date()) -> InsightsPeriod {
        let calendar = Calendar.current
        let prev = calendar.date(byAdding: .month, value: -1, to: now) ?? now
        let comps = calendar.dateComponents([.year, .month], from: prev)
        return .month(
            year: comps.year ?? calendar.component(.year, from: now),
            month: comps.month ?? calendar.component(.month, from: now)
        )
    }

    /// Filter a transaction list down to this period.
    /// `now` is parameterized for tests; production callers use `Date()`.
    func filter(_ transactions: [Transaction], now: Date = Date()) -> [Transaction] {
        let calendar = Calendar.current
        switch self {
        case .month(let year, let month):
            return transactions.filter { tx in
                let comps = calendar.dateComponents([.year, .month], from: tx.date)
                return comps.year == year && comps.month == month
            }
        case .last3Months:
            return rolling(months: 3, transactions: transactions, now: now, calendar: calendar)
        case .last6Months:
            return rolling(months: 6, transactions: transactions, now: now, calendar: calendar)
        case .lastYear:
            return rolling(months: 12, transactions: transactions, now: now, calendar: calendar)
        case .allTime:
            return transactions
        case .customRange(let from, let to):
            // Normalise the picked dates: anything from 00:00 of
            // `from` up to 23:59:59 of `to`, regardless of the time
            // component the picker happened to emit.
            let start = calendar.startOfDay(for: from)
            let end = calendar.date(
                bySettingHour: 23, minute: 59, second: 59,
                of: to
            ) ?? to
            // Tolerate inverted ranges (user accidentally picked
            // `to` before `from`) by swapping rather than throwing —
            // it's an analytics screen, not a wire-protocol input.
            let lo = min(start, end)
            let hi = max(start, end)
            return transactions.filter { $0.date >= lo && $0.date <= hi }
        }
    }

    private func rolling(
        months: Int,
        transactions: [Transaction],
        now: Date,
        calendar: Calendar
    ) -> [Transaction] {
        guard let start = calendar.date(byAdding: .month, value: -months, to: now) else {
            return transactions
        }
        return transactions.filter { $0.date >= start && $0.date <= now }
    }

    /// Inline phrase rendered inside the card's headline question
    /// ("Where did you spend the most money in **<headline>**?").
    /// Months drop the year when it matches the current year so the
    /// label stays short for the common case.
    func headline(now: Date = Date()) -> String {
        switch self {
        case .month(let year, let month):
            let comps = DateComponents(year: year, month: month, day: 1)
            let date = Calendar.current.date(from: comps) ?? now
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            let currentYear = Calendar.current.component(.year, from: now)
            formatter.dateFormat = (year == currentYear) ? "LLLL" : "LLLL yyyy"
            return formatter.string(from: date)
        case .last3Months: return "the last 3 months"
        case .last6Months: return "the last 6 months"
        case .lastYear: return "the last year"
        case .allTime: return "all time"
        case .customRange(let from, let to):
            return Self.formatRange(from: from, to: to, prefix: "")
        }
    }

    /// Compact "Mar 1 – Mar 28" / "Mar 1, 2025 – Apr 2, 2026"
    /// formatter shared by `headline` and `menuLabel`. Year is
    /// omitted only when *both* dates are in the current year, so a
    /// range that straddles a year boundary stays unambiguous.
    private static func formatRange(from: Date, to: Date, prefix: String) -> String {
        let calendar = Calendar.current
        let nowYear = calendar.component(.year, from: Date())
        let fromYear = calendar.component(.year, from: from)
        let toYear = calendar.component(.year, from: to)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = (fromYear == nowYear && toYear == nowYear)
            ? "MMM d"
            : "MMM d, yyyy"
        let f = formatter.string(from: from)
        let t = formatter.string(from: to)
        return prefix.isEmpty ? "\(f) – \(t)" : "\(prefix)\(f) – \(t)"
    }

    /// Short label for menu rows — same as `headline` but always
    /// includes the year for `.month` (no ambiguity in a long list of
    /// months that crosses a year boundary).
    var menuLabel: String {
        switch self {
        case .month(let year, let month):
            let comps = DateComponents(year: year, month: month, day: 1)
            let date = Calendar.current.date(from: comps) ?? Date()
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US")
            formatter.dateFormat = "LLLL yyyy"
            return formatter.string(from: date)
        case .last3Months: return "Last 3 months"
        case .last6Months: return "Last 6 months"
        case .lastYear: return "Last year"
        case .allTime: return "All time"
        case .customRange(let from, let to):
            return Self.formatRange(from: from, to: to, prefix: "")
        }
    }

    /// The previous N calendar months as `.month` cases (most-recent
    /// first). Used by the headline menu so the user can jump back
    /// up to two years.
    static func recentMonths(count: Int = 24, now: Date = Date()) -> [InsightsPeriod] {
        let calendar = Calendar.current
        var result: [InsightsPeriod] = []
        // offset = 1 → previous month; matches the default selection
        // so the menu shows the current default at the top.
        for offset in 1...count {
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: date)
            if let year = comps.year, let month = comps.month {
                result.append(.month(year: year, month: month))
            }
        }
        return result
    }
}

// MARK: - Category Analytics

/// Pure logic for the Insights screen's category breakdowns. Groups
/// transactions of a chosen `TransactionType` by their `category`
/// title, sums their amounts (after currency conversion), and returns
/// a list ordered by total descending.
///
/// Kept as a free `enum` (no UI deps) so it's straightforward to unit
/// test the same way `TransactionFilterService` is.
enum CategoryAnalyticsService {

    /// One row in the per-category breakdown.
    struct CategoryTotal: Identifiable, Equatable {
        /// `id` = category title — used both for `Identifiable` and as
        /// the grouping key. Two transactions with category "Food"
        /// always collapse to one row, regardless of casing
        /// differences in the underlying records (we don't normalise
        /// case here; the caller's data is expected to already be
        /// canonicalised by `CategoryStore.validatedCategory`).
        let id: String
        let category: String
        let emoji: String
        let total: Double
        let count: Int
        /// 0…1 — fraction of the *grand total*. Used by the bar
        /// visualization in `CategoryTopCard`. The top row will
        /// always have the largest share but it isn't 1.0 unless there
        /// is exactly one category in the result.
        let share: Double
    }

    /// Aggregate `transactions` of a specific type by category.
    ///
    /// - Parameters:
    ///   - transactions: input list (typically already date-filtered).
    ///   - type: `.income` for "earning categories", `.expenses` for
    ///     "spending categories". Other types are filtered out.
    ///   - targetCurrency: ISO code we convert every transaction's
    ///     `amount` into before summing — so totals across mixed
    ///     currencies are comparable.
    ///   - convert: rate-conversion closure (matches the signature
    ///     used by `TransactionFilterService.balance`).
    ///   - emojiByCategory: optional override map (`title → emoji`)
    ///     for cases where the receiver wants the **current** emoji
    ///     from `CategoryStore` rather than whatever the transaction
    ///     was created with. Falls back to `tx.emoji` for categories
    ///     not in the map (so deleted-category transactions still
    ///     render with *some* glyph).
    static func topCategories(
        transactions: [Transaction],
        type: TransactionType,
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        emojiByCategory: [String: String] = [:]
    ) -> [CategoryTotal] {
        // Single pass: accumulate sum + count + a representative emoji
        // per category. We pick the emoji from the **first** matching
        // transaction; if `emojiByCategory` has a value for the
        // category later (the "live" CategoryStore emoji), that wins
        // when we build the final row.
        var sums: [String: (sum: Double, count: Int, fallbackEmoji: String)] = [:]
        for tx in transactions where tx.type == type {
            let amountInTarget = convert(tx.amount, tx.currency, targetCurrency)
            if let existing = sums[tx.category] {
                sums[tx.category] = (
                    existing.sum + amountInTarget,
                    existing.count + 1,
                    existing.fallbackEmoji
                )
            } else {
                sums[tx.category] = (amountInTarget, 1, tx.emoji)
            }
        }

        let grandTotal = sums.values.reduce(0) { $0 + $1.sum }
        let rows = sums.map { (key, value) -> CategoryTotal in
            let emoji = emojiByCategory[key] ?? value.fallbackEmoji
            return CategoryTotal(
                id: key,
                category: key,
                emoji: emoji,
                total: value.sum,
                count: value.count,
                share: grandTotal > 0 ? value.sum / grandTotal : 0
            )
        }
        return rows.sorted { lhs, rhs in
            // Primary: descending total. Tie-breaker: descending count
            // (more transactions feels more "real"), then alpha so the
            // order is stable across launches.
            if lhs.total != rhs.total { return lhs.total > rhs.total }
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return lhs.category < rhs.category
        }
    }

    /// Sum of every row's `total`. Convenience helper for the card
    /// subtitle ("12 345.50 USD across 5 categories").
    static func grandTotal(_ rows: [CategoryTotal]) -> Double {
        rows.reduce(0) { $0 + $1.total }
    }

    // MARK: - Per-category monthly history

    /// One bucket in the per-category monthly breakdown — used by
    /// the `CategoryHistoryView` chart + list. We pre-compute the
    /// canonical first-of-month `Date` so SwiftUI Charts can use it
    /// directly as an `x` axis value (`.value("Month", item.date,
    /// unit: .month)`).
    struct MonthlyTotal: Identifiable, Equatable {
        /// `id` = "yyyy-MM" — stable across re-renders, sortable as
        /// a string, and matches the bucket key we accumulate into.
        let id: String
        let year: Int
        let month: Int
        /// Sum of converted amounts for this category in this month.
        /// Zero for months that had no matching transaction (we still
        /// emit a `MonthlyTotal` so the chart renders an empty slot).
        let total: Double
        /// Number of transactions that contributed to `total`.
        let count: Int

        /// First-of-month date in the system calendar. Used as the
        /// chart's x-axis value (`.value(_:, _, unit: .month)`).
        var date: Date {
            Calendar.current.date(
                from: DateComponents(year: year, month: month, day: 1)
            ) ?? Date()
        }

        /// Long label for list rows: "March 2026".
        var fullLabel: String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "LLLL yyyy"
            return f.string(from: date)
        }
    }

    /// Build the per-month aggregate for one category. Every month
    /// in the requested window appears in the result — months with
    /// no matching transactions show `total = 0, count = 0` so the
    /// chart's x-axis stays evenly spaced.
    ///
    /// - Parameters:
    ///   - categoryTitle: matched **case-sensitively** against
    ///     `tx.category`. Caller is expected to pass the canonical
    ///     title already (typically taken from the
    ///     `CategoryAnalyticsService.CategoryTotal` row the user
    ///     tapped on, which already uses the canonical title).
    ///   - type: `.income` or `.expenses`. Transactions of the other
    ///     type are excluded — a category title can in principle
    ///     exist on both sides of the ledger and the user only
    ///     wants to see one direction here.
    ///   - transactions: source list (caller filters out reminders
    ///     / recurring parents already, typically by using
    ///     `transactionStore.homeTransactions`).
    ///   - targetCurrency: ISO code we convert every amount into
    ///     before summing.
    ///   - convert: rate-conversion closure (same signature as the
    ///     other analytics entry points).
    ///   - monthCount: how many months the result covers (most-recent
    ///     first internally, but the result is **chronological**:
    ///     oldest at index 0, newest at the end — that's the order
    ///     the chart wants for left-to-right rendering).
    ///   - skipCurrentMonth: when `true` (default), the current
    ///     calendar month is excluded from the window — useful for
    ///     analytics charts where an in-progress month would render
    ///     as a misleadingly short bar. With `monthCount = 6` and
    ///     `skipCurrentMonth = true` on April 17, the window is
    ///     Oct 2025 → March 2026 (the 6 most recent *fully completed*
    ///     months). Set `false` if you specifically need the
    ///     in-progress month included.
    ///   - now: pinning point for the window. Defaults to `Date()`;
    ///     parameterized for tests.
    static func monthlyHistory(
        for categoryTitle: String,
        type: TransactionType,
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        monthCount: Int = 12,
        skipCurrentMonth: Bool = true,
        now: Date = Date()
    ) -> [MonthlyTotal] {
        let calendar = Calendar.current

        // Build the bucket layout first — chronologically ordered so
        // older bars render on the left of the chart. The offset
        // window is shifted by 1 when `skipCurrentMonth` is true:
        // instead of `[0 ... monthCount-1]` we walk
        // `[1 ... monthCount]`, dropping offset 0 (the in-progress
        // month) and adding offset `monthCount` (one extra month
        // earlier) so the user still sees `monthCount` bars.
        struct Bucket {
            let year: Int
            let month: Int
            var sum: Double = 0
            var count: Int = 0
        }
        var buckets: [String: Bucket] = [:]
        var orderedKeys: [String] = []
        let lastOffset = skipCurrentMonth ? 1 : 0
        let firstOffset = lastOffset + monthCount - 1
        for offset in stride(from: firstOffset, through: lastOffset, by: -1) {
            guard let date = calendar.date(byAdding: .month, value: -offset, to: now) else { continue }
            let comps = calendar.dateComponents([.year, .month], from: date)
            guard let y = comps.year, let m = comps.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            buckets[key] = Bucket(year: y, month: m)
            orderedKeys.append(key)
        }

        // Single pass over the transactions — drop type / category
        // mismatches early so we don't pay for the formatter call
        // on irrelevant rows.
        for tx in transactions
        where tx.type == type && tx.category == categoryTitle {
            let comps = calendar.dateComponents([.year, .month], from: tx.date)
            guard let y = comps.year, let m = comps.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            guard var bucket = buckets[key] else { continue }
            bucket.sum += convert(tx.amount, tx.currency, targetCurrency)
            bucket.count += 1
            buckets[key] = bucket
        }

        return orderedKeys.compactMap { key in
            guard let bucket = buckets[key] else { return nil }
            return MonthlyTotal(
                id: key,
                year: bucket.year,
                month: bucket.month,
                total: bucket.sum,
                count: bucket.count
            )
        }
    }

    // MARK: - Daily aggregates (for the SpendingCalendarCard heatmap)

    /// Sum of all expense transactions on a single calendar day,
    /// converted into the target currency. Used as the value that
    /// drives a heatmap cell's intensity.
    struct DailyExpense: Identifiable, Equatable {
        let id: String   // "yyyy-MM-dd"
        /// Start-of-day date in the system calendar.
        let date: Date
        /// Total expense amount on this day (target-currency).
        let total: Double
        /// Number of expense transactions on this day.
        let count: Int
    }

    /// Returns one `DailyExpense` per calendar day in the requested
    /// month, in chronological order. Days with no expense
    /// transactions still appear with `total = 0, count = 0` so the
    /// calendar grid renders evenly without holes.
    ///
    /// `monthDate` may be any moment within the month — the function
    /// normalises to the year+month components.
    static func dailyExpenses(
        in monthDate: Date,
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> [DailyExpense] {
        let calendar = Calendar.current
        let monthComps = calendar.dateComponents([.year, .month], from: monthDate)
        guard
            let year = monthComps.year,
            let month = monthComps.month,
            let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1))
        else { return [] }

        let dayRange = calendar.range(of: .day, in: .month, for: firstOfMonth) ?? 1..<29

        // Bucket-per-day, pre-seeded so empty days still appear.
        struct Bucket { var sum: Double = 0; var count: Int = 0 }
        var buckets: [Int: Bucket] = [:]
        for day in dayRange { buckets[day] = Bucket() }

        for tx in transactions where tx.type == .expenses {
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            guard
                comps.year == year, comps.month == month,
                let day = comps.day, var bucket = buckets[day]
            else { continue }
            bucket.sum += convert(tx.amount, tx.currency, targetCurrency)
            bucket.count += 1
            buckets[day] = bucket
        }

        return dayRange.compactMap { day in
            guard
                let bucket = buckets[day],
                let date = calendar.date(from: DateComponents(year: year, month: month, day: day))
            else { return nil }
            return DailyExpense(
                id: String(format: "%04d-%02d-%02d", year, month, day),
                date: date,
                total: bucket.sum,
                count: bucket.count
            )
        }
    }

    /// Single 1…31 bucket for the "averages by day-of-month" mode.
    /// `monthsCounted` is the *denominator* used to divide the
    /// summed amounts — it varies for days 29-31 because some
    /// months don't have those days at all.
    struct DayOfMonthAverage: Identifiable, Equatable {
        /// `id` = `dayOfMonth` so SwiftUI's `ForEach` is happy.
        let id: Int
        let dayOfMonth: Int
        /// `sum / monthsCounted`, or 0 if nothing was spent.
        let average: Double
        /// Number of months in the user's expense range that have
        /// this day-of-month calendrically (drives the averaging
        /// denominator). Important for days 29-31 where some months
        /// (Feb in non-leap years; etc.) don't have them.
        let monthsCounted: Int
    }

    /// For each day-of-month 1…31, returns the average expense
    /// amount across the user's full expense history (per-period
    /// filtering doesn't apply to this analytic — averages need a
    /// long baseline to be meaningful).
    ///
    /// Denominator semantics (per spec):
    ///   - Range = months from first expense to last expense,
    ///     inclusive. Months without any expense in between **count**
    ///     in the denominator (otherwise gaps would inflate averages).
    ///   - Days 29-31 use only those months from the range that
    ///     calendrically have those days (Feb is excluded for day 30,
    ///     non-leap Feb is excluded for day 29, etc.).
    static func averageDailyByDayOfMonth(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> [DayOfMonthAverage] {
        let calendar = Calendar.current
        let expenses = transactions.filter { $0.type == .expenses }

        guard
            let firstDate = expenses.map(\.date).min(),
            let lastDate = expenses.map(\.date).max()
        else {
            return (1...31).map {
                DayOfMonthAverage(id: $0, dayOfMonth: $0, average: 0, monthsCounted: 0)
            }
        }

        // Sum spending per day-of-month (1...31) across all months.
        var sumByDay: [Int: Double] = [:]
        for tx in expenses {
            let day = calendar.component(.day, from: tx.date)
            sumByDay[day, default: 0] += convert(tx.amount, tx.currency, targetCurrency)
        }

        // Enumerate every month in [firstDate, lastDate] and tally,
        // for each day-of-month, how many of those months have it.
        var monthsByDay: [Int: Int] = [:]
        var current = calendar.date(
            from: calendar.dateComponents([.year, .month], from: firstDate)
        ) ?? firstDate
        let endMonth = calendar.date(
            from: calendar.dateComponents([.year, .month], from: lastDate)
        ) ?? lastDate
        while current <= endMonth {
            let dayRange = calendar.range(of: .day, in: .month, for: current) ?? 1..<29
            for day in dayRange { monthsByDay[day, default: 0] += 1 }
            guard let next = calendar.date(byAdding: .month, value: 1, to: current) else { break }
            current = next
        }

        return (1...31).map { day in
            let total = sumByDay[day, default: 0]
            let monthCount = monthsByDay[day, default: 0]
            let avg = monthCount > 0 ? total / Double(monthCount) : 0
            return DayOfMonthAverage(
                id: day,
                dayOfMonth: day,
                average: avg,
                monthsCounted: monthCount
            )
        }
    }

    /// Maximum single-day expense total across the user's **entire**
    /// expense history. Used to anchor the heatmap colour scale's
    /// red end so the colour intensity is comparable across months
    /// (per spec — "не в видимом окне, а за всю историю").
    static func maxDailyExpenseEver(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double
    ) -> Double {
        let calendar = Calendar.current
        var dayBuckets: [String: Double] = [:]
        for tx in transactions where tx.type == .expenses {
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let key = String(format: "%04d-%02d-%02d", y, m, d)
            dayBuckets[key, default: 0] += convert(tx.amount, tx.currency, targetCurrency)
        }
        return dayBuckets.values.max() ?? 0
    }


    // MARK: - Per-category statistical extremes (last-month outliers)

    /// A single transaction in the last fully-completed month whose
    /// amount was a statistical outlier vs the user's typical
    /// **per-transaction** spend in that category (across all of
    /// history). Surfaces the "wow you went big" moment as a
    /// concrete purchase the user can recognise.
    struct BigPurchase: Equatable {
        let transaction: Transaction
        /// Amount converted into the target currency. Cached here
        /// so the UI doesn't have to redo the FX lookup.
        let convertedAmount: Double
        let categoryTitle: String
        let categoryEmoji: String
        /// Mean transaction amount in this category (target
        /// currency, all-time). The "your usual purchase" baseline
        /// the multiplier compares against.
        let categoryMean: Double
        /// `convertedAmount / categoryMean` — the user-facing
        /// "Nx more than usual" number.
        let multiplier: Double
        /// `(amount − mean) / stddev`, used for ranking. Stored
        /// for future UI uses; not currently rendered.
        let zScore: Double
    }

    /// A single category whose **last-month total** was a
    /// statistical outlier vs that category's prior monthly
    /// totals. Surfaces the "your X-spending blew up last month"
    /// moment at the category-aggregate level.
    struct BigCategoryMonth: Equatable {
        let date: Date            // first of the last month
        let year: Int
        let month: Int
        let categoryTitle: String
        let categoryEmoji: String
        /// Last month's total spend for this category (target
        /// currency).
        let total: Double
        /// Mean of monthly totals over **prior** months
        /// (last month is excluded so it doesn't dilute the
        /// baseline).
        let mean: Double
        let multiplier: Double
        let zScore: Double
    }

    /// Hard floors below which we don't surface either extremes
    /// card — statistics on tiny samples mislead more than they
    /// inform.
    static let extremesMinTotalActiveDays: Int = 14
    static let extremesMinCategories: Int = 2

    /// Z-score threshold ≈ 2σ. Adapts automatically to per-category
    /// variance: a stable category flags small jumps; a wild
    /// category requires huge ones.
    static let extremesZThreshold: Double = 2.0

    /// Per-category sample-size floor for **transaction-level**
    /// outlier detection. Higher than the monthly floor because
    /// transactions tend to scatter more than month-aggregates,
    /// and we want enough datapoints for σ to stabilise.
    static let extremesMinTransactionsPerCategory: Int = 5

    /// Per-category sample-size floor for **monthly-aggregate**
    /// outlier detection. The baseline excludes last month, so 3
    /// here means "the user has at least 3 prior months with
    /// activity in this category".
    static let extremesMinPriorMonthsPerCategory: Int = 3

    /// The single most-outstanding transaction in the previous
    /// fully-completed calendar month, measured by per-category
    /// z-score against the user's all-time history of that
    /// category. Returns `nil` when no transaction qualifies — the
    /// user hasn't accumulated enough activity yet, or nothing
    /// rose above the threshold.
    static func biggestPurchaseInLastMonth(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        emojiByCategory: [String: String] = [:],
        minTotalActiveDays: Int = extremesMinTotalActiveDays,
        minCategories: Int = extremesMinCategories,
        minSamplesPerCategory: Int = extremesMinTransactionsPerCategory,
        zThreshold: Double = extremesZThreshold,
        now: Date = Date()
    ) -> BigPurchase? {
        let calendar = Calendar.current

        // Last month = the previous fully-completed calendar month.
        // E.g. on April 30 → March; on May 1 → April.
        guard
            let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: now),
            let lastMonthInterval = calendar.dateInterval(of: .month, for: lastMonthDate)
        else { return nil }

        // Card-level gates: need enough overall activity AND
        // variety before we render any "anomaly" judgement.
        var globalActiveDays: Set<String> = []
        var categoriesWithActivity: Set<String> = []
        var byCategory: [String: [(amount: Double, tx: Transaction)]] = [:]

        for tx in transactions where tx.type == .expenses {
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let amount = convert(tx.amount, tx.currency, targetCurrency)
            guard amount > 0 else { continue }
            globalActiveDays.insert(String(format: "%04d-%02d-%02d", y, m, d))
            categoriesWithActivity.insert(tx.category)
            byCategory[tx.category, default: []].append((amount, tx))
        }

        guard globalActiveDays.count >= minTotalActiveDays else { return nil }
        guard categoriesWithActivity.count >= minCategories else { return nil }

        var best: BigPurchase?
        var bestZ: Double = -.infinity

        for (category, items) in byCategory {
            guard items.count >= minSamplesPerCategory else { continue }

            let amounts = items.map(\.amount)
            let n = Double(amounts.count)
            let mean = amounts.reduce(0, +) / n
            let denom = max(n - 1, 1)
            let variance = amounts.reduce(0) { acc, v in
                acc + (v - mean) * (v - mean)
            } / denom
            let stddev = variance.squareRoot()
            guard stddev > 0 else { continue }

            for item in items where lastMonthInterval.contains(item.tx.date) {
                let z = (item.amount - mean) / stddev
                guard z >= zThreshold else { continue }
                if z > bestZ {
                    bestZ = z
                    let mult = mean > 0 ? item.amount / mean : 1
                    best = BigPurchase(
                        transaction: item.tx,
                        convertedAmount: item.amount,
                        categoryTitle: category,
                        categoryEmoji: emojiByCategory[category] ?? item.tx.emoji,
                        categoryMean: mean,
                        multiplier: mult,
                        zScore: z
                    )
                }
            }
        }

        return best
    }

    /// The single category whose total last-month spend was the
    /// most-outstanding outlier vs that category's *prior* months
    /// (last month is excluded from the baseline, so the comparison
    /// is "last month" vs "what your usual month looks like").
    /// Returns `nil` when no category qualifies.
    static func biggestCategorySumInLastMonth(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        emojiByCategory: [String: String] = [:],
        minTotalActiveDays: Int = extremesMinTotalActiveDays,
        minCategories: Int = extremesMinCategories,
        minPriorMonths: Int = extremesMinPriorMonthsPerCategory,
        zThreshold: Double = extremesZThreshold,
        now: Date = Date()
    ) -> BigCategoryMonth? {
        let calendar = Calendar.current

        // Last month identification + key.
        guard
            let lastMonthDate = calendar.date(byAdding: .month, value: -1, to: now),
            let lastMonthStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: lastMonthDate)
            )
        else { return nil }
        let lastMonthComps = calendar.dateComponents([.year, .month], from: lastMonthDate)
        guard let lastY = lastMonthComps.year, let lastM = lastMonthComps.month else { return nil }
        let lastMonthKey = String(format: "%04d-%02d", lastY, lastM)

        // Card-level gates + per-category month aggregation in a
        // single pass.
        var globalActiveDays: Set<String> = []
        var categoriesWithActivity: Set<String> = []
        var byCategoryMonth: [String: [String: Double]] = [:]
        var emojiFallback: [String: String] = [:]

        for tx in transactions where tx.type == .expenses {
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            let amount = convert(tx.amount, tx.currency, targetCurrency)
            guard amount > 0 else { continue }
            globalActiveDays.insert(String(format: "%04d-%02d-%02d", y, m, d))
            categoriesWithActivity.insert(tx.category)
            let monthKey = String(format: "%04d-%02d", y, m)
            byCategoryMonth[tx.category, default: [:]][monthKey, default: 0] += amount
            emojiFallback[tx.category] = tx.emoji
        }

        guard globalActiveDays.count >= minTotalActiveDays else { return nil }
        guard categoriesWithActivity.count >= minCategories else { return nil }

        var best: BigCategoryMonth?
        var bestZ: Double = -.infinity

        for (category, monthSums) in byCategoryMonth {
            // Need a last-month value to even consider this category.
            guard let lastSum = monthSums[lastMonthKey] else { continue }

            // Baseline = all prior months (excluding last month) so
            // last month doesn't dilute the comparison.
            let priorSums = monthSums.filter { $0.key != lastMonthKey }.values
            guard priorSums.count >= minPriorMonths else { continue }

            let n = Double(priorSums.count)
            let mean = priorSums.reduce(0, +) / n
            let denom = max(n - 1, 1)
            let variance = priorSums.reduce(0) { acc, v in
                acc + (v - mean) * (v - mean)
            } / denom
            let stddev = variance.squareRoot()
            guard stddev > 0 else { continue }

            let z = (lastSum - mean) / stddev
            guard z >= zThreshold else { continue }

            if z > bestZ {
                bestZ = z
                let mult = mean > 0 ? lastSum / mean : 1
                best = BigCategoryMonth(
                    date: lastMonthStart,
                    year: lastY,
                    month: lastM,
                    categoryTitle: category,
                    categoryEmoji: emojiByCategory[category] ?? emojiFallback[category] ?? "📁",
                    total: lastSum,
                    mean: mean,
                    multiplier: mult,
                    zScore: z
                )
            }
        }

        return best
    }

    // MARK: - Small-purchases savings card

    /// Aggregate result for the "you could save N on small
    /// purchases" card. Contains the user-facing numbers (N, X)
    /// plus the full list of qualifying small purchases for the
    /// tap-to-detail sheet.
    struct SmallPurchasesSavings: Equatable {
        /// Amount line below which a transaction counts as
        /// "small" for **this** user. Computed adaptively from
        /// the user's own typical-purchase distribution; not
        /// currently rendered ("show only the narrative" per
        /// design) but kept on the result for future surfaces.
        let smallnessThreshold: Double
        /// **N** — count of small purchases that fall inside a
        /// qualifying month (a month where at least one category
        /// had ≥ N same-category small purchases). Purchases in
        /// non-qualifying months are excluded from the surfaced
        /// total — they still help calibrate the threshold but
        /// don't count for "savings" maths.
        let totalQualifyingSmallPurchases: Int
        /// **X** — the largest single-month sum of qualifying
        /// small purchases. Reads naturally as "you could save up
        /// to X per month": the user's worst (= biggest) month
        /// is the best evidence of what's feasible to cut.
        let maxMonthlySavings: Double
        /// Most-frequent category among the qualifying small
        /// purchases. Used to pick the icon/emoji for the card —
        /// rendering the dominant habit visually anchors the
        /// "you're spending a lot on X" message in something
        /// concrete (e.g. coffee ☕).
        let mostFrequentCategoryTitle: String
        /// Live-resolved emoji for `mostFrequentCategoryTitle`
        /// (from `CategoryStore` via `emojiByCategory`); falls
        /// back to whatever emoji was stored on the matching
        /// transaction if the category was deleted.
        let mostFrequentCategoryEmoji: String
        /// Sorted newest-first for the detail sheet — same order
        /// the home transaction list uses, so the rows feel
        /// familiar to the user.
        let smallPurchases: [Transaction]
    }

    /// Adaptive smallness baseline gates and constants. Tuned to
    /// match the spec ("≥ 4 same-category small purchases per
    /// month, ≥ 2 such months, ≥ 2 distinct categories overall").
    static let savingsMinActiveDays: Int = 14
    /// Floor on transaction count before a percentile is meaningful.
    static let savingsMinTotalTransactions: Int = 10
    /// Per-month, per-category floor: a month qualifies when **at
    /// least one** of its categories has this many small purchases
    /// in it. Other small purchases in that month — from other
    /// categories — also count once the month qualifies.
    static let savingsMinPurchasesPerCategoryPerMonth: Int = 4
    static let savingsMinQualifyingMonths: Int = 2
    static let savingsMinCategories: Int = 2
    /// Upper bound on the smallness threshold: even if a
    /// percentile-based threshold would land high, we cap at this
    /// fraction of mean so we don't accidentally label "the
    /// cheapest end of normal" as "small".
    static let savingsThresholdMeanFactor: Double = 0.4

    /// Identifies "small purchase savings" — transactions that
    /// are individually below the user's adaptive smallness
    /// threshold AND form a recognisable habit.
    ///
    /// **Adaptive threshold**: derived from the user's own
    /// typical expense distribution as `min(Q1, mean × 0.4)`.
    /// Q1 anchors the bottom-quartile definition of small;
    /// `mean × 0.4` caps it so high-spending users with high Q1s
    /// don't accidentally flag "the cheap end of normal" as
    /// small. Recomputed on every call from a fresh read of
    /// `transactions` — when the user's spending pattern shifts,
    /// the definition of "small" auto-adjusts.
    ///
    /// **Qualifying-month rule** (per spec): a month qualifies
    /// when at least one category in it has ≥
    /// `minPurchasesPerCategoryPerMonth` small purchases. ALL
    /// small purchases of a qualifying month count toward N and
    /// X — including ones from other categories. So 4 coffees +
    /// 1 candy + 1 bus ticket in one month → month qualifies on
    /// coffee, all 6 count.
    ///
    /// Returns `nil` when any gate fails — the card hides
    /// itself.
    static func smallPurchasesSavings(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        emojiByCategory: [String: String] = [:],
        minActiveDays: Int = savingsMinActiveDays,
        minTotalTransactions: Int = savingsMinTotalTransactions,
        minPurchasesPerCategoryPerMonth: Int = savingsMinPurchasesPerCategoryPerMonth,
        minQualifyingMonths: Int = savingsMinQualifyingMonths,
        minCategories: Int = savingsMinCategories,
        thresholdMeanFactor: Double = savingsThresholdMeanFactor
    ) -> SmallPurchasesSavings? {
        let calendar = Calendar.current

        // 1. Build (tx, convertedAmount) pairs + global activity gate.
        var items: [(tx: Transaction, amount: Double)] = []
        var globalActiveDays: Set<String> = []
        for tx in transactions where tx.type == .expenses {
            let amount = convert(tx.amount, tx.currency, targetCurrency)
            guard amount > 0 else { continue }
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            guard let y = comps.year, let m = comps.month, let d = comps.day else { continue }
            items.append((tx, amount))
            globalActiveDays.insert(String(format: "%04d-%02d-%02d", y, m, d))
        }

        guard globalActiveDays.count >= minActiveDays else { return nil }
        guard items.count >= minTotalTransactions else { return nil }

        // 2. Compute adaptive smallness threshold from ALL expense
        // amounts. This baseline includes purchases that won't end
        // up in any qualifying month — they still help calibrate
        // what counts as "small for this user".
        let sortedAmounts = items.map { $0.amount }.sorted()
        let q1Index = max(0, Int(Double(sortedAmounts.count - 1) * 0.25))
        let q1 = sortedAmounts[q1Index]
        let mean = sortedAmounts.reduce(0, +) / Double(sortedAmounts.count)
        let threshold = Swift.min(q1, mean * thresholdMeanFactor)
        guard threshold > 0 else { return nil }

        // 3. Filter to small purchases (amount ≤ threshold).
        let smallItems = items.filter { $0.amount <= threshold }
        guard !smallItems.isEmpty else { return nil }

        // 4. Group small purchases by month, tracking per-category
        // counts so we can apply the "≥ N same-category" rule.
        struct MonthBucket {
            var allSmall: [(tx: Transaction, amount: Double)] = []
            var byCategory: [String: Int] = [:]
            var sum: Double = 0
        }
        var byMonth: [String: MonthBucket] = [:]
        for entry in smallItems {
            let comps = calendar.dateComponents([.year, .month], from: entry.tx.date)
            guard let y = comps.year, let m = comps.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            var bucket = byMonth[key] ?? MonthBucket()
            bucket.allSmall.append(entry)
            bucket.byCategory[entry.tx.category, default: 0] += 1
            bucket.sum += entry.amount
            byMonth[key] = bucket
        }

        // 5. A month qualifies when at least one category has
        // ≥ minPurchasesPerCategoryPerMonth small purchases in
        // that month. ALL small purchases of a qualifying month
        // are surfaced (including ones from other categories).
        let qualifyingBuckets = byMonth.values.filter { bucket in
            bucket.byCategory.values.contains { $0 >= minPurchasesPerCategoryPerMonth }
        }
        guard qualifyingBuckets.count >= minQualifyingMonths else { return nil }

        // 6. Variety gate — categories among the surfaced
        // (qualifying-month) small purchases.
        let qualifyingPurchases = qualifyingBuckets.flatMap { $0.allSmall }
        let categories = Set(qualifyingPurchases.map { $0.tx.category })
        guard categories.count >= minCategories else { return nil }

        // 7. X = max single-month sum across qualifying months.
        let maxSum = qualifyingBuckets.map { $0.sum }.max() ?? 0
        // 8. N = total count of qualifying small purchases.
        let n = qualifyingPurchases.count

        // 9. Most-frequent category among qualifying purchases —
        // anchors the card's emoji to the dominant habit. Tie-break
        // on category name ascending so the result is stable.
        var categoryCounts: [String: Int] = [:]
        var emojiFallback: [String: String] = [:]
        for entry in qualifyingPurchases {
            categoryCounts[entry.tx.category, default: 0] += 1
            // Last-wins fallback emoji — only used when the
            // category isn't in the live `emojiByCategory` map.
            emojiFallback[entry.tx.category] = entry.tx.emoji
        }
        let topCategory = categoryCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .first?.key ?? ""
        let topEmoji = emojiByCategory[topCategory]
            ?? emojiFallback[topCategory]
            ?? "🛒"

        // 10. Sort newest-first for the detail sheet.
        let sortedTxs = qualifyingPurchases
            .map { $0.tx }
            .sorted { $0.date > $1.date }

        return SmallPurchasesSavings(
            smallnessThreshold: threshold,
            totalQualifyingSmallPurchases: n,
            maxMonthlySavings: maxSum,
            mostFrequentCategoryTitle: topCategory,
            mostFrequentCategoryEmoji: topEmoji,
            smallPurchases: sortedTxs
        )
    }

    // MARK: - Monthly trend cards (net balance / expenses / income)

    /// Which value series the trend is measured on. Each kind
    /// drives both the data extraction (cumulative vs per-month
    /// flow) and the favorable/unfavorable interpretation
    /// (balance growing = good; expenses shrinking = good).
    enum TrendKind: Equatable {
        case netBalance
        case expenses
        case income
    }

    /// Result of a monthly-trend analysis. Emits the average
    /// percentage change per month — positive = growing, negative =
    /// shrinking — along with the time-window length so the UI
    /// can show "based on N months".
    struct MonthlyTrend: Equatable {
        let kind: TrendKind
        /// Signed % change per month (linear regression slope
        /// normalised against the absolute mean of the series).
        /// Values of small magnitude (`< 1%`) are suppressed
        /// upstream — the result, if any, is always meaningful.
        let percentPerMonth: Double
        /// Number of months in the time series. Useful both for
        /// transparency ("based on N months") and for sanity
        /// — small N → less reliable trend.
        let monthsCovered: Int

        /// Whether the trend direction is **favorable** for the
        /// user. Drives the accent colour the UI uses for the
        /// percentage:
        ///   - balance / income growing = good (green)
        ///   - expenses shrinking      = good (green)
        ///   - opposites               = bad  (warm orange)
        var isFavorable: Bool {
            switch kind {
            case .netBalance, .income: return percentPerMonth >= 0
            case .expenses: return percentPerMonth <= 0
            }
        }
    }

    /// Hard floor on the time-series length — fewer months than
    /// this and the trend is too noisy to surface. Per spec: "хотя
    /// бы 2 месяца".
    static let trendMinMonths: Int = 2

    /// Suppress the card when the absolute % change is below this
    /// floor. Per spec: "если этот процент маленький, например
    /// <1%, то тогда эту карточку лучше скрыть". With a stable
    /// trend at this magnitude there's nothing actionable to say.
    static let trendMinPercentToShow: Double = 1.0

    /// Linear-regression-based monthly trend for one of three value
    /// series — net balance (cumulative), monthly expenses, or
    /// monthly income. Returns `nil` (card hides) when:
    ///   - The user has fewer than `trendMinMonths` months of
    ///     activity for the chosen kind.
    ///   - The mean of the series is too close to zero (the
    ///     resulting % would be unstable and meaningless).
    ///   - The absolute % change is below `trendMinPercentToShow`.
    ///
    /// **Method**: build a chronological per-month value series
    /// from the first month of relevant activity through the
    /// previous fully-completed calendar month (excluding the
    /// in-progress current month for consistency with the rest
    /// of the analytics surface). Fit a least-squares line and
    /// express the slope as a percentage of the absolute mean of
    /// the series — `slope / |mean| × 100` — giving a single
    /// signed "average % change per month" number.
    ///
    /// Why not period-over-period geometric mean? Because the
    /// balance series can cross zero / be negative, and the
    /// expense/income series can have zero months mid-stream,
    /// both of which break geometric formulas. Linear regression
    /// is well-defined for all input shapes the user can produce.
    static func monthlyTrend(
        kind: TrendKind,
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        minMonths: Int = trendMinMonths,
        minPercentToShow: Double = trendMinPercentToShow,
        now: Date = Date()
    ) -> MonthlyTrend? {
        let calendar = Calendar.current

        // 1. Determine the first activity date relevant to the
        // chosen kind. For .netBalance any transaction counts;
        // for .expenses / .income only transactions of the
        // matching type. This makes the time series start from
        // when the user actually began producing the data we're
        // about to trend — otherwise leading zero months would
        // distort the linear fit.
        let firstActivityDate: Date?
        switch kind {
        case .netBalance:
            firstActivityDate = transactions.compactMap { tx -> Date? in
                let amount = convert(tx.amount, tx.currency, targetCurrency)
                return amount > 0 ? tx.date : nil
            }.min()
        case .expenses:
            // No `.lazy` here — `LazySequence`'s `compactMap`
            // takes an escaping closure, which we can't satisfy
            // with the non-escaping `convert` parameter. Eager is
            // fine at this scale.
            firstActivityDate = transactions
                .filter { $0.type == .expenses }
                .compactMap { tx -> Date? in
                    let amount = convert(tx.amount, tx.currency, targetCurrency)
                    return amount > 0 ? tx.date : nil
                }
                .min()
        case .income:
            firstActivityDate = transactions
                .filter { $0.type == .income }
                .compactMap { tx -> Date? in
                    let amount = convert(tx.amount, tx.currency, targetCurrency)
                    return amount > 0 ? tx.date : nil
                }
                .min()
        }
        guard let first = firstActivityDate else { return nil }

        // 2. End of the time series = previous fully-completed
        // month. Excludes the in-progress current month for
        // consistency with the rest of the analytics surface.
        guard
            let prevMonthDate = calendar.date(byAdding: .month, value: -1, to: now),
            let endStart = calendar.date(
                from: calendar.dateComponents([.year, .month], from: prevMonthDate)
            )
        else { return nil }

        guard let firstStart = calendar.date(
            from: calendar.dateComponents([.year, .month], from: first)
        ) else { return nil }
        guard firstStart <= endStart else { return nil }

        // 3. Enumerate calendar months [first, end] inclusive.
        var months: [Date] = []
        var cursor = firstStart
        while cursor <= endStart {
            months.append(cursor)
            guard let next = calendar.date(byAdding: .month, value: 1, to: cursor) else { break }
            cursor = next
        }
        guard months.count >= minMonths else { return nil }

        // 4. Aggregate per-month income and expense sums (in target
        // currency) across the **whole** transaction list — even
        // pre-firstActivity transactions, which won't be reached
        // by the month list anyway.
        struct MonthData {
            var income: Double = 0
            var expenses: Double = 0
            var delta: Double { income - expenses }
        }
        var byMonth: [String: MonthData] = [:]
        for tx in transactions {
            let amount = convert(tx.amount, tx.currency, targetCurrency)
            guard amount > 0 else { continue }
            let comps = calendar.dateComponents([.year, .month], from: tx.date)
            guard let y = comps.year, let m = comps.month else { continue }
            let key = String(format: "%04d-%02d", y, m)
            var data = byMonth[key] ?? MonthData()
            switch tx.type {
            case .income: data.income += amount
            case .expenses: data.expenses += amount
            }
            byMonth[key] = data
        }

        // 5. Build the value series for the chosen kind. Balance
        // is cumulative (carries running sum month-to-month);
        // expenses / income are per-month flow.
        var values: [Double] = []
        var cumulative: Double = 0
        for monthDate in months {
            let comps = calendar.dateComponents([.year, .month], from: monthDate)
            let key = String(format: "%04d-%02d", comps.year ?? 0, comps.month ?? 0)
            let data = byMonth[key] ?? MonthData()
            switch kind {
            case .netBalance:
                cumulative += data.delta
                values.append(cumulative)
            case .expenses:
                values.append(data.expenses)
            case .income:
                values.append(data.income)
            }
        }

        // 6. Least-squares linear regression on (i, value_i).
        let n = Double(values.count)
        let xs = (0..<values.count).map { Double($0) }
        let meanX = xs.reduce(0, +) / n
        let meanY = values.reduce(0, +) / n

        let numerator = zip(xs, values)
            .map { ($0 - meanX) * ($1 - meanY) }
            .reduce(0, +)
        let denominator = xs
            .map { ($0 - meanX) * ($0 - meanX) }
            .reduce(0, +)
        guard denominator > 0 else { return nil }
        let slope = numerator / denominator

        // 7. Normalise against absolute mean. `|mean|` keeps the
        // sign convention "positive = growing" regardless of
        // whether the series is negative-valued (e.g. balance
        // hovering below zero).
        guard abs(meanY) > 0.01 else { return nil }
        let percentPerMonth = slope / abs(meanY) * 100

        // 8. Suppress trivially small trends per spec.
        guard abs(percentPerMonth) >= minPercentToShow else { return nil }

        return MonthlyTrend(
            kind: kind,
            percentPerMonth: percentPerMonth,
            monthsCovered: values.count
        )
    }

    // MARK: - Category cannibalization (substitution patterns)

    /// One detected "cannibalization" event — a single calendar
    /// month where one category's spend rose well above its
    /// historical mean (z ≥ +`zThreshold`σ) **and** another
    /// category's spend dropped well below its mean (z ≤
    /// −`zThreshold`σ), with the two deltas being similar enough
    /// in magnitude to read as substitution rather than two
    /// independent anomalies.
    ///
    /// `deltaUp` and `deltaDown` are both stored as **positive**
    /// magnitudes so the UI can render "spent X more" / "dropped
    /// by Y" without sign juggling.
    struct CategoryCannibalization: Equatable {
        let monthDate: Date          // first of the month
        let year: Int
        let month: Int
        /// Category whose spend went up.
        let categoryUp: String
        let categoryUpEmoji: String
        /// Category whose spend went down.
        let categoryDown: String
        let categoryDownEmoji: String
        /// Positive magnitude — how much MORE was spent on
        /// `categoryUp` vs its historical mean.
        let deltaUp: Double
        /// Positive magnitude — how much LESS was spent on
        /// `categoryDown` vs its historical mean.
        let deltaDown: Double
        let zScoreUp: Double
        let zScoreDown: Double
    }

    /// Card-level activity floor — user must have at least this
    /// many distinct months with expense data in their history,
    /// otherwise we don't even attempt to find substitution
    /// patterns. Per spec: "минимум 2 месяца надо".
    static let cannibalizationMinTotalMonths: Int = 2

    /// Window of candidate months we scan for cannibalization
    /// signals — the last N fully-completed months. Picking
    /// across multiple months gives the user a chance to see a
    /// pattern they might not catch glancing at the most recent
    /// month alone.
    static let cannibalizationCandidateMonths: Int = 6

    /// Per-category baseline floor. Computing a stable σ for a
    /// category needs at least this many monthly samples
    /// **excluding** the candidate month being evaluated.
    static let cannibalizationMinSamplesPerCategory: Int = 3

    /// Z-score gate. The "up" category must be ≥ +zThreshold·σ
    /// above its mean; the "down" category must be ≤ −zThreshold·σ
    /// below its mean. Adapts automatically to per-category
    /// variance — wild categories need bigger swings to qualify.
    static let cannibalizationZThreshold: Double = 2.0

    /// Substitution-similarity tolerance. The two deltas must be
    /// close enough in magnitude that they read as one cause:
    /// `|deltaUp − deltaDown| / max(deltaUp, deltaDown) ≤ tolerance`.
    /// 0.30 means the smaller delta is at least 70% of the larger
    /// — clear substitution, not two independent shocks.
    static let cannibalizationSubstitutionTolerance: Double = 0.3

    /// Detect a single category-cannibalization (substitution)
    /// pattern across the user's recent history. Returns the
    /// **strongest** pair (largest combined delta magnitude) found
    /// in any of the last `candidateMonths` fully-completed months,
    /// or `nil` if nothing qualifies. Currency-agnostic — every
    /// amount is converted into `targetCurrency` first.
    static func categoryCannibalization(
        transactions: [Transaction],
        targetCurrency: String,
        convert: (_ amount: Double, _ from: String, _ to: String) -> Double,
        emojiByCategory: [String: String] = [:],
        minTotalMonths: Int = cannibalizationMinTotalMonths,
        candidateMonths: Int = cannibalizationCandidateMonths,
        minSamplesPerCategory: Int = cannibalizationMinSamplesPerCategory,
        zThreshold: Double = cannibalizationZThreshold,
        substitutionTolerance: Double = cannibalizationSubstitutionTolerance,
        now: Date = Date()
    ) -> CategoryCannibalization? {
        let calendar = Calendar.current

        // 1. Aggregate per (category, month). Skip non-positive
        // amounts (defensive — should already be filtered).
        struct MonthBucket {
            var sum: Double = 0
            let date: Date    // first of month
            let year: Int
            let month: Int
        }
        var byCategoryMonth: [String: [String: MonthBucket]] = [:]
        var emojiFallback: [String: String] = [:]
        var allMonthKeys: Set<String> = []

        for tx in transactions where tx.type == .expenses {
            let comps = calendar.dateComponents([.year, .month], from: tx.date)
            guard
                let y = comps.year, let m = comps.month,
                let monthStart = calendar.date(from: DateComponents(year: y, month: m, day: 1))
            else { continue }
            let amount = convert(tx.amount, tx.currency, targetCurrency)
            guard amount > 0 else { continue }
            let key = String(format: "%04d-%02d", y, m)
            var bucket = byCategoryMonth[tx.category]?[key]
                ?? MonthBucket(date: monthStart, year: y, month: m)
            bucket.sum += amount
            byCategoryMonth[tx.category, default: [:]][key] = bucket
            emojiFallback[tx.category] = tx.emoji
            allMonthKeys.insert(key)
        }

        // Card-level "user has enough activity" gate.
        guard allMonthKeys.count >= minTotalMonths else { return nil }
        guard !byCategoryMonth.isEmpty else { return nil }

        // 2. Build the list of candidate month keys (last N
        // fully-completed months, most-recent first).
        guard let prevMonthDate = calendar.date(byAdding: .month, value: -1, to: now) else {
            return nil
        }
        var candidateMonthKeys: [String] = []
        var cursor = prevMonthDate
        for _ in 0..<candidateMonths {
            let comps = calendar.dateComponents([.year, .month], from: cursor)
            guard let y = comps.year, let m = comps.month else { break }
            candidateMonthKeys.append(String(format: "%04d-%02d", y, m))
            guard let prev = calendar.date(byAdding: .month, value: -1, to: cursor) else { break }
            cursor = prev
        }

        // 3. For each candidate month, compute z-scores per
        // category vs **its own** prior-months baseline (excluding
        // this month). Find the strongest UP × DOWN pair where the
        // two deltas are similar enough in magnitude to read as a
        // substitution.
        struct ZScoreEntry {
            let category: String
            let monthSum: Double
            let baselineMean: Double
            let zScore: Double
            let date: Date
            let year: Int
            let month: Int
        }

        var best: CategoryCannibalization?
        var bestScore: Double = 0

        for monthKey in candidateMonthKeys {
            var entries: [ZScoreEntry] = []
            for (category, monthSums) in byCategoryMonth {
                guard let bucket = monthSums[monthKey] else { continue }
                let priorSums = monthSums
                    .filter { $0.key != monthKey }
                    .values
                    .map { $0.sum }
                guard priorSums.count >= minSamplesPerCategory else { continue }

                let n = Double(priorSums.count)
                let mean = priorSums.reduce(0, +) / n
                let denom = max(n - 1, 1)
                let variance = priorSums.reduce(0) { acc, v in
                    acc + (v - mean) * (v - mean)
                } / denom
                let stddev = sqrt(variance)
                guard stddev > 0 else { continue }

                let z = (bucket.sum - mean) / stddev
                entries.append(ZScoreEntry(
                    category: category,
                    monthSum: bucket.sum,
                    baselineMean: mean,
                    zScore: z,
                    date: bucket.date,
                    year: bucket.year,
                    month: bucket.month
                ))
            }

            let upCandidates = entries.filter { $0.zScore >= zThreshold }
            let downCandidates = entries.filter { $0.zScore <= -zThreshold }

            for up in upCandidates {
                let deltaUp = up.monthSum - up.baselineMean   // > 0
                for down in downCandidates {
                    let deltaDown = down.baselineMean - down.monthSum  // > 0
                    let maxMagnitude = max(deltaUp, deltaDown)
                    guard maxMagnitude > 0 else { continue }
                    // Substitution: deltas are similar in size.
                    let asymmetry = abs(deltaUp - deltaDown) / maxMagnitude
                    guard asymmetry <= substitutionTolerance else { continue }

                    // Score = total magnitude of the substitution.
                    // Bigger swings win when multiple candidate
                    // pairs / months exist.
                    let score = deltaUp + deltaDown
                    if score > bestScore {
                        bestScore = score
                        best = CategoryCannibalization(
                            monthDate: up.date,
                            year: up.year,
                            month: up.month,
                            categoryUp: up.category,
                            categoryUpEmoji: emojiByCategory[up.category]
                                ?? emojiFallback[up.category] ?? "📁",
                            categoryDown: down.category,
                            categoryDownEmoji: emojiByCategory[down.category]
                                ?? emojiFallback[down.category] ?? "📁",
                            deltaUp: deltaUp,
                            deltaDown: deltaDown,
                            zScoreUp: up.zScore,
                            zScoreDown: down.zScore
                        )
                    }
                }
            }
        }

        return best
    }
}

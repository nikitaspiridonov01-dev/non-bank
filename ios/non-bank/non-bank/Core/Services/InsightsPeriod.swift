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
///
/// ## File layout
///
/// The enum cases + the constructor live above. The two
/// responsibilities — **filtering** a transaction list and
/// **formatting** the period for the UI — live in dedicated
/// extensions below so the surface area for each side is easy to
/// read. Filter-only changes (date math, calendar handling) touch
/// the filter extension; display-string changes (locale, date
/// formats) touch the formatter extension.
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

// MARK: - Period filter

extension InsightsPeriod {

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
}

// MARK: - Period formatter

extension InsightsPeriod {

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
}

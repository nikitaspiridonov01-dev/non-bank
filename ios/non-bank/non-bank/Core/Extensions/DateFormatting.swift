import Foundation

// MARK: - Date Formatting
//
// Centralises the three date-format patterns repeated across views,
// each with consistent **year suppression** logic (omit the year
// when the date is in the current calendar year, include it
// otherwise — keeps labels compact for typical "this year" cases
// while staying unambiguous for older dates).
//
// Replaces:
//   - 4× `formatDate` returning "MMM d" — `BigPurchaseCard`,
//     `CategoryAmountRow`, `CategoryCannibalizationCard`,
//     `SmallExpensesListView`.
//   - 3× `formatMonth` returning "LLLL" — `BigCategoryMonthCard`,
//     `CategoryCannibalizationCard`, `SpendingCalendarCard`.
//   - 5+ `formatSectionDate` returning "WED, MAR 15" —
//     `DebtSummaryView`, `SmallExpensesListView`, hand-rolled in
//     `CategoryHistoryView`'s month list, etc.

extension Date {

    /// `"Mar 15"` when `self` is in the current calendar year,
    /// `"Mar 15, 2024"` otherwise. Inline-narrative friendly
    /// ("This purchase, on Mar 15, was…").
    func formattedMonthDay(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let yearOfDate = calendar.component(.year, from: self)
        let currentYear = calendar.component(.year, from: now)
        let formatter = Self.cachedFormatter
        formatter.dateFormat = (yearOfDate == currentYear) ? "MMM d" : "MMM d, yyyy"
        return formatter.string(from: self)
    }

    /// `"March"` when `self` is in the current calendar year,
    /// `"March 2024"` otherwise. Used in narrative cards
    /// ("In March, you spent…").
    func formattedMonth(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let yearOfDate = calendar.component(.year, from: self)
        let currentYear = calendar.component(.year, from: now)
        let formatter = Self.cachedFormatter
        formatter.dateFormat = (yearOfDate == currentYear) ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: self)
    }

    /// `"WED, MAR 15"` (or `"WED, MAR 15, 2024"` for past years).
    /// Section-header style — uppercase with weekday prefix.
    /// Pair with `SectionHeader` for the visual treatment.
    func formattedSectionDate(now: Date = Date()) -> String {
        let calendar = Calendar.current
        let yearOfDate = calendar.component(.year, from: self)
        let currentYear = calendar.component(.year, from: now)
        let formatter = Self.cachedFormatter
        // POSIX locale here so weekday/month abbreviations stay
        // English regardless of device locale — section headers
        // are visual anchors, not user-facing copy. Localise later
        // if/when the rest of the UI is localised.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = (yearOfDate == currentYear)
            ? "EEE, MMM d"
            : "EEE, MMM d, yyyy"
        let result = formatter.string(from: self).uppercased()
        // Reset locale on the shared formatter so the next caller
        // (which expects en_US) doesn't inherit POSIX.
        formatter.locale = Locale(identifier: "en_US")
        return result
    }

    /// Always-with-year `"LLLL yyyy"` — used by the Spending
    /// Calendar card's chevron header where the year matters
    /// regardless of when we are.
    func formattedMonthWithYear() -> String {
        let formatter = Self.cachedFormatter
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: self)
    }

    // MARK: - Cached formatter

    /// Single shared `DateFormatter` instance. `DateFormatter` is
    /// expensive to construct (~1ms each) and these helpers are
    /// called from view bodies that re-render often. Locale stays
    /// pinned to `en_US` because the rest of the app's UI is
    /// English-only; per-call overrides (e.g. POSIX in the section
    /// formatter) reset on exit so the shared instance is
    /// predictable for the next caller.
    private static let cachedFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        return f
    }()
}

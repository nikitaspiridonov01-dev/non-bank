import Foundation

// MARK: - Amount Formatting
//
// Helpers for the various flavours of amount display used across
// the app. Replaces the **7 inline copies** of `formatAmount(_:)`
// scattered across the Insights cards, plus the **3 copies** of
// the multiplier formatter (`if mult >= 10 { "%.0f" } else { "%.1f" }`).
//
// Composition pattern:
//   - For a single-`Text` runs (where SwiftUI needs an atomic glyph
//     run to measure natural width correctly), call
//     `formattedAmount(currency:)` to get a `String`.
//   - For multi-styled `Text` concatenations, the existing
//     `NumberFormatting.integerPart(_:)` /
//     `NumberFormatting.decimalPartIfAny(_:)` helpers remain — they
//     give per-piece control of font / colour.

extension Double {

    /// `"1 234.50 USD"` — full string with currency code appended.
    /// Mirrors the in-line `"\(int)\(dec) \(currency)"` pattern used
    /// in `BigPurchaseCard`, `CategoryCannibalizationCard`,
    /// `MonthlyTrendCard`, `SmallPurchasesCard`, `BigCategoryMonthCard`,
    /// `SpendingCalendarCard`, and `CategoryHistoryView`.
    func formattedAmount(currency: String) -> String {
        let int = NumberFormatting.integerPart(self)
        let dec = NumberFormatting.decimalPartIfAny(self)
        return "\(int)\(dec) \(currency)"
    }

    /// `"4.2"` for `< 10`, `"15"` for `≥ 10`. Used for the "× more
    /// than usual" multiplier display in extreme cards. The
    /// branching avoids fake precision on double-digit multipliers
    /// where one decimal is visual noise.
    ///
    /// Note: returns the **bare number** without the trailing `×`
    /// glyph — that's the caller's responsibility (some surfaces
    /// want `"4.2×"`, others `"× 4.2"` or just the number).
    var formattedMultiplier: String {
        if self >= 10 {
            return String(format: "%.0f", self)
        }
        return String(format: "%.1f", self)
    }

    /// `"42%"` for ≥ 1, `"<1%"` for non-zero values below 1. Used
    /// for share-of-total displays in `CategoryAmountRow`. The
    /// `<1%` collapse avoids showing `"0%"` for non-zero values
    /// (rounding to integer would otherwise zero them out).
    var formattedPercent: String {
        let pct = self * 100
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }
}

import Foundation

/// Centralized number formatting utilities.
/// Replaces duplicated integerPart/decimalPart across BalanceHeaderView, HomeView,
/// TransactionDetailView, and SearchTransactionsView.
enum NumberFormatting {

    private static let groupedFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = " "
        f.maximumFractionDigits = 0
        return f
    }()

    /// Formatted absolute integer part with space-separated groups: "1 234"
    static func integerPart(_ value: Double) -> String {
        let intPart = Int(abs(value))
        return groupedFormatter.string(from: NSNumber(value: intPart)) ?? "0"
    }

    /// Decimal part with leading dot: ".05"
    static func decimalPart(_ value: Double) -> String {
        let rounded = (abs(value) * 100).rounded() / 100
        let decimal = rounded - Double(Int(rounded))
        return String(format: ".%02d", Int((decimal * 100).rounded()))
    }

    /// Like `decimalPart` but returns an empty string when the cents are zero.
    /// E.g. 12.50 → ".50", 12.00 → "".
    static func decimalPartIfAny(_ value: Double) -> String {
        let cents = Int((abs(value) * 100).rounded()) % 100
        return cents == 0 ? "" : String(format: ".%02d", cents)
    }

    /// Balance sign: "+" for positive, "-" for negative/zero
    static func balanceSign(_ value: Double) -> String {
        if value == 0 { return "-" }
        return value > 0 ? "+" : "-"
    }

    // MARK: - Compact format
    //
    // Low-magnitude currencies (USD, EUR) typically need full precision —
    // "$24.95" reads fine in a row. Long-tail currencies (IDR, IRR,
    // LAK, LBP, VND, UZS) routinely produce 7–10-digit numbers that
    // blow out narrow row layouts. We switch to a "1.2M" / "850K"
    // compact form at >= 100 000 so amounts fit alongside the title
    // without truncating to ellipses.

    /// True when the amount is large enough that compact suffixes
    /// (K / M / B) help readability. Threshold picked so that
    /// everyday USD/EUR/RUB amounts (under 100k) still render in
    /// full, while typical IDR/IRR/VND/UZS amounts (millions) get
    /// shortened.
    static func shouldUseCompact(_ value: Double) -> Bool {
        abs(value) >= 100_000
    }

    /// Lossy "1.2M" / "12.3K" / "850" representation for narrow row
    /// contexts. One decimal place when the leading number is < 100,
    /// none when ≥ 100 (so "127K" reads as a clean integer, "12.3K"
    /// keeps the precision). Sign is preserved on the caller side via
    /// `balanceSign`; this returns absolute magnitude.
    static func compact(_ value: Double) -> String {
        let abs = abs(value)
        if abs >= 1_000_000_000 {
            return formatCompact(abs / 1_000_000_000, suffix: "B")
        }
        if abs >= 1_000_000 {
            return formatCompact(abs / 1_000_000, suffix: "M")
        }
        if abs >= 1_000 {
            return formatCompact(abs / 1_000, suffix: "K")
        }
        return groupedFormatter.string(from: NSNumber(value: Int(abs))) ?? "0"
    }

    private static func formatCompact(_ scaled: Double, suffix: String) -> String {
        // One decimal under 100 ("12.3M"), none above ("127M").
        if scaled >= 100 {
            return "\(Int(scaled.rounded()))\(suffix)"
        }
        // Trim trailing zero — "12.0M" reads worse than "12M".
        let rounded = (scaled * 10).rounded() / 10
        if rounded == rounded.rounded() {
            return "\(Int(rounded))\(suffix)"
        }
        return String(format: "%.1f%@", rounded, suffix)
    }
}

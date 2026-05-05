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
}

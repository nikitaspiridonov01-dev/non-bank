import SwiftUI

/// Reusable amount display used in transaction rows and search results.
/// Sign · integer · cents (when non-zero) · currency, matching the tight
/// `HStack(spacing: 0)` + `.padding(.leading, 3)` pattern used on the home
/// and debt screens.
struct AmountView: View {
    let amount: Double
    let isIncome: Bool
    let currency: String

    /// Long-tail currencies (IDR, IRR, VND, UZS, LBP, LAK) produce
    /// 7–10-digit numbers that don't fit alongside the transaction
    /// title in a row. We switch to a compact "1.2M IDR" / "850K UZS"
    /// form whenever the magnitude crosses the readability threshold.
    /// USD / EUR / RUB amounts under 100k still render with full
    /// precision since space isn't an issue there.
    private var useCompact: Bool { NumberFormatting.shouldUseCompact(amount) }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(isIncome ? "+" : "-")
                .font(AppFonts.rowAmountSign)
                .foregroundColor(AppColors.textSecondary)
            if useCompact {
                Text(NumberFormatting.compact(amount))
                    .font(AppFonts.rowAmountInteger)
                    .foregroundColor(AppColors.textPrimary)
            } else {
                Text(NumberFormatting.integerPart(amount))
                    .font(AppFonts.rowAmountInteger)
                    .foregroundColor(AppColors.textPrimary)
                Text(NumberFormatting.decimalPartIfAny(amount))
                    .font(AppFonts.rowAmountCurrency)
                    .foregroundColor(AppColors.textSecondary)
            }
            Text(currency)
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 3)
        }
        // Single-line guard. We deliberately don't apply
        // `minimumScaleFactor` here — SwiftUI's layout pass tends to
        // shrink the text even when there's room (it computes
        // pessimistically against the parent's `Spacer(minLength:)`).
        // Compact mode already handles wide currencies; for short
        // codes (USD / AMD / EUR) the title truncates instead, which
        // is the layout the rest of the app expects.
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

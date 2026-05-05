import SwiftUI

/// Reusable amount display used in transaction rows and search results.
/// Sign · integer · cents (when non-zero) · currency, matching the tight
/// `HStack(spacing: 0)` + `.padding(.leading, 3)` pattern used on the home
/// and debt screens.
struct AmountView: View {
    let amount: Double
    let isIncome: Bool
    let currency: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(isIncome ? "+" : "-")
                .font(AppFonts.rowAmountSign)
                .foregroundColor(AppColors.textSecondary)
            Text(NumberFormatting.integerPart(amount))
                .font(AppFonts.rowAmountInteger)
                .foregroundColor(AppColors.textPrimary)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
            Text(currency)
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 3)
        }
    }
}

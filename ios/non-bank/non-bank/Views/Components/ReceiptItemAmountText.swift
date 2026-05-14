import SwiftUI

/// Single source of truth for how a receipt-item amount renders. Splits
/// the value into three glyphs — bold integer (thousand-separated),
/// smaller decimal (omitted when whole), trailing currency code — so
/// every receipt surface (review screen, read-only sheet, transaction
/// card preview, editor inactive rows) reads as one family.
///
/// A single `Text(...)` like "1290.40" wouldn't carry thousand
/// separators or the bold-integer / muted-decimal contrast users have
/// learned to read on the home rows; this view brings the same
/// vocabulary to every receipt context.
struct ReceiptItemAmountText: View {
    let amount: Double
    let currency: String
    /// Negative-amount lines (parser-tagged or user-named "Discount") tint
    /// success-green and prepend an explicit "-" since
    /// `NumberFormatting.integerPart` strips signs.
    var isDiscount: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if isDiscount {
                Text("-")
                    .font(AppFonts.rowAmountInteger)
                    .foregroundColor(AppColors.success)
            }
            Text(NumberFormatting.integerPart(amount))
                .font(AppFonts.rowAmountInteger)
                .foregroundColor(isDiscount ? AppColors.success : AppColors.textPrimary)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(isDiscount ? AppColors.success : AppColors.textSecondary)
            Text(currency)
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 3)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

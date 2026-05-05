import SwiftUI

struct ReminderRowView: View {
    let transaction: Transaction
    let emoji: String
    let nextDateLabel: String
    let isLast: Bool
    var onTap: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    var body: some View {
        SwipeToDeleteRow(onDelete: { onDelete?() }) {
            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 14) {
                    Text(emoji)
                        .font(AppFonts.emojiMedium)
                        .frame(width: AppSizes.emojiFrame, height: AppSizes.emojiFrame)

                    VStack(alignment: .leading, spacing: AppSpacing.xs) {
                        Text(transaction.title)
                            .font(AppFonts.labelPrimary)
                            .foregroundColor(AppColors.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text(nextDateLabel)
                            .font(AppFonts.rowDescription)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)

                        HStack(spacing: 6) {
                            if transaction.isSplit {
                                Image(systemName: "person.2.fill")
                                    .font(AppFonts.iconMicro)
                                    .foregroundColor(AppColors.splitAccent)
                            }
                            if let interval = transaction.repeatInterval {
                                badgePill(
                                    icon: "repeat",
                                    text: interval.badgeLabel,
                                    color: AppColors.reminderAccent
                                )
                            }
                        }
                    }
                    .layoutPriority(0)

                    Spacer(minLength: 8)

                    HStack(alignment: .firstTextBaseline, spacing: 0) {
                        Text(transaction.isIncome ? "+" : "-")
                            .font(AppFonts.rowAmountSign)
                            .foregroundColor(AppColors.textSecondary)
                        Text(NumberFormatting.integerPart(transaction.amount))
                            .font(AppFonts.rowAmountInteger)
                            .foregroundColor(AppColors.textPrimary)
                        Text(NumberFormatting.decimalPartIfAny(transaction.amount))
                            .font(AppFonts.rowAmountCurrency)
                            .foregroundColor(AppColors.textSecondary)
                        Text(transaction.currency)
                            .font(AppFonts.rowAmountCurrency)
                            .foregroundColor(AppColors.textSecondary)
                            .padding(.leading, 3)
                    }
                    .lineLimit(1)
                    .layoutPriority(1)
                    .fixedSize(horizontal: true, vertical: false)
                }
                .padding(.vertical, AppSizes.reminderRowVerticalPadding)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .contentShape(Rectangle())
                .onTapGesture { onTap?() }

                if !isLast {
                    Divider()
                        .background(AppColors.border)
                        .padding(.leading, AppSizes.dividerLeading)
                }
            }
            // Match the Reminders screen's warm tint so rows blend in with
            // the surrounding background instead of appearing as white cards.
            // An opaque fill is still required so the red swipe-delete layer
            // stays hidden behind the row content.
            .background(AppColors.reminderBackgroundTint)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func badgePill(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(AppFonts.iconMicro)
            Text(text)
                .font(AppFonts.badgeLabel)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, AppSpacing.xxs)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }
}

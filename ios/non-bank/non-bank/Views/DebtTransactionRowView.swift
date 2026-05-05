import SwiftUI

/// Transaction row for the debt-summary and friend-detail screens.
/// Mirrors `TransactionRowView` on the left but replaces the amount column with
/// the user's personal position in the split: "You lent / You borrow / Not involved".
struct DebtTransactionRowView: View {
    let transaction: Transaction
    let emoji: String
    let isLast: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    private var position: UserTransactionPosition {
        SplitDebtService.userPosition(in: transaction)
    }

    var body: some View {
        SwipeToDeleteRow(onDelete: onDelete) {
            VStack(spacing: 0) {
                Button(action: onTap) {
                    HStack(alignment: .center, spacing: 14) {
                        Text(emoji)
                            .font(AppFonts.emojiMedium)
                            .frame(width: AppSizes.emojiFrame, height: AppSizes.emojiFrame)

                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text(transaction.title)
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textPrimary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if let desc = transaction.description, !desc.isEmpty {
                                Text(desc)
                                    .font(AppFonts.rowDescription)
                                    .foregroundColor(AppColors.textSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                            }
                            HStack(spacing: 6) {
                                if transaction.isSplit {
                                    Image(systemName: "person.2.fill")
                                        .font(AppFonts.iconMicro)
                                        .foregroundColor(AppColors.splitAccent)
                                }
                                if transaction.isRecurringChild || transaction.isRecurringParent {
                                    Image(systemName: "repeat")
                                        .font(AppFonts.iconMicro)
                                        .foregroundColor(AppColors.reminderAccent)
                                }
                            }
                        }
                        .layoutPriority(0)

                        Spacer(minLength: 8)

                        positionView
                            .layoutPriority(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .padding(.vertical, AppSizes.rowVerticalPadding)
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .contentShape(Rectangle())
                }
                .buttonStyle(PlainButtonStyle())

                if !isLast {
                    Divider()
                        .background(AppColors.border)
                        .padding(.leading, AppSizes.dividerLeading)
                }
            }
            .background(AppColors.backgroundPrimary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Position column

    @ViewBuilder
    private var positionView: some View {
        switch position {
        case .notInvolved:
            Text("Not involved")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textTertiary)
        case .lent(let amount):
            VStack(alignment: .trailing, spacing: 1) {
                Text("You lent")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
                amountRow(amount: amount)
            }
        case .borrowed(let amount):
            VStack(alignment: .trailing, spacing: 1) {
                Text("You borrow")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
                amountRow(amount: amount)
            }
        }
    }

    private func amountRow(amount: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(NumberFormatting.integerPart(amount))
                .font(AppFonts.rowAmountInteger)
                .foregroundColor(AppColors.textPrimary)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
            Text(transaction.currency)
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 3)
        }
    }
}

import SwiftUI

// MARK: - Transaction Row

struct TransactionRowView: View {
    let transaction: Transaction
    let emoji: String
    let isLast: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

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
                        
                        VStack(alignment: .trailing, spacing: 1) {
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
                            .fixedSize(horizontal: true, vertical: false)
                            if let split = transaction.splitInfo, split.totalAmount != transaction.amount {
                                Text("of \(NumberFormatting.integerPart(split.totalAmount))\(NumberFormatting.decimalPartIfAny(split.totalAmount)) \(transaction.currency)")
                                    .font(AppFonts.badgeLabel)
                                    .foregroundColor(AppColors.textTertiary)
                                    .lineLimit(1)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                        }
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
}

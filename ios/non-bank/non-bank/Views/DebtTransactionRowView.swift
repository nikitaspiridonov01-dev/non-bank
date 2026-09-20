import SwiftUI

/// Transaction row for the debt-summary and friend-detail screens.
/// Mirrors `TransactionRowView` on the left but replaces the amount column with
/// the user's position in the split: "You lent / You borrow / Not involved".
struct DebtTransactionRowView: View {
    let transaction: Transaction
    let emoji: String
    /// When set, the position column shows what moved between the user and
    /// **this friend** instead of the user's position in the transaction as
    /// a whole. Friend-scoped screens pass their friend's ID: on a dinner a
    /// third person paid for, the whole-transaction figure is what the user
    /// owes *the payer*, so rendering it under a friend's name claimed a
    /// debt that doesn't exist between them (and never added up to the
    /// balance in the header). `nil` on the all-debts list, where the
    /// whole-transaction position is the right answer.
    var counterpartyID: String? = nil
    let isLast: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    private var position: UserTransactionPosition {
        guard let counterpartyID else {
            return SplitDebtService.userPosition(in: transaction)
        }
        return SplitDebtService.userPosition(in: transaction, towards: counterpartyID)
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
                        .background(AppColors.splitBorder)
                        .padding(.leading, AppSizes.dividerLeading)
                }
            }
            // Transparent — transaction rows in the Split list sit
            // directly on the lavender page tint without their own
            // card backdrop. Cleaner read against `splitBackgroundTint`
            // and matches how Reminders list rows render.
            .background(Color.clear)
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
        case .settled:
            // Friend-scoped: mirror the wording `DebtRowView` uses for a
            // zero balance in the transaction's own breakdown card, so the
            // row and the card can't seem to disagree.
            Text(counterpartyID == nil ? "Settled" : "Balances out")
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
        // `fixedSize(horizontal:)` here mirrors the trick on the outer
        // `positionView`. Without it the HStack inherits the VStack's
        // ambient width and the currency code gets truncated to
        // "100 A…" instead of "100 AMD" — the parent `Spacer(minLength:)`
        // doesn't reserve enough room for three-letter ISO codes on
        // narrow currencies (AMD, IDR, RUB) once a long title is on
        // the other side.
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(NumberFormatting.integerPart(amount))
                .font(AppFonts.rowAmountInteger)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)
            Text(transaction.currency)
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)
                .padding(.leading, 3)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

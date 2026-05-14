import SwiftUI

struct ReminderRowView: View {
    let transaction: Transaction
    let emoji: String
    let isLast: Bool
    var onTap: (() -> Void)? = nil
    var onDelete: (() -> Void)? = nil

    /// Observed so split reminder rows redraw when the user toggles the
    /// global insights mode. Reminders themselves don't contribute to
    /// analytics aggregates, but the display rule for "what number to
    /// show in the row" is the same as for past transactions.
    @ObservedObject private var insightsSettings = InsightsSettings.shared

    /// Used to commit the per-tx insights flag flip triggered by the
    /// leading swipe. Mirrors `TransactionRowView`'s injection — keeps
    /// the action local to the row so parents don't need to thread a
    /// new callback through.
    @EnvironmentObject private var transactionStore: TransactionStore

    private var displayAmount: Double {
        transaction.displayPrimaryAmount(includePotentialExpenses: insightsSettings.includePotentialExpenses)
    }

    private var leadingSwipeAction: SwipeRowLeadingAction {
        let isExcluded = transaction.excludedFromInsights
        return SwipeRowLeadingAction(
            iconSystemName: isExcluded ? "chart.bar.xaxis" : "eye.slash",
            tint: UIColor(AppColors.splitAccent),
            onTap: {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                transactionStore.update(transaction.settingExcludedFromInsights(!isExcluded))
            }
        )
    }

    var body: some View {
        SwipeToDeleteRow(onDelete: { onDelete?() }, leadingAction: leadingSwipeAction) {
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

                    AmountView(
                        amount: displayAmount,
                        isIncome: transaction.isIncome,
                        currency: transaction.currency
                    )
                    .layoutPriority(1)
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
            // Transparent — the parent group wraps its rows in a
            // `.glassEffect(...)` container so each row sits on shared
            // iOS 26 Liquid Glass instead of carrying its own opaque
            // tint. (The danger swipe-delete layer is positioned
            // beside the row content, not behind it, so transparent
            // rows don't reveal it when not swiped.)
            .background(Color.clear)
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

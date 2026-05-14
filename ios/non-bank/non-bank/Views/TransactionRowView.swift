import SwiftUI

// MARK: - Transaction Row

struct TransactionRowView: View {
    let transaction: Transaction
    let emoji: String
    let isLast: Bool
    let onTap: () -> Void
    let onDelete: () -> Void

    /// Observed so split rows redraw with the right primary amount /
    /// subtitle the moment the user flips "Include potential expenses"
    /// in Settings. Without this the row stays on whatever the value
    /// was at last render until the next data mutation.
    @ObservedObject private var insightsSettings = InsightsSettings.shared

    /// Used to commit the per-tx insights flag flip triggered by the
    /// leading swipe action. The row owns this side-effect — every
    /// parent that hosts a row would otherwise need to pass through
    /// the same callback verbatim.
    @EnvironmentObject private var transactionStore: TransactionStore

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

    /// Amount rendered on the right side of the row. In include-potential
    /// mode for split transactions this is `myShare` (the user's real
    /// share); in legacy mode it's the stored `amount` (== `paidByMe`).
    private var displayAmount: Double {
        transaction.displayPrimaryAmount(includePotentialExpenses: insightsSettings.includePotentialExpenses)
    }

    /// Subtitle under the amount. Three cases:
    ///   - Split + new mode: always "Your share of {totalAmount}" — the
    ///     primary number is the user's share, the subtitle frames the
    ///     full purchase total.
    ///   - Split + legacy mode: "of {totalAmount}" only when the
    ///     out-of-pocket payment differs from the total (matches the
    ///     pre-feature behaviour).
    ///   - Non-split: nil.
    private var amountSubtitle: String? {
        guard let split = transaction.splitInfo else { return nil }
        // Long-tail currencies (IDR / IRR / VND / UZS) push the subtitle
        // off the row when full-precision; switch to compact at the
        // same threshold as the primary amount so the two read as a pair.
        let formattedTotal: String
        if NumberFormatting.shouldUseCompact(split.totalAmount) {
            formattedTotal = "\(NumberFormatting.compact(split.totalAmount)) \(transaction.currency)"
        } else {
            formattedTotal = "\(NumberFormatting.integerPart(split.totalAmount))\(NumberFormatting.decimalPartIfAny(split.totalAmount)) \(transaction.currency)"
        }
        if insightsSettings.includePotentialExpenses {
            return "Your share of \(formattedTotal)"
        }
        return split.totalAmount != transaction.amount ? "of \(formattedTotal)" : nil
    }

    var body: some View {
        SwipeToDeleteRow(onDelete: onDelete, leadingAction: leadingSwipeAction) {
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

                        VStack(alignment: .trailing, spacing: 2) {
                            // `AmountView` switches to a compact suffix
                            // form ("1.2M IDR") above 100k and adds a
                            // `minimumScaleFactor` to keep the title
                            // on the row instead of getting pushed out
                            // by long IDR/IRR/VND amounts. We drop the
                            // outer `fixedSize` for the same reason —
                            // the row needs to be allowed to shrink the
                            // amount instead of stealing space.
                            AmountView(
                                amount: displayAmount,
                                isIncome: transaction.isIncome,
                                currency: transaction.currency
                            )
                            if let subtitle = amountSubtitle {
                                // Sized two steps below the row
                                // description (`caption` / 14pt) so it
                                // reads as a clear subtitle rather than
                                // a sibling of the currency code above.
                                // 12pt regular gives enough contrast
                                // against the bold amount integer
                                // (19pt) and the currency strip
                                // (14pt medium) to feel like
                                // hierarchy, while staying clear of
                                // the squashed-tiny zone the old 11pt
                                // + `minimumScaleFactor(0.7)` combo
                                // produced (~8pt effective on long
                                // currencies). Truncation handles
                                // overflow instead of scaling.
                                Text(subtitle)
                                    .font(.system(size: 12, weight: .regular))
                                    .foregroundColor(AppColors.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .layoutPriority(1)
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

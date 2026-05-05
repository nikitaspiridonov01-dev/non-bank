import SwiftUI

/// "In March, you spent X on Y — Nx higher than your typical month."
///
/// Surfaces the **single category** whose total in the previous
/// fully-completed calendar month was the most-outstanding outlier
/// vs that category's prior monthly totals (last month is excluded
/// from the baseline so the comparison stays clean). Companion to
/// `BigPurchaseCard` but at the category-aggregate level instead
/// of single-transaction.
///
/// Card hides itself when no category qualifies.
struct BigCategoryMonthCard: View {

    /// Pre-computed analytics context — replaces the
    /// `transactionStore` / `categoryStore` / `currencyStore` trio
    /// + the `convert` / `emojiByCategory` boilerplate.
    let context: AnalyticsContext

    // MARK: - Derived

    private var extreme: CategoryAnalyticsService.BigCategoryMonth? {
        context.biggestCategorySumInLastMonth
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let e = extreme {
                content(for: e)
            }
        }
    }

    private func content(for e: CategoryAnalyticsService.BigCategoryMonth) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            EmojiTile(emoji: e.categoryEmoji, size: .hero, background: AppColors.insightRowFill)
            narrative(for: e)
        }
        .insightCardShell()
    }

    // MARK: - Narrative

    /// Bold sentence with **amount** and **multiplier** emphasized
    /// in the warm accent. The clause after the dash starts with
    /// "it's" so the second half reads as a follow-on observation
    /// ("…— it's 2.6× higher than your typical expenses.")
    /// rather than a fragment.
    private func narrative(for e: CategoryAnalyticsService.BigCategoryMonth) -> some View {
        let amount = formatAmount(e.total)
        let mult = formatMultiplier(e.multiplier)
        let monthName = formatMonth(e.date)

        return (
            Text("In ")
                .foregroundColor(AppColors.textPrimary)
            + Text(monthName)
                .foregroundColor(AppColors.textPrimary)
            + Text(", you spent ")
                .foregroundColor(AppColors.textPrimary)
            + Text(amount)
                .foregroundColor(AppColors.reminderAccent)
            + Text(" on ")
                .foregroundColor(AppColors.textPrimary)
            + Text(e.categoryTitle)
                .foregroundColor(AppColors.textPrimary)
            + Text(" — it's ")
                .foregroundColor(AppColors.textPrimary)
            + Text("\(mult)× higher")
                .foregroundColor(AppColors.reminderAccent)
            + Text(" than your typical expenses.")
                .foregroundColor(AppColors.textPrimary)
        )
        .font(AppFonts.titleSmall)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

    private func formatAmount(_ value: Double) -> String {
        let int = NumberFormatting.integerPart(value)
        let dec = NumberFormatting.decimalPartIfAny(value)
        return "\(int)\(dec) \(context.targetCurrency)"
    }

    private func formatMultiplier(_ mult: Double) -> String {
        if mult >= 10 {
            return String(format: "%.0f", mult)
        }
        return String(format: "%.1f", mult)
    }

    /// Year omitted when the extreme month is in the current
    /// calendar year — keeps the narrative compact ("In March")
    /// for the typical case while staying unambiguous when an
    /// older outlier surfaces ("In November 2024").
    private func formatMonth(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        let calendar = Calendar.current
        let yearOfDate = calendar.component(.year, from: date)
        let currentYear = calendar.component(.year, from: Date())
        formatter.dateFormat = (yearOfDate == currentYear) ? "LLLL" : "LLLL yyyy"
        return formatter.string(from: date)
    }
}

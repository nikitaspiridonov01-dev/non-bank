import SwiftUI

/// Generic monthly-trend narrative card. One struct, three flavours
/// (`netBalance`, `expenses`, `income`) — driven by the `kind`
/// parameter. The data extraction, threshold gates, and direction
/// semantics live in `CategoryAnalyticsService.monthlyTrend`; this
/// view is purely presentational.
///
/// Card hides itself when the trend isn't meaningful (< 2 months
/// of activity for the chosen kind, or absolute % change < 1%).
struct MonthlyTrendCard: View {

    /// Which value series to trend. Three instances of this card
    /// are rendered side-by-side on the Insights screen.
    let kind: CategoryAnalyticsService.TrendKind

    /// Pre-computed analytics context — replaces the
    /// `transactionStore` / `currencyStore` pair + the `convert`
    /// boilerplate.
    let context: AnalyticsContext

    // MARK: - Derived

    private var trend: CategoryAnalyticsService.MonthlyTrend? {
        context.monthlyTrend(kind)
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let t = trend {
                content(for: t)
            }
        }
    }

    private func content(for t: CategoryAnalyticsService.MonthlyTrend) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            narrative(for: t)
            subtitle(for: t)
        }
        .insightCardShell()
    }

    // MARK: - Narrative

    /// "On average, your <subject> is/are <direction> by <N%> per
    /// month." Direction word + percent share an accent colour
    /// driven by `isFavorable` — green when the change is good for
    /// the user (balance / income growing, expenses shrinking),
    /// warm orange otherwise.
    private func narrative(for t: CategoryAnalyticsService.MonthlyTrend) -> some View {
        let percent = String(format: "%.1f", abs(t.percentPerMonth))
        let direction = t.percentPerMonth >= 0 ? "growing" : "shrinking"
        let subjectVerb: String
        switch t.kind {
        case .netBalance: subjectVerb = "your net balance is"
        case .expenses:   subjectVerb = "your expenses are"
        case .income:     subjectVerb = "your income is"
        }
        let accent: Color = t.isFavorable ? Color.green : AppColors.reminderAccent

        return (
            Text("On average, ")
                .foregroundColor(AppColors.textPrimary)
            + Text(subjectVerb)
                .foregroundColor(AppColors.textPrimary)
            + Text(" ")
                .foregroundColor(AppColors.textPrimary)
            + Text(direction)
                .foregroundColor(accent)
            + Text(" by ")
                .foregroundColor(AppColors.textPrimary)
            + Text("\(percent)%")
                .foregroundColor(accent)
            + Text(" per month.")
                .foregroundColor(AppColors.textPrimary)
        )
        .font(AppFonts.titleSmall)
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Subtitle

    /// "Based on N months of activity." Tells the user how much
    /// data the trend is computed from — important context since
    /// a 2-month sample tells a very different story from a
    /// 14-month one.
    private func subtitle(for t: CategoryAnalyticsService.MonthlyTrend) -> some View {
        let months = t.monthsCovered
        let suffix = months == 1 ? "month" : "months"
        return Text("Based on \(months) \(suffix) of activity.")
            .font(AppFonts.caption)
            .foregroundColor(AppColors.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

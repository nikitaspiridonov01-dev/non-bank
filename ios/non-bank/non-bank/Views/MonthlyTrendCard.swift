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
    /// month." Bright orange `accent` is reserved for clickable
    /// elements; the non-clickable emphasis (direction word + the
    /// percent) uses `accentBold` (deep warm sienna) — noticeable
    /// without competing with the clickable orange CTAs elsewhere
    /// on the screen. The earlier favorable-vs-unfavorable green/red
    /// split was retired — direction is now communicated through
    /// the verbal word ("growing"/"shrinking") and a single warm
    /// emphasis colour, not through hue semantics.
    private func narrative(for t: CategoryAnalyticsService.MonthlyTrend) -> some View {
        let percent = String(format: "%.1f", abs(t.percentPerMonth))
        let direction = t.percentPerMonth >= 0 ? "growing" : "shrinking"
        let subjectVerb: String
        switch t.kind {
        case .netBalance: subjectVerb = "your net balance is"
        case .expenses:   subjectVerb = "your expenses are"
        case .income:     subjectVerb = "your income is"
        }

        let prefix: Text = Text("On average, ")
            .foregroundColor(AppColors.textPrimary)
        let subject: Text = Text(subjectVerb)
            .foregroundColor(AppColors.textPrimary)
        let gap: Text = Text(" ")
            .foregroundColor(AppColors.textPrimary)
        let directionText: Text = Text(direction)
            .foregroundColor(AppColors.accentBold)
        let by: Text = Text(" by ")
            .foregroundColor(AppColors.textPrimary)
        let percentText: Text = Text("\(percent)%")
            .foregroundColor(AppColors.accentBold)
        let suffix: Text = Text(" per month.")
            .foregroundColor(AppColors.textPrimary)

        let sentence: Text = prefix + subject + gap + directionText + by + percentText + suffix

        return sentence
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

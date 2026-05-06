import SwiftUI
import Charts

/// Per-category history screen. Pushed from any category row on the
/// Insights cards or detail screens. Shows:
///   - Header: emoji tile + category title + a one-line subtitle
///     ("Spending" / "Income"). No stat tiles — the average is
///     surfaced inside the chart itself as a horizontal rule, which
///     gives it visual context (every bar is implicitly compared
///     against the line) and saves the screen real estate that two
///     "summary stat" cards used to occupy.
///   - Bar chart: monthly totals for the last 6 months. Empty
///     months render as gaps so the x-axis stays evenly spaced.
///     A dashed `RuleMark` overlays the bars at the mean monthly
///     value, annotated with a small "avg X CUR" badge.
///   - List: same 6 months, each row showing month label, count
///     of transactions, and the monthly total. Months with no
///     activity are dimmed but still listed so the user can see
///     "nothing happened in February" at a glance.
///
/// The view does not let the user change the window — by design.
/// Insights surfaces the *period* via the cards' headlines; this
/// screen is a focused drilldown on one category over a fixed
/// rolling window.
struct CategoryHistoryView: View {

    // MARK: - Inputs

    let categoryTitle: String
    let categoryEmoji: String
    let type: TransactionType
    let accentColor: Color

    // MARK: - Environment

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var categoryStore: CategoryStore

    /// Chart window — 6 *fully completed* months. The chart excludes
    /// the in-progress current month so an early-in-the-month bar
    /// doesn't render misleadingly short next to its peers. ~55pt
    /// per bar on a typical phone keeps month labels readable.
    private static let chartMonthsToShow: Int = 6

    /// Floor for the "By month" list — the list always shows at
    /// least this many months (chart's 6 + current = 7) even when
    /// the user has only just started using the category. For
    /// longer histories the actual count is computed dynamically
    /// from the date of the first transaction (`listMonthCount`).
    private static let minListMonthsToShow: Int = chartMonthsToShow + 1

    // MARK: - Derived

    /// Built locally — pushed via `NavigationLink`, kept self-contained.
    private var analyticsContext: AnalyticsContext {
        .from(
            transactionStore: transactionStore,
            currencyStore: currencyStore,
            categoryStore: categoryStore
        )
    }

    /// History feeding the bar chart — fully completed months only.
    private var chartHistory: [CategoryAnalyticsService.MonthlyTotal] {
        analyticsContext.monthlyHistory(
            for: categoryTitle,
            type: type,
            monthCount: Self.chartMonthsToShow,
            skipCurrentMonth: true
        )
    }

    /// History feeding the "By month" list — every month from the
    /// **first transaction's month** up to and including the current
    /// (in-progress) month. Empty months in between still appear so
    /// the user can see "nothing in February" at a glance — gaps
    /// would be more disorienting than visible zeros.
    ///
    /// Floor: at least `minListMonthsToShow` rows so a brand-new
    /// category gets a familiar 7-row layout instead of just one
    /// "current month" row.
    private var listHistory: [CategoryAnalyticsService.MonthlyTotal] {
        analyticsContext.monthlyHistory(
            for: categoryTitle,
            type: type,
            monthCount: listMonthCount,
            skipCurrentMonth: false
        )
    }

    /// Number of monthly buckets the list should render. Computed
    /// from the *earliest* matching transaction (this category +
    /// this type) up to the current month. Floored at
    /// `minListMonthsToShow` so the layout stays familiar for new
    /// users who haven't built up history yet.
    private var listMonthCount: Int {
        let calendar = Calendar.current
        let firstDate = transactionStore.homeTransactions
            .filter { $0.type == type && $0.category == categoryTitle }
            .map { $0.date }
            .min()

        guard let first = firstDate else { return Self.minListMonthsToShow }

        let nowComps = calendar.dateComponents([.year, .month], from: Date())
        let firstComps = calendar.dateComponents([.year, .month], from: first)

        // (now.year - first.year) * 12 + (now.month - first.month) gives
        // the inclusive month delta; +1 to count both endpoints.
        let yearDiff = (nowComps.year ?? 0) - (firstComps.year ?? 0)
        let monthDiff = (nowComps.month ?? 0) - (firstComps.month ?? 0)
        let delta = yearDiff * 12 + monthDiff + 1

        return max(delta, Self.minListMonthsToShow)
    }

/// Simple arithmetic mean over **all** months in the chart
    /// window (zero months included). Each bar contributes equally
    /// so the `RuleMark` rendered at this y-value reads naturally
    /// as "the mean of the bars you see". The current month is
    /// excluded — same window as the chart — so a partial month
    /// doesn't drag the average down.
    private var averagePerMonth: Double {
        guard !chartHistory.isEmpty else { return 0 }
        return chartHistory.reduce(0) { $0 + $1.total } / Double(chartHistory.count)
    }

    /// True if any **chart** bucket has activity. Drives whether the
    /// chart card renders at all — when there are no completed
    /// months yet, the chart would just be empty bars, so we hide
    /// it entirely and let the list speak for the user's data
    /// (which may include only the current month).
    private var chartHasActivity: Bool {
        chartHistory.contains { $0.count > 0 }
    }

    /// True if any **list** bucket has activity (chart's window plus
    /// the current month). When false → no data anywhere → show the
    /// big empty state. Since `listHistory ⊇ chartHistory`, this is
    /// the broadest "do we have anything to show" predicate.
    private var listHasActivity: Bool {
        listHistory.contains { $0.count > 0 }
    }

    private var typeSubtitle: String {
        type == .income ? "Income history" : "Spending history"
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xxl) {
                header

                // Chart only when there's at least one *completed*
                // month with activity — otherwise the chart would
                // be a row of empty bars, which reads as "broken"
                // rather than "no data".
                if chartHasActivity {
                    chartCard
                }

                // List whenever there's any data anywhere in the
                // 7-month window (chart's 6 + current month).
                if listHasActivity {
                    monthlyList
                }

                // Big empty state only when literally nothing in
                // the past 7 months — including the current one.
                if !listHasActivity {
                    emptyState
                }

                Spacer(minLength: 32)
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.sm)
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle(categoryTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    /// Emoji tile + title + subtitle. The previous version stacked
    /// two "summary stat" cards under this row; both numbers are now
    /// inside the chart (the avg line + its annotation), which keeps
    /// the header focused on identity ("which category, which side
    /// of the ledger") and frees up vertical space.
    private var header: some View {
        HStack(spacing: 14) {
            EmojiTile(emoji: categoryEmoji, size: .hero, background: AppColors.insightRowFill)

            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(categoryTitle)
                    .font(AppFonts.heading)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)
                Text(typeSubtitle)
                    .font(AppFonts.rowDescription)
                    .foregroundColor(AppColors.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Chart

    /// Bar chart of monthly totals + a dashed `RuleMark` at the mean
    /// monthly value. The avg label lives in the **chart card title
    /// row** (not as an annotation on the rule) so it never overlaps
    /// the bars — putting it inside the plot area as `position: .top,
    /// alignment: .trailing` was visually splitting any bar that
    /// stretched into the upper-right corner.
    private var chartCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            chartTitleRow

            Chart {
                ForEach(chartHistory) { item in
                    BarMark(
                        x: .value("Month", item.date, unit: .month),
                        y: .value("Amount", item.total)
                    )
                    .foregroundStyle(accentColor.gradient)
                    .cornerRadius(4)
                }

                // Average line — only drawn when the chart window
                // actually has activity (otherwise we'd render an
                // avg of 0 pinned to the x-axis, which is just
                // clutter). Annotation is intentionally absent:
                // the avg number is rendered in the card title row
                // above instead.
                if chartHasActivity {
                    RuleMark(y: .value("Average", averagePerMonth))
                        .foregroundStyle(AppColors.textSecondary.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
            }
            .frame(height: 200)
            .chartXAxis {
                // Tick on every month so each bar gets its own label.
                // `centered: true` aligns the label to the **middle**
                // of the bar's horizontal span — without it, SwiftUI
                // Charts anchors the label at the start of the unit
                // (the 1st of the month), which left labels visibly
                // offset to the *left* of their bars.
                //
                // Year is added as a second line only on bars that
                // anchor the calendar — January (year transition)
                // and the leftmost bar (start of window) — so the
                // rest of the axis stays uncluttered while the year
                // is still always visible somewhere.
                AxisMarks(values: .stride(by: .month)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            axisLabel(for: date)
                        }
                    }
                }
            }
            .chartYAxis {
                // Leading position so the y-axis sits on the same
                // edge as the rest of the screen's content (matches
                // typical iOS reading direction).
                AxisMarks(position: .leading)
            }
        }
        .padding(AppSpacing.cardInset)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.insightCard)
        )
    }

    /// Chart card header: section label on the left, avg key on the
    /// right. Putting the avg here (rather than as an annotation
    /// inside the plot area) keeps it from overlapping bars and
    /// gives it a fixed home where the user can always read it.
    /// A small dashed-line glyph in front of the value visually ties
    /// the number to the dashed `RuleMark` rendered inside the chart.
    private var chartTitleRow: some View {
        HStack(spacing: AppSpacing.sm) {
            Text("Monthly trend")
                .font(AppFonts.footnote)
                .foregroundColor(AppColors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            Spacer()

            if chartHasActivity {
                averageInlineLabel
            }
        }
    }

    /// "▒▒▒ avg 1 234.56 USD" inline label paired with the chart's
    /// dashed average rule. The leading dashed glyph is the visual
    /// key that ties this label to the line in the chart — without
    /// it, "avg" by itself doesn't tell the user *which* visual
    /// element on the chart it labels.
    private var averageInlineLabel: some View {
        HStack(spacing: 6) {
            // Dashed-line key — same dash pattern + opacity as the
            // RuleMark in the chart so the eye links them together.
            DashedKeyLine()
                .stroke(
                    AppColors.textSecondary.opacity(0.55),
                    style: StrokeStyle(lineWidth: 1, dash: [3, 2])
                )
                .frame(width: 14, height: 1)

            (
                Text("avg ")
                    .font(AppFonts.iconSmall)
                    .foregroundColor(AppColors.textTertiary)
                + Text(NumberFormatting.integerPart(averagePerMonth))
                    .font(AppFonts.captionSmallStrong)
                    .foregroundColor(AppColors.textPrimary)
                + Text(NumberFormatting.decimalPartIfAny(averagePerMonth))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                + Text(" \(currencyStore.selectedCurrency)")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
            )
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// One x-axis label. Always shows the month abbreviation; adds a
    /// small grey year line **only** for January markers (year
    /// transitions) and for the leftmost bar in the window. Other
    /// bars stay single-line so the axis doesn't crowd itself.
    @ViewBuilder
    private func axisLabel(for date: Date) -> some View {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let firstDate = chartHistory.first?.date
        let isFirstBar = firstDate.map {
            calendar.isDate(date, equalTo: $0, toGranularity: .month)
        } ?? false
        let showYear = month == 1 || isFirstBar

        VStack(spacing: 1) {
            Text(date, format: .dateTime.month(.abbreviated))
                .font(AppFonts.badgeLabel)
                .foregroundStyle(AppColors.textSecondary)
            if showYear {
                Text(date, format: .dateTime.year(.twoDigits))
                    .font(.system(size: 9, weight: .regular))
                    .foregroundStyle(AppColors.textTertiary)
            }
        }
    }

    // MARK: - Monthly list

    /// Reverse-chronological list (newest first) so the user reads
    /// "March → February → January" top-down — matching how the home
    /// transaction list groups its date sections.
    private var monthlyList: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("By month")
                .font(AppFonts.footnote)
                .foregroundColor(AppColors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.5)

            VStack(spacing: AppSpacing.sm) {
                // Iterates `listHistory` reversed so the **current
                // (in-progress) month is at the top** of the list,
                // then last month, the month before that, …, all the
                // way back to the month of the user's first
                // transaction in this category. Empty months between
                // are still rendered (dimmed) so visible gaps don't
                // hide that the user wasn't active in those months.
                ForEach(listHistory.reversed()) { entry in
                    monthRow(entry)
                }
            }
        }
    }

    private func monthRow(_ entry: CategoryAnalyticsService.MonthlyTotal) -> some View {
        HStack(spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(entry.fullLabel)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(entry.count > 0
                        ? AppColors.textPrimary
                        : AppColors.textTertiary)
                if entry.count > 0 {
                    Text(transactionCountLabel(entry.count))
                        .font(.system(size: 12, weight: .regular))
                        .foregroundColor(AppColors.textTertiary)
                }
            }

            Spacer(minLength: 8)

            if entry.count > 0 {
                amountText(entry.total)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            } else {
                Text("—")
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            // `insightRowFill` was chosen for rows that sit INSIDE an
            // `insightCard` (where the row is one step lighter than
            // its container). Here the rows live directly on
            // `backgroundPrimary`, so that brighter cream washed out
            // against the page. `backgroundElevated` is one step
            // *darker* than the page in light mode (and one step
            // brighter in dark) — the standard card surface — so the
            // pill reads as a visible chip in both schemes. Empty
            // months keep the 0.5 opacity to stay muted.
            RoundedRectangle(cornerRadius: AppRadius.rowPill)
                .fill(AppColors.backgroundElevated)
                .opacity(entry.count > 0 ? 1.0 : 0.5)
        )
    }

    /// Single concatenated `Text` so SwiftUI measures natural width
    /// atomically — same trick as `CategoryAmountRow.amountText`.
    private func amountText(_ value: Double) -> Text {
        Text(NumberFormatting.integerPart(value))
            .font(AppFonts.rowAmountInteger)
            .foregroundColor(AppColors.textPrimary)
        + Text(NumberFormatting.decimalPartIfAny(value))
            .font(AppFonts.rowAmountCurrency)
            .foregroundColor(AppColors.textSecondary)
        + Text(" \(currencyStore.selectedCurrency)")
            .font(AppFonts.rowAmountCurrency)
            .foregroundColor(AppColors.textSecondary)
    }

    private func transactionCountLabel(_ count: Int) -> String {
        count == 1 ? "1 transaction" : "\(count) transactions"
    }

    // MARK: - Empty state

    /// Tiny horizontal line shape used as the dashed-line key next
    /// to the inline avg label. We need a `Shape` (rather than a
    /// `Rectangle`) because `StrokeStyle(dash:)` only renders dashes
    /// on a stroked path — `Rectangle().fill(...)` would render a
    /// solid bar instead. One stroke from leading to trailing midline
    /// is all the visual we need.
    private struct DashedKeyLine: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: 0, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }

    /// Shown when this category has zero matching transactions in
    /// the visible window (chart's 6 completed months + the current
    /// month). Same visual vocabulary as the other empty states on
    /// the Insights screens.
    private var emptyState: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: "calendar")
                .font(AppFonts.iconHero)
                .foregroundColor(AppColors.textTertiary)
            Text("No activity in recent months")
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textPrimary)
            Text("Older transactions in this category aren't shown on this screen.")
                .font(AppFonts.rowDescription)
                .foregroundColor(AppColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

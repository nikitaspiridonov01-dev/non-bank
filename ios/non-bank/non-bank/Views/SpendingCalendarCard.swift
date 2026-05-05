import SwiftUI

/// Heatmap-style spending calendar shown on the Insights screen.
///
/// **Two modes** controlled by the in-card segmented picker:
///   - **Month** — a calendar grid for one specific month. Each day
///     cell is a colour-coded circle whose hue runs from green (low
///     spending) through yellow to red (high). Tapping a cell pops
///     up a small bottom sheet with the date + amount in big type.
///   - **Averages** — a 31-cell grid with one cell per day-of-month.
///     Each cell shows the user's *average* spend on that day-of-
///     month across their full expense history. Days 29-31 use only
///     the months that calendrically have those days.
///
/// **Period sync** — in Month mode the displayed calendar follows
/// the shared `period` binding. Tapping the chevrons mutates
/// `period` so the other Insights cards stay in lockstep.
///
/// **Colour scale anchor** — both modes normalise to the user's
/// *all-time* maximum daily expense, so a "100 USD" day looks the
/// same red in March as in December.
///
/// **Constant height** — the month grid is padded to a full 6 weeks
/// (42 cells) regardless of how many days the actual month has.
/// Without this, switching between months of different lengths
/// makes the whole card jump 40-80pt vertically.
struct SpendingCalendarCard: View {

    /// Pre-computed analytics context — replaces the
    /// `transactionStore` / `currencyStore` pair + the `convert`
    /// boilerplate. The card calls `context.dailyExpenses(in:)` /
    /// `averageDailyByDayOfMonth` / `maxDailyExpenseEver` directly.
    let context: AnalyticsContext

    /// Shared period state from `InsightsView`. Bound so chevron
    /// navigation propagates to the other cards (`CategoryTopCard`)
    /// and vice versa.
    @Binding var period: InsightsPeriod

    /// Specific-month vs. averages-by-day-of-month.
    enum Mode: Hashable { case month, averages }
    @State private var mode: Mode = .month

    /// Identifiable wrapper so SwiftUI's `.sheet(item:)` can re-key
    /// itself when the user taps a different cell while the sheet
    /// is already presented (different `id` triggers a content
    /// swap rather than a stale presentation).
    private struct DaySelection: Identifiable, Equatable {
        let day: Int  // 1...31
        var id: Int { day }
    }

    /// Currently-presented day in the bottom sheet. Setting this to
    /// non-nil opens the sheet; nil closes it. The cell itself
    /// doesn't render any selection chrome — the sheet is the only
    /// affordance, dismissed by drag or by tapping the close button.
    @State private var presentedDay: DaySelection? = nil

    // MARK: - Layout constants

    /// Calendar grids are always rendered with 6 rows × 7 columns
    /// = 42 cells. Padding shorter months with trailing transparent
    /// cells keeps the card's height constant across navigation.
    private static let totalCellsInMonthGrid: Int = 42

    // MARK: - Derived: month resolution

    /// Calendar month the grid renders in `.month` mode.
    private var effectiveMonth: Date {
        let calendar = Calendar.current
        switch period {
        case .month(let year, let month):
            return calendar.date(from: DateComponents(year: year, month: month, day: 1))
                ?? Date()
        case .customRange(_, let to):
            return calendar.date(
                from: calendar.dateComponents([.year, .month], from: to)
            ) ?? to
        case .last3Months, .last6Months, .lastYear, .allTime:
            let now = Date()
            let prev = calendar.date(byAdding: .month, value: -1, to: now) ?? now
            return calendar.date(
                from: calendar.dateComponents([.year, .month], from: prev)
            ) ?? prev
        }
    }

    private var canNavigateNext: Bool {
        let calendar = Calendar.current
        let nextMonthComps = calendar.dateComponents(
            [.year, .month],
            from: calendar.date(byAdding: .month, value: 1, to: effectiveMonth) ?? effectiveMonth
        )
        let nowComps = calendar.dateComponents([.year, .month], from: Date())
        guard
            let ny = nextMonthComps.year, let nm = nextMonthComps.month,
            let cy = nowComps.year, let cm = nowComps.month
        else { return false }
        if ny > cy { return false }
        if ny == cy && nm > cm { return false }
        return true
    }

    // MARK: - Derived: data

    private var dailyData: [CategoryAnalyticsService.DailyExpense] {
        context.dailyExpenses(in: effectiveMonth)
    }

    private var averagesData: [CategoryAnalyticsService.DayOfMonthAverage] {
        context.averageDailyByDayOfMonth
    }

    private var allTimeMaxDaily: Double {
        context.maxDailyExpenseEver
    }

    private var averagesMax: Double {
        averagesData.map(\.average).max() ?? 0
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            headline
            modePicker

            if mode == .month {
                monthHeader
                weekdayRow
                monthGrid
            } else {
                averagesDescription
                averagesGrid
            }
        }
        .insightCardShell()
        // Reset presentation when mode flips so a stale sheet from
        // .month doesn't bleed into .averages (and vice versa).
        .onChange(of: mode) { _ in presentedDay = nil }
        .onChange(of: period) { _ in presentedDay = nil }
        .sheet(item: $presentedDay) { selection in
            daySheet(for: selection.day)
        }
    }

    // MARK: - Headline

    private var headline: some View {
        Text("On which day do you spend more?")
            .font(AppFonts.title)
            .foregroundColor(AppColors.textPrimary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Mode picker

    private var modePicker: some View {
        Picker("Mode", selection: $mode) {
            Text("Month").tag(Mode.month)
            Text("Averages").tag(Mode.averages)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Averages mode description

    private var averagesDescription: some View {
        Text("This is how much you spend on average on each day of the month, considering the entire history of spending for all months.")
            .font(AppFonts.caption)
            .foregroundColor(AppColors.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Month header

    private var monthHeader: some View {
        HStack {
            chevronButton(systemName: "chevron.left", enabled: true) {
                navigate(by: -1)
            }
            Spacer()
            Text(monthLabel(for: effectiveMonth))
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            chevronButton(systemName: "chevron.right", enabled: canNavigateNext) {
                navigate(by: 1)
            }
        }
    }

    private func chevronButton(
        systemName: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(AppFonts.captionStrong)
                .foregroundColor(enabled ? AppColors.textPrimary : AppColors.textTertiary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.small)
                        .fill(AppColors.insightRowFill)
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func navigate(by delta: Int) {
        let calendar = Calendar.current
        guard
            let target = calendar.date(byAdding: .month, value: delta, to: effectiveMonth)
        else { return }
        let comps = calendar.dateComponents([.year, .month], from: target)
        guard let y = comps.year, let m = comps.month else { return }
        period = .month(year: y, month: m)
    }

    // MARK: - Weekday row

    private var weekdayRow: some View {
        let calendar = Calendar.current
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let firstWeekday = calendar.firstWeekday
        let rotated = Array(symbols[(firstWeekday - 1)...]) + Array(symbols[..<(firstWeekday - 1)])

        return HStack(spacing: AppSpacing.xs) {
            ForEach(0..<7, id: \.self) { i in
                Text(rotated[i].uppercased())
                    .font(AppFonts.iconSmall)
                    .foregroundColor(AppColors.textTertiary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: - Month grid

    /// 7-wide LazyVGrid padded to 42 cells (6 rows). Months that
    /// span fewer rows get trailing transparent cells so the grid's
    /// total height stays constant — the card no longer jumps when
    /// navigating between months of different lengths.
    private var monthGrid: some View {
        let calendar = Calendar.current
        let firstWeekday = calendar.firstWeekday
        let monthFirst = calendar.date(
            from: calendar.dateComponents([.year, .month], from: effectiveMonth)
        ) ?? effectiveMonth
        let weekdayOfFirst = calendar.component(.weekday, from: monthFirst)
        let leadingBlanks = (weekdayOfFirst - firstWeekday + 7) % 7
        let trailingBlanks = max(
            Self.totalCellsInMonthGrid - leadingBlanks - dailyData.count,
            0
        )

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.xs), count: 7),
            spacing: 4
        ) {
            ForEach(0..<leadingBlanks, id: \.self) { _ in emptyCell }
            ForEach(dailyData) { day in
                monthCell(for: day)
            }
            ForEach(0..<trailingBlanks, id: \.self) { _ in emptyCell }
        }
    }

    private var emptyCell: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
    }

    private func monthCell(for day: CategoryAnalyticsService.DailyExpense) -> some View {
        let dayNumber = Calendar.current.component(.day, from: day.date)
        return Button {
            presentedDay = DaySelection(day: dayNumber)
        } label: {
            cellShape(
                amount: day.total,
                maxValue: allTimeMaxDaily,
                label: "\(dayNumber)"
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Averages grid

    private var averagesGrid: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: AppSpacing.xs), count: 7),
            spacing: 4
        ) {
            ForEach(averagesData) { day in
                averageCell(for: day)
            }
        }
    }

    private func averageCell(for day: CategoryAnalyticsService.DayOfMonthAverage) -> some View {
        Button {
            presentedDay = DaySelection(day: day.dayOfMonth)
        } label: {
            cellShape(
                amount: day.average,
                maxValue: averagesMax,
                label: "\(day.dayOfMonth)"
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Cell shape

    /// Square-aspect circle filled with the heatmap colour, day
    /// number centred on top. **No selection ring** — visual
    /// feedback is the bottom sheet that opens on tap, which the
    /// user dismisses with a drag or close button.
    private func cellShape(
        amount: Double,
        maxValue: Double,
        label: String
    ) -> some View {
        ZStack {
            Circle()
                .fill(heatmapColor(amount: amount, max: maxValue))
            Text(label)
                .font(AppFonts.footnote)
                .foregroundColor(textColor(forAmount: amount))
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Bottom sheet

    /// Bottom-sheet content for a tapped day. Big date + big amount
    /// — the layout the user asked for in place of the inline
    /// tooltip. Handles both modes off the same `day` Int by
    /// looking up the matching record.
    @ViewBuilder
    private func daySheet(for day: Int) -> some View {
        Group {
            switch mode {
            case .month:
                if let entry = dailyData.first(where: {
                    Calendar.current.component(.day, from: $0.date) == day
                }) {
                    monthDaySheet(entry: entry)
                } else {
                    sheetFallback(title: "Day \(day)", subtitle: nil)
                }
            case .averages:
                if let entry = averagesData.first(where: { $0.dayOfMonth == day }) {
                    averageDaySheet(entry: entry)
                } else {
                    sheetFallback(title: "Day \(day)", subtitle: nil)
                }
            }
        }
        // Small detent so the sheet feels lightweight — the user
        // gets a glance at the data without the calendar
        // disappearing entirely. Drag indicator + drag-to-dismiss
        // are the only chrome we need.
        .presentationDetents([.height(220)])
        .presentationDragIndicator(.visible)
        .presentationBackground(AppColors.backgroundElevated)
        .presentationCornerRadius(24)
    }

    /// Month-mode sheet: full date + total spend on that day.
    private func monthDaySheet(
        entry: CategoryAnalyticsService.DailyExpense
    ) -> some View {
        let cal = Calendar.current
        let dayMonth = monthDayLabel(for: entry.date)
        let year = "\(cal.component(.year, from: entry.date))"
        return sheetLayout(
            title: dayMonth,
            subtitle: year,
            amount: entry.total,
            emptyMessage: "No spending on this day"
        )
    }

    /// Averages-mode sheet: day-of-month + average spend on that day.
    private func averageDaySheet(
        entry: CategoryAnalyticsService.DayOfMonthAverage
    ) -> some View {
        let hasData = entry.monthsCounted > 0 && entry.average > 0
        return sheetLayout(
            title: "Day \(entry.dayOfMonth)",
            subtitle: hasData ? "Average across your spending history" : nil,
            amount: entry.average,
            emptyMessage: "No data yet for this day"
        )
    }

    /// Shared sheet body for both modes. Big bold title + small
    /// secondary subtitle + extra-large amount (or the empty
    /// message when amount ≤ 0).
    private func sheetLayout(
        title: String,
        subtitle: String?,
        amount: Double,
        emptyMessage: String
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                Text(title)
                    .font(AppFonts.displayMedium)
                    .foregroundColor(AppColors.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(AppFonts.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            }

            if amount > 0 {
                bigAmount(amount)
            } else {
                Text(emptyMessage)
                    .font(AppFonts.bodyLarge)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .padding(.horizontal, AppSpacing.xxl)
        .padding(.top, AppSpacing.xxl)
        .padding(.bottom, AppSpacing.xxxl)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Fallback when we can't find a record for a tapped day —
    /// shouldn't happen in practice (cells are built from the
    /// same data source the lookup queries) but keeps the sheet
    /// from showing a blank view if the data churns mid-tap.
    private func sheetFallback(title: String, subtitle: String?) -> some View {
        sheetLayout(title: title, subtitle: subtitle, amount: 0, emptyMessage: "No data")
    }

    /// Large amount display matching the home balance vocabulary —
    /// big bold integer, smaller secondary cents and currency.
    private func bigAmount(_ value: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(NumberFormatting.integerPart(value))
                .font(AppFonts.displayLarge)
                .foregroundColor(AppColors.textPrimary)
            Text(NumberFormatting.decimalPartIfAny(value))
                .font(.system(size: 20, weight: .semibold))
                .foregroundColor(AppColors.textSecondary)
            Text(context.targetCurrency)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 5)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    // MARK: - Color & formatting

    /// Heatmap colour for a given amount. 0 → muted gray; non-zero
    /// values map onto a hue gradient from green (low) through
    /// yellow (mid) to red (high). **Tones tuned for a softer
    /// palette** — earlier brighter values were reading as
    /// "rainbow" rather than "designer". Saturation/brightness
    /// pulled into a calmer range that still gives clear visual
    /// hierarchy without becoming garish.
    private func heatmapColor(amount: Double, max maxValue: Double) -> Color {
        guard amount > 0, maxValue > 0 else {
            return AppColors.insightRowFill
        }
        let normalized = min(amount / maxValue, 1.0)
        // Hue 120° = green; 0° = red. Linear ramp through 60°
        // (yellow) at the midpoint.
        let hue = (1.0 - normalized) * 120.0 / 360.0

        return Color(uiColor: UIColor { trait in
            // Calmer values across both modes — saturation around
            // 0.6 keeps colours present without screaming, and the
            // brightness band keeps them readable on either
            // background. Values picked by eye against the dark
            // `insightCard` and the equivalent light surface.
            let isDark = trait.userInterfaceStyle == .dark
            let saturation: CGFloat = isDark ? 0.62 : 0.55
            let brightness: CGFloat = isDark ? 0.72 : 0.88
            return UIColor(
                hue: CGFloat(hue),
                saturation: saturation,
                brightness: brightness,
                alpha: 1.0
            )
        })
    }

    /// Day-number label colour. `Color.primary` adapts: dark text on
    /// the bright cells (light mode), light text on the calmer cells
    /// (dark mode). Empty cells fall back to tertiary.
    private func textColor(forAmount amount: Double) -> Color {
        amount > 0 ? Color.primary.opacity(0.9) : AppColors.textTertiary
    }

    private func monthLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "LLLL yyyy"
        return formatter.string(from: date)
    }

    private func monthDayLabel(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d"
        return formatter.string(from: date)
    }
}

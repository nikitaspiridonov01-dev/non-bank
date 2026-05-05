import SwiftUI

/// Period selector for the Insights screen. Replaces the inline
/// `Menu` we were attaching to each card's headline because:
///   1. SwiftUI's `Menu` wraps its label in an internal `Button`
///      whose layout doesn't propagate `fixedSize(vertical: true)`
///      reliably — when the headline grew between selections the
///      bottom of the text got clipped during the cross-fade. A plain
///      Button + sheet sidesteps the wrapper entirely.
///   2. We need a **custom date range** option, which a flat menu
///      list can't host gracefully.
///
/// Sheet layout (top → bottom):
///   - **Custom range** — always-expanded section with two compact
///     `DatePicker`s + an "Apply" button. Sits at the top because the
///     prototype calls out custom-range as the primary affordance for
///     analytics drill-downs.
///   - **Months** — last 24 calendar months, most-recent first. Tap
///     commits + dismisses.
///
/// Tapping a month commits + dismisses immediately. The custom-range
/// form only commits when "Apply" is pressed so editing dates doesn't
/// thrash the parent screen mid-selection.
struct PeriodPickerSheet: View {

    @Binding var period: InsightsPeriod
    @Environment(\.dismiss) private var dismiss

    /// Calendar months exposed in the "Months" section. Capped at 24
    /// so even a heavy scroller can reach the bottom on a phone.
    private let recentMonths: [InsightsPeriod] = InsightsPeriod.recentMonths(count: 24)

    @State private var customFrom: Date
    @State private var customTo: Date

    init(period: Binding<InsightsPeriod>) {
        self._period = period
        // Seed the custom-range pickers with sensible defaults
        // derived from the current period — if the user is already
        // in a custom range we land on that exact range; otherwise
        // we suggest "last 30 days" so picking dates feels like a
        // light edit rather than starting from epoch.
        switch period.wrappedValue {
        case .customRange(let from, let to):
            self._customFrom = State(initialValue: from)
            self._customTo = State(initialValue: to)
        default:
            let now = Date()
            let cal = Calendar.current
            self._customFrom = State(
                initialValue: cal.date(byAdding: .day, value: -30, to: now) ?? now
            )
            self._customTo = State(initialValue: now)
        }
    }

    var body: some View {
        List {
            customRangeSection
            applyButtonSection
            monthsSection
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .dismissibleSheet(title: "Period")
    }

    // MARK: - Custom range

    /// Two `DatePicker`s in a regular section. The Apply button lives
    /// in its **own** sibling section (`applyButtonSection`) — putting
    /// the bordered-prominent Apply button in the same `Section` as
    /// the date pickers caused the trailing date row ("To") to render
    /// with a clipped baseline because the button's intrinsic height
    /// was confusing the section's row-spacing calculation.
    private var customRangeSection: some View {
        Section {
            DatePicker(
                "From",
                selection: $customFrom,
                in: ...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)

            DatePicker(
                "To",
                // Bound `to` to ≥ `from` so the user can't pick
                // an inverted range from the picker itself.
                selection: $customTo,
                in: customFrom...Date(),
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
        } header: {
            Text("Custom range")
        }
    }

    /// Apply button isolated into its own section (no header, no row
    /// chrome) so it doesn't cohabitate with the `DatePicker` rows.
    /// Inset insets are tightened to 16pt horizontal so the prominent
    /// fill aligns with the section above and doesn't pop out.
    private var applyButtonSection: some View {
        Section {
            Button {
                period = .customRange(from: customFrom, to: customTo)
                dismiss()
            } label: {
                Text("Apply custom range")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.sm)
            }
            .buttonStyle(.borderedProminent)
            .tint(AppColors.accentBold)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        }
    }

    // MARK: - Months

    private var monthsSection: some View {
        Section("Months") {
            ForEach(recentMonths, id: \.self) { p in
                presetRow(p)
            }
        }
    }

    /// Tappable row for a specific month. Dismisses the sheet
    /// immediately on tap so the parent re-renders with the new
    /// period in a single frame.
    private func presetRow(_ preset: InsightsPeriod) -> some View {
        Button {
            period = preset
            dismiss()
        } label: {
            HStack {
                Text(preset.menuLabel)
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
                if isSelected(preset) {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .font(AppFonts.captionStrong)
                }
            }
        }
    }

    /// Whether `preset` matches the currently-selected period.
    private func isSelected(_ preset: InsightsPeriod) -> Bool {
        period == preset
    }
}

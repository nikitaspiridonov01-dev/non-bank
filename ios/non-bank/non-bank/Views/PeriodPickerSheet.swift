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
///   - **Custom range** — single tappable row that drills into a
///     dedicated `CustomRangeSheet` for entering From/To dates. The
///     two date pickers + Apply button used to live inline at the top
///     of this sheet and ate ~280pt of vertical real-estate before
///     the user even saw the months list. Splitting them off keeps
///     the months section above the fold.
///   - **Months** — last 24 calendar months, most-recent first. Tap
///     commits + dismisses.
///
/// Tapping a month commits + dismisses immediately. The custom-range
/// drill-down only commits when "Apply" is pressed there, and on
/// commit it dismisses both sheets so the parent screen lands on the
/// new range in a single frame.
struct PeriodPickerSheet: View {

    @Binding var period: InsightsPeriod
    @Environment(\.dismiss) private var dismiss

    /// Calendar months exposed in the "Months" section. Capped at 24
    /// so even a heavy scroller can reach the bottom on a phone.
    private let recentMonths: [InsightsPeriod] = InsightsPeriod.recentMonths(count: 24)

    @State private var showCustomRange = false

    var body: some View {
        List {
            customRangeRow
            monthsSection
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .dismissibleSheet(title: "Period")
        .sheet(isPresented: $showCustomRange) {
            CustomRangeSheet(period: $period) {
                // Apply pressed in the inner sheet: it dismisses
                // itself; we additionally close *this* sheet so the
                // parent screen re-renders with the new range
                // immediately rather than landing back on the period
                // list with the row updated.
                dismiss()
            }
        }
    }

    // MARK: - Custom range entry

    /// Single tappable row that drills into the dedicated
    /// `CustomRangeSheet`. When the active period IS a custom range,
    /// the row's trailing detail shows the active From → To so the
    /// user can read the current selection without opening the sheet.
    private var customRangeRow: some View {
        Section {
            Button {
                showCustomRange = true
            } label: {
                HStack {
                    Text("Custom range")
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    if case .customRange(let from, let to) = period {
                        Text("\(Self.shortDate(from)) – \(Self.shortDate(to))")
                            .font(AppFonts.metaRegular)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.right")
                        .font(AppFonts.captionStrong)
                        .foregroundColor(AppColors.textTertiary)
                }
            }
        }
    }

    /// Compact "MMM d, yy" format — short enough to fit alongside the
    /// row title + chevron, distinct enough to avoid confusion with
    /// the `DatePicker`'s locale-driven format inside the inner sheet.
    private static func shortDate(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, yy"
        return f.string(from: d)
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

/// Bottom-sheet drill-down for entering a custom From/To date range.
/// Hosted as a `.sheet` from `PeriodPickerSheet` (and only there) —
/// keeping it in the same file because the two views share the
/// `InsightsPeriod.customRange(from:to:)` contract and live and die
/// together.
private struct CustomRangeSheet: View {
    @Binding var period: InsightsPeriod
    /// Fired AFTER the inner sheet has updated `period` and dismissed
    /// itself. The caller uses this to also dismiss the outer
    /// `PeriodPickerSheet` so applying lands the user back on their
    /// original screen instead of the period list.
    let onApply: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var customFrom: Date
    @State private var customTo: Date

    init(period: Binding<InsightsPeriod>, onApply: @escaping () -> Void) {
        self._period = period
        self.onApply = onApply
        // Seed pickers from the active period — if it's already a
        // custom range we land on those exact bounds; otherwise we
        // suggest "last 30 days" so picking feels like a light edit
        // rather than starting from epoch.
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
            // Two `DatePicker`s in a regular section. The Apply
            // button lives in its **own** sibling section so the
            // bordered-prominent button doesn't confuse the row-
            // spacing calculation that previously clipped the "To"
            // row's baseline.
            //
            // `.tint(accentBold)` re-paints the compact pill with
            // the warm app accent — the iOS-default `secondarySystemFill`
            // pill on top of `backgroundElevated` was a low-contrast
            // gray-on-cream stack.
            Section {
                // `listRowBackground(backgroundElevated)` overrides the
                // default `secondarySystemBackground` (cool gray) that
                // `insetGrouped` paints behind each row. On the cream
                // page that gray read as "too dark" — `backgroundElevated`
                // is the warm-cream card token used by the rest of the
                // app's sheets.
                DatePicker(
                    "From",
                    selection: $customFrom,
                    in: ...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .tint(AppColors.accentBold)
                .listRowBackground(AppColors.backgroundElevated)

                DatePicker(
                    "To",
                    // Bound to ≥ `from` so the user can't pick an
                    // inverted range from the picker itself.
                    selection: $customTo,
                    in: customFrom...Date(),
                    displayedComponents: .date
                )
                .datePickerStyle(.compact)
                .tint(AppColors.accentBold)
                .listRowBackground(AppColors.backgroundElevated)
            }

            Section {
                Button {
                    period = .customRange(from: customFrom, to: customTo)
                    dismiss()
                    onApply()
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
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .dismissibleSheet(title: "Custom range")
        .presentationDetents([.medium])
    }
}

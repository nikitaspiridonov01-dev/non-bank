import SwiftUI

/// Horizontal period filter buttons displayed below the trend chart.
///
/// Layout: filters pinned to the **leading** edge in the user-friendly
/// "broadest first" order (`All time → 1D → 1W → 1M → 1Y`), Insights
/// pinned to the **trailing** edge with a flexible `Spacer` between
/// them. Result on a typical phone width:
///
///     [All time] [1D] [1W] [1M] [1Y] ………………… [Insights]
///
/// **Edge alignment** — uses a fixed 16pt horizontal inset matching
/// the standard `.padding(.horizontal, AppSpacing.pageHorizontal)` used by the rest of the
/// home screen content (quick filters, transaction rows). Same
/// inset is applied to the trend chart in `BalanceHeaderView`, so
/// "All time" sits exactly under the chart's leading edge and
/// "Insights" exactly under the trailing edge.
///
/// "Insights" is **not** a filter — it triggers `onInsightsTap` which
/// opens the analytics sheet — and lives on its own at the trailing
/// edge to read as a distinct call-to-action rather than a sibling
/// time-period.
struct PeriodPickerBar: View {
    @Binding var dateFilter: DateFilterType

    /// Fired when the user taps "Insights". Passing this in (rather
    /// than presenting a sheet from inside the bar) keeps the bar
    /// reusable and lets `HomeView` own the sheet binding alongside
    /// its other modal state.
    let onInsightsTap: () -> Void

    /// Display order — broadest period first, then narrowing down.
    /// Reads left-to-right as "All time, today, this week, this
    /// month, this year".
    private let filters: [DateFilterType] = [.all, .today, .week, .month, .year]

    var body: some View {
        HStack(spacing: 0) {
            filterGroup
            Spacer(minLength: 16)
            insightsButton
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Filter group
    //
    // Each filter pill gets a Liquid Glass capsule **only when
    // selected** — the iOS 26 segmented-control pattern. Inactive
    // labels stay flat / dim; the selected one pops out as a small
    // glass pill.

    private var filterGroup: some View {
        HStack(spacing: AppSpacing.sm) {
            ForEach(filters) { filter in
                Button {
                    dateFilter = filter
                } label: {
                    filterLabel(for: filter)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private func filterLabel(for filter: DateFilterType) -> some View {
        let isSelected = dateFilter == filter
        let base = Text(filter.shortLabel)
            .font(AppFonts.metaText)
            .foregroundColor(isSelected ? AppColors.textPrimary : AppColors.textTertiary)
            .opacity(isSelected ? 1.0 : 0.6)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 4)

        if isSelected {
            base.glassEffect(.regular, in: .capsule)
        } else {
            base
        }
    }

    // MARK: - Insights CTA
    //
    // Always-on glass capsule because Insights is a constant CTA, not
    // a toggle. `textTertiary` keeps it visually quieter than the
    // active filter (which uses `textPrimary`).

    private var insightsButton: some View {
        Button(action: onInsightsTap) {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "chart.bar.xaxis")
                    .font(AppFonts.micro)
                Text("Insights")
                    .font(AppFonts.metaText)
            }
            .foregroundColor(AppColors.textTertiary)
            .padding(.horizontal, AppSpacing.sm)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}

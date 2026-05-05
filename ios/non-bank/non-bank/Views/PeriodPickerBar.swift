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
            // Filter group — its own HStack so the inter-button
            // spacing (20pt) is independent from the spacer between
            // filters and Insights.
            HStack(spacing: AppSpacing.xl) {
                ForEach(filters) { filter in
                    Button {
                        dateFilter = filter
                    } label: {
                        Text(filter.shortLabel)
                            .font(AppFonts.metaText)
                            .foregroundColor(dateFilter == filter ? AppColors.textPrimary : AppColors.textTertiary)
                            .opacity(dateFilter == filter ? 1.0 : 0.6)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Push Insights to the trailing edge regardless of how
            // wide the filter group renders.
            Spacer(minLength: 16)

            // Insights — opens the analytics screen. Reads as a muted
            // secondary action via a soft chip background that picks
            // up a subtle accent tint, with `textSecondary` for legibility
            // in both themes (in dark mode the `textTertiary` text on a
            // black background reads as washed-out and easy to miss).
            Button(action: onInsightsTap) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(AppFonts.micro)
                    Text("Insights")
                        .font(AppFonts.metaText)
                }
                .foregroundColor(AppColors.textSecondary)
                .padding(.horizontal, AppSpacing.sm)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(AppColors.backgroundChipSoft)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }
}

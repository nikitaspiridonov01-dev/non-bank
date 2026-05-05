import SwiftUI

/// Insight card preview. Large headline question with the period
/// rendered as an accent-coloured tappable element (single tap →
/// `PeriodPickerSheet`), then a stack of up to `collapsedLimit`
/// `CategoryAmountRow`s, then a "See all (n) →" `NavigationLink` that
/// pushes the full-screen `InsightsDetailView`.
///
/// The card is intentionally agnostic about *what kind* of total it
/// shows — caller picks the headline prefix, accent colour, and
/// destination view. Same shell is used for both "Top spending" and
/// "Top earning" cards on the Insights screen.
///
/// **Why Button + sheet, not Menu?** SwiftUI's `Menu` wraps its label
/// in an internal Button container that doesn't reliably propagate
/// `fixedSize(vertical: true)` — when the headline grew between
/// selections (e.g. "March 2026" → "the last 6 months") the bottom
/// of the wrapped text got clipped during the cross-fade. A plain
/// `Button` triggering a sheet sidesteps the wrapper entirely so
/// the headline always lays out at full intrinsic height. The sheet
/// also lets us host a custom date-range form, which a menu can't.
struct CategoryTopCard<Destination: View>: View {

    /// Pre-question fragment, e.g. "Where did you spend the most money in".
    /// The current period is appended as accent-coloured text inside
    /// a `Button`, followed by a "?".
    let questionPrefix: String

    /// Sorted rows from `CategoryAnalyticsService.topCategories`.
    /// Already pre-sorted; the card never re-sorts.
    let categories: [CategoryAnalyticsService.CategoryTotal]

    /// ISO currency code shown next to each amount.
    let currency: String

    /// Which side of the ledger this card aggregates. Forwarded to
    /// `CategoryHistoryView` so each row's drill-down only shows
    /// transactions of the matching type (a category can in theory
    /// appear on both sides; tapping a row on the *spending* card
    /// should never surface income drilldowns).
    let type: TransactionType

    /// Tints the period text in the headline + the "See all" button.
    let accentColor: Color

    /// Two-way binding to the parent's period state. The headline tap
    /// opens a sheet that mutates this binding directly, so changes
    /// propagate to both cards (and the detail view) without any
    /// callback plumbing.
    @Binding var period: InsightsPeriod

    /// Builder for the destination shown when the user taps "See all".
    /// Generic over `Destination` so callers can pass any view type
    /// without going through `AnyView`.
    @ViewBuilder let detailDestination: () -> Destination

    /// Number of rows shown in the preview before the "See all"
    /// button appears. Matches the "TOP-3" the spec called out.
    private static var collapsedLimit: Int { 3 }

    @State private var showPeriodPicker: Bool = false

    private var visibleRows: [CategoryAnalyticsService.CategoryTotal] {
        Array(categories.prefix(Self.collapsedLimit))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.lg) {
            headline

            if categories.isEmpty {
                emptyContent
            } else {
                rowsList
                if categories.count > Self.collapsedLimit {
                    seeAllLink
                }
            }
        }
        .insightCardShell()
        .sheet(isPresented: $showPeriodPicker) {
            PeriodPickerSheet(period: $period)
        }
    }

    // MARK: - Headline

    /// "Where did you spend the most money in **March 2026**?". A
    /// single concatenated `Text` (with the period segment in the
    /// accent colour) wrapped in a plain `Button` that opens the
    /// period sheet — no `Menu`, no internal wrapper, full layout
    /// stability across period switches.
    ///
    /// `fixedSize(horizontal: false, vertical: true)` forces the text
    /// to render at its full intrinsic height regardless of any
    /// container animation, preventing the clipping that the
    /// `Menu`-wrapped version exhibited.
    private var headline: some View {
        Button {
            showPeriodPicker = true
        } label: {
            (
                Text("\(questionPrefix) ")
                    .foregroundColor(AppColors.textPrimary)
                +
                Text(period.headline())
                    .foregroundColor(accentColor)
                +
                Text("?")
                    .foregroundColor(AppColors.textPrimary)
            )
            .font(AppFonts.title)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        // Disable any inherited animation on the text content itself
        // so subsequent period changes flip the text instantly rather
        // than crossfading mid-layout. The sheet open/close still
        // animates as usual.
        .transaction { $0.animation = nil }
    }

    // MARK: - Rows

    /// Rows are wrapped in `NavigationLink` so each pill is tappable
    /// → pushes `CategoryHistoryView` for that category. `.plain`
    /// button style preserves the row's original look (no chevron,
    /// no highlight tint).
    private var rowsList: some View {
        VStack(spacing: 10) {
            ForEach(visibleRows) { row in
                NavigationLink {
                    CategoryHistoryView(
                        categoryTitle: row.category,
                        categoryEmoji: row.emoji,
                        type: type,
                        accentColor: accentColor
                    )
                } label: {
                    CategoryAmountRow(row: row, currency: currency)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - See all link

    /// `NavigationLink` shown when there are more categories than the
    /// preview limit. Pushes the supplied `detailDestination` onto
    /// the parent's `NavigationStack`.
    private var seeAllLink: some View {
        NavigationLink {
            detailDestination()
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Text("See all \(categories.count)")
                    .font(AppFonts.captionStrong)
                Image(systemName: "arrow.right")
                    .font(AppFonts.micro)
            }
            .foregroundColor(accentColor)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    /// Compact empty state — same row-pill style as a real row so
    /// the layout stays consistent when the user picks a period that
    /// has no transactions.
    private var emptyContent: some View {
        EmptyStateView(systemImage: "tray", title: "No data for this period", size: .compact)
            .rowPill(verticalPadding: 14)
    }
}

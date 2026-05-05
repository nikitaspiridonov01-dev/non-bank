import SwiftUI

/// Full-screen "see all categories" view pushed when the user taps
/// the "See all" link on an Insights card. Same headline as the
/// parent card (with the period still tappable to change) plus
/// every category for the chosen `type` — no top-N preview.
///
/// State is **synced with the parent** via the `period` binding so
/// changing the period here also updates the parent cards. The
/// detail view **recomputes its own category list** rather than
/// receiving a snapshot — otherwise switching the period via the
/// headline here would leave the rows stale until the user popped
/// back and re-tapped "See all".
struct InsightsDetailView: View {

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore

    /// Navbar title — short, e.g. "Top spending" / "Top earning".
    let navTitle: String

    /// Pre-question fragment for the headline.
    let questionPrefix: String

    /// Which side of the ledger this detail view aggregates.
    let type: TransactionType

    /// Tints the period text in the headline.
    let accentColor: Color

    /// Two-way binding to the parent's period state. Updates flow
    /// back so both the card preview and this screen always agree.
    @Binding var period: InsightsPeriod

    @State private var showPeriodPicker: Bool = false

    // MARK: - Derived

    /// Built locally rather than passed in because this screen is
    /// pushed via `NavigationLink` and stays self-contained — the
    /// env objects we declare above are already available, and
    /// rebuilding the context per render is cheap (a couple of
    /// closure captures + a small dictionary).
    private var analyticsContext: AnalyticsContext {
        .from(
            transactionStore: transactionStore,
            currencyStore: currencyStore,
            categoryStore: categoryStore
        )
    }

    private var categories: [CategoryAnalyticsService.CategoryTotal] {
        analyticsContext.filtered(by: period).topCategories(type: type)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                headline
                    .padding(.horizontal, AppSpacing.xl)
                    .padding(.top, AppSpacing.sm)

                if categories.isEmpty {
                    emptyContent
                        .padding(.horizontal, AppSpacing.xl)
                } else {
                    categoryList
                        .padding(.horizontal, AppSpacing.xl)
                }

                Spacer(minLength: 32)
            }
            .padding(.bottom, AppSpacing.xxl)
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle(navTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showPeriodPicker) {
            PeriodPickerSheet(period: $period)
        }
    }

    // MARK: - Headline

    /// Identical to `CategoryTopCard.headline` — same Button + sheet
    /// pattern so the detail screen's headline behaves predictably
    /// when the user changes period from here.
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
        .transaction { $0.animation = nil }
    }

    // MARK: - Category list

    /// Rows are wrapped in `NavigationLink` so each pill is tappable
    /// → pushes `CategoryHistoryView` for that category. Same
    /// `.plain` button style as the preview card so the row still
    /// reads as a chip rather than a system-styled list cell.
    private var categoryList: some View {
        VStack(spacing: 10) {
            ForEach(categories) { row in
                NavigationLink {
                    CategoryHistoryView(
                        categoryTitle: row.category,
                        categoryEmoji: row.emoji,
                        type: type,
                        accentColor: accentColor
                    )
                } label: {
                    CategoryAmountRow(row: row, currency: currencyStore.selectedCurrency)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    /// Same row-pill empty state as the card so the visual continuity
    /// is preserved when the user opens detail for a period with no
    /// transactions of this type.
    private var emptyContent: some View {
        EmptyStateView(systemImage: "tray", title: "No data for this period", size: .compact)
            .rowPill(verticalPadding: 14)
    }
}

import SwiftUI

/// One row inside an Insights card / detail screen. Renders an emoji
/// tile, the category name (up to 3 lines), and a right-aligned
/// amount with the per-category share-of-total below.
///
/// Extracted into its own component so the preview card
/// (`CategoryTopCard`) and the full-list screen (`InsightsDetailView`)
/// stay visually identical without duplicating row code.
///
/// **Layout strategy** — the right-hand amount column is the priority
/// element: it claims its natural width first via
/// `layoutPriority(1) + fixedSize(horizontal: true, vertical: false)`.
/// The category text on the left then fills whatever's left via
/// `frame(maxWidth: .infinity, alignment: .leading)` and wraps to up
/// to three lines. We deliberately use a **single concatenated Text**
/// for the amount rather than three sibling Texts in an HStack,
/// because the HStack-of-Texts version reported a slightly smaller
/// natural width than what it actually rendered (SwiftUI's per-child
/// width measurement plus the inter-child padding came up short by
/// ~4pt) and clipped the trailing currency code as "151.81 U…" even
/// when the row had ample room.
///
/// The amount style (digit + cents + currency, secondary tone for
/// the trailing pieces) mirrors `AmountView` / `TransactionRowView`
/// so analytics rows feel like the rest of the app's vocabulary. We
/// drop the +/- sign because category aggregates aren't signed.
struct CategoryAmountRow: View {
    let row: CategoryAnalyticsService.CategoryTotal
    let currency: String

    var body: some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            emojiTile

            Text(row.category)
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 1) {
                amountText
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                percentageText
                    .fixedSize(horizontal: true, vertical: false)
            }
            .layoutPriority(1)
            .fixedSize(horizontal: true, vertical: false)
        }
        .rowPill()
    }

    // MARK: - Emoji tile

    /// Slightly lighter chip behind the emoji so it stands out from
    /// the row pill (which already sits on the dark insight card).
    private var emojiTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(AppColors.backgroundChip)
            Text(row.emoji)
                .font(.system(size: 20))
        }
        .frame(width: 38, height: 38)
    }

    // MARK: - Amount

    /// Single concatenated `Text` so SwiftUI measures the natural
    /// width as one atomic glyph run. Mirrors `AmountView` typography
    /// (large bold integer, smaller secondary cents + currency code)
    /// and uses a literal leading space before the currency to match
    /// the visual gap that `AmountView` achieves with `.padding(.leading, 3)`
    /// — within a single `Text` we can't apply view padding between
    /// runs, but a regular space at this font weight reads identically.
    private var amountText: Text {
        Text(NumberFormatting.integerPart(row.total))
            .font(AppFonts.rowAmountInteger)
            .foregroundColor(AppColors.textPrimary)
        + Text(NumberFormatting.decimalPartIfAny(row.total))
            .font(AppFonts.rowAmountCurrency)
            .foregroundColor(AppColors.textSecondary)
        + Text(" \(currency)")
            .font(AppFonts.rowAmountCurrency)
            .foregroundColor(AppColors.textSecondary)
    }

    // MARK: - Percentage

    /// Share of total expressed as a percentage. Tertiary text so it
    /// reads as supplementary metadata rather than competing with
    /// the primary amount.
    private var percentageText: some View {
        Text(Self.formatPercent(row.share))
            .font(AppFonts.badgeLabel)
            .foregroundColor(AppColors.textTertiary)
            .monospacedDigit()
    }

    /// Format a 0…1 share as a "42%" string. Sub-1% shares collapse
    /// to "<1%" so an integer rounding doesn't display "0%" for
    /// nonzero values (otherwise users would think the row was
    /// counted twice or that the math was wrong).
    static func formatPercent(_ share: Double) -> String {
        let pct = share * 100
        if pct > 0 && pct < 1 { return "<1%" }
        return "\(Int(pct.rounded()))%"
    }
}

import SwiftUI

// MARK: - Tappable Row Pill
//
// Replaces the 6+ inline copies of:
//
//     .padding(.horizontal, 14)
//     .padding(.vertical, 12)
//     .frame(maxWidth: .infinity, alignment: .leading)
//     .background(
//         RoundedRectangle(cornerRadius: 14)
//             .fill(AppColors.insightRowFill)
//     )
//
// found in `CategoryAmountRow`, `BigPurchaseCard`, `SmallExpensesListView`,
// `SmallPurchasesCard` (CTA), monthly rows in `CategoryHistoryView`,
// debt rows in `DebtSummaryView`, etc.
//
// Usage:
//
//     Button { onTap() } label: {
//         HStack { ... row content ... }
//             .rowPill()
//     }
//     .buttonStyle(.plain)
//
// `fill` and `radius` are tweakable but default to the standard
// Insights-card vocabulary (`insightRowFill`, 14pt corner radius).

struct RowPillModifier: ViewModifier {
    let fill: Color
    let radius: CGFloat
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(fill)
            )
    }
}

extension View {
    /// Wraps the receiver in the standard tappable row-pill chrome:
    /// horizontal/vertical padding, full-width leading-aligned frame,
    /// rounded `insightRowFill` background.
    ///
    /// Defaults match the existing Insights row-pill pattern (14pt
    /// horizontal, 12pt vertical, 14pt corner radius). Override any
    /// argument to alter the look without escaping the modifier.
    func rowPill(
        fill: Color = AppColors.insightRowFill,
        radius: CGFloat = AppRadius.rowPill,
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = AppSpacing.rowVertical
    ) -> some View {
        modifier(RowPillModifier(
            fill: fill,
            radius: radius,
            horizontalPadding: horizontalPadding,
            verticalPadding: verticalPadding
        ))
    }
}

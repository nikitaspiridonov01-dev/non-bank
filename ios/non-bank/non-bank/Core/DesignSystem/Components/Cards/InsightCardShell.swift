import SwiftUI

// MARK: - Insight Card Shell
//
// View modifier replacing the 8-fold duplication of:
//
//     .padding(20)
//     .background(AppColors.insightCard)
//     .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
//
// found inline in `BigPurchaseCard`, `BigCategoryMonthCard`,
// `CategoryTopCard`, `CategoryCannibalizationCard`, `MonthlyTrendCard`,
// `SmallPurchasesCard`, `SpendingCalendarCard`, and the chart card
// inside `CategoryHistoryView`.
//
// Usage:
//
//     VStack(alignment: .leading, spacing: 12) {
//         narrative
//         subtitle
//     }
//     .insightCardShell()
//
// Tweak `padding` to override the default `AppSpacing.cardInset` (20pt)
// when a card needs tighter / looser internal spacing.

struct InsightCardShell: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppColors.insightCard)
            .clipShape(RoundedRectangle(cornerRadius: AppRadius.card))
    }
}

extension View {
    /// Wraps the receiver in the standard Insights-card chrome:
    /// `padding(20)` + `insightCard` background + `card` corner
    /// radius. The default 20pt inset matches `AppSpacing.cardInset`.
    func insightCardShell(padding: CGFloat = AppSpacing.cardInset) -> some View {
        modifier(InsightCardShell(padding: padding))
    }
}

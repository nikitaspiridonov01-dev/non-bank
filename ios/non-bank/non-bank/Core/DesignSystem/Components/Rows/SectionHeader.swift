import SwiftUI

// MARK: - Section Header
//
// Bold uppercase tracking pattern used across the app for list /
// scroll section dividers. Replaces the 5+ inline copies of:
//
//     Text("Top earning categories")
//         .font(.system(size: 13, weight: .semibold))
//         .foregroundColor(AppColors.textTertiary)
//         .textCase(.uppercase)
//         .tracking(0.5)
//
// found in `CategoryHistoryView` (3 instances), `SmallExpensesListView`,
// `DebtSummaryView`, etc.
//
// Usage:
//
//     SectionHeader(text: "Monthly trend")
//
//     // Or inside a card with custom colour:
//     SectionHeader(text: "By month", color: AppColors.textSecondary)

struct SectionHeader: View {

    /// Display text. Will be uppercased automatically via
    /// `.textCase(.uppercase)` so callers pass natural-case strings.
    let text: String

    /// Tint for the label. Defaults to `textTertiary` (secondary
    /// emphasis). Use `textSecondary` when the section header sits
    /// against a tinted card background and needs more contrast.
    var color: Color = AppColors.textTertiary

    var body: some View {
        Text(text)
            .font(AppFonts.sectionHeader)
            .foregroundColor(color)
            .tracking(AppFonts.sectionHeaderTracking)
            .textCase(.uppercase)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

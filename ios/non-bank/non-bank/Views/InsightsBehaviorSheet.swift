import SwiftUI

/// Modal sheet for the "Insights and analytics" settings row. Lets the
/// user pick between counting their real share (default) and counting
/// only what they paid out of pocket. Includes a side-by-side example
/// so the difference is concrete rather than abstract.
///
/// The toggle drives `InsightsSettings.shared.includePotentialExpenses`
/// directly — every analytics surface observes that publisher and
/// re-renders the moment the user flips it.
struct InsightsBehaviorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var insightsSettings = InsightsSettings.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    headerSection
                    toggleCard
                    exampleSection
                    Spacer().frame(height: AppSpacing.xl)
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.lg)
            }
            .background(AppColors.backgroundPrimary)
            // No navigation title — the in-content header is enough,
            // and a duplicate title in the toolbar made the sheet feel
            // top-heavy. Just the Done button stays in the toolbar.
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(16)
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(AppColors.splitAccent)
            Text("Potential expenses and debts")
                .font(.title3).bold()
                .foregroundColor(AppColors.textPrimary)
            Text("In a split, some money is owed but hasn't moved yet — by you or by a friend. Choose whether those potential amounts count in your totals.")
                .font(.body)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toggleCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Toggle(isOn: $insightsSettings.includePotentialExpenses) {
                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Include potential expenses and debts")
                        .font(AppFonts.body)
                        .foregroundColor(AppColors.textPrimary)
                    Text(insightsSettings.includePotentialExpenses
                         ? "Counted by your share — including what's still owed."
                         : "Counted only by what actually moved.")
                        .font(AppFonts.metaText)
                        .foregroundColor(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .tint(AppColors.splitAccent)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }

    /// Two static cards, one per mode. Each card shows both
    /// canonical scenarios (lent / borrow) so the user can compare
    /// the two modes side-by-side without flipping the toggle.
    /// Static by design — the user asked for stable examples that
    /// don't morph as they tap the switch.
    private var exampleSection: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text("Examples")
                .font(.subheadline)
                .foregroundColor(AppColors.textSecondary)
            modeExampleCard(
                modeLabel: "Including potential expenses and debts",
                scenarios: [
                    ("You paid 1100, your share 800", "Counts as 800"),
                    ("Friend paid 3200, your share 1500", "Counts as 1500")
                ]
            )
            modeExampleCard(
                modeLabel: "Excluding potential expenses and debts",
                scenarios: [
                    ("You paid 1100, your share 800", "Counts as 1100"),
                    ("Friend paid 3200, your share 1500", "Counts as 0")
                ]
            )
        }
    }

    private func modeExampleCard(
        modeLabel: String,
        scenarios: [(String, String)]
    ) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            Text(modeLabel)
                .font(AppFonts.bodySmallEmphasized)
                .foregroundColor(AppColors.textPrimary)
            VStack(alignment: .leading, spacing: AppSpacing.sm) {
                ForEach(Array(scenarios.enumerated()), id: \.offset) { _, scenario in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.0)
                            .font(AppFonts.metaText)
                            .foregroundColor(AppColors.textSecondary)
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "arrow.right")
                                .font(AppFonts.iconSmall)
                                .foregroundColor(AppColors.textTertiary)
                            Text(scenario.1)
                                .font(AppFonts.bodySmallEmphasized)
                                .foregroundColor(AppColors.textPrimary)
                        }
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }
}

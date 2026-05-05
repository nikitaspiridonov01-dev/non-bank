import SwiftUI

// MARK: - Empty State View
//
// Standardised empty / "no data" placeholder. Replaces the 9 ad-hoc
// implementations scattered across `InsightsView`, `CategoryTopCard`
// (compact-in-pill variant), `InsightsDetailView`, `CategoryHistoryView`,
// `FriendsView`, `FriendPickerView`, `ReceiptReviewView`, `HomeView`
// (search empty), and `FilterSheetView`.
//
// Three size variants cover the actual range of usage:
// - `.compact` — single-line text + small icon, fits inside a pill
//   row (used for "No data for this period" inside Insights cards).
// - `.full`    — centered icon + title (+ optional description),
//   for empty-list screens (FriendsView, ReceiptReviewView).
// - `.page`    — large icon + title + description + optional
//   action button, for whole-screen empty states (`InsightsView`'s
//   "Nothing to analyse yet").
//
// Usage:
//
//     // Compact, in a pill:
//     EmptyStateView(systemImage: "tray", title: "No data for this period",
//                    size: .compact)
//         .rowPill()
//
//     // Full-screen with CTA:
//     EmptyStateView(
//         systemImage: "chart.bar.xaxis",
//         title: "Nothing to analyse yet",
//         description: "Add a transaction to start seeing insights here.",
//         size: .page,
//         action: .init(title: "Add transaction") { showCreate = true }
//     )

struct EmptyStateView: View {

    enum Size: Equatable {
        /// In-line empty state — small icon + label, side-by-side.
        /// Drop into a pill row for "No data" placeholders.
        case compact
        /// Centered, vertical layout — list-screen empty states.
        case full
        /// Large hero variant — whole-screen empty states with
        /// optional action button.
        case page
    }

    /// Optional CTA at the bottom of `.page` variant. Ignored on
    /// `.compact` and `.full` (those have no action slot by design
    /// — keep the visual hierarchy of the screen, not the empty
    /// state, owning the user's primary action).
    struct ActionConfig {
        let title: String
        let action: () -> Void
    }

    let systemImage: String
    let title: String
    var description: String? = nil
    var size: Size = .full
    var action: ActionConfig? = nil

    var body: some View {
        switch size {
        case .compact: compactBody
        case .full:    fullBody
        case .page:    pageBody
        }
    }

    // MARK: - Variants

    /// Inline: icon + title on one HStack row. Tertiary tone
    /// throughout — empty states are by definition de-emphasized
    /// content.
    private var compactBody: some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .light))
                .foregroundColor(AppColors.textTertiary)
            Text(title)
                .font(AppFonts.caption)
                .foregroundColor(AppColors.textTertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// Centered icon + title (+ optional description). Reserves
    /// vertical room (`padding(.vertical, 32)`) so the empty
    /// state has presence inside an otherwise empty screen.
    private var fullBody: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(AppColors.textTertiary)
            Text(title)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textSecondary)
            if let description {
                Text(description)
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxxl)
    }

    /// Hero — bigger icon, optional CTA button. Use for
    /// whole-screen empty states ("you have no data yet").
    private var pageBody: some View {
        VStack(spacing: AppSpacing.md) {
            Image(systemName: systemImage)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(AppColors.textTertiary)
            Text(title)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
            if let description {
                Text(description)
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xxl)
            }
            if let action {
                Button(action: action.action) {
                    Text(action.title)
                        .font(AppFonts.bodySmall)
                        .foregroundColor(AppColors.accent)
                        .padding(.top, AppSpacing.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

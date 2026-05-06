import SwiftUI

// MARK: - Empty Transactions View
//
// Home-screen empty state when the user has no past transactions
// matching the current view (or none at all). Centred sleeping-cat
// pixel illustration + headline + subtitle copy.
//
// **Layout**
// Uses `GeometryReader + .position + .ignoresSafeArea()` rather than
// a Spacer-driven `VStack`. The Spacer pattern depends on the parent
// passing through `.frame(maxHeight: .infinity)` — but this view sits
// inside HomeView's `ZStack(alignment: .top)`, which doesn't reliably
// expand a child's max-height when other siblings (background, the
// ScrollView) define their own intrinsic sizes. The geo + position
// approach takes the screen rect directly from `geo.size`, sidesteps
// the propagation issue, and is what the Lottie predecessor used —
// keeping the same layout means we know the centering still works.

struct EmptyTransactionsView: View {
    /// Optional CTA tap-handler. When supplied, an "Add transaction"
    /// affordance renders below the headline so the user has a direct
    /// path into the create flow without hunting for the tab-bar `+`.
    /// Pattern mirrors `FriendsView.emptyState`'s "Add new friend" link.
    var onAdd: (() -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: AppSpacing.lg) {
                SleepingCatIllustration(tint: .neutral, size: .hero)

                Text("No transactions yet")
                    .font(AppFonts.subhead)
                    .foregroundColor(AppColors.textPrimary)

                Text("Add your first transaction to start tracking your spending.")
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xxxl)

                if let onAdd {
                    Button(action: onAdd) {
                        HStack(spacing: AppSpacing.xs) {
                            Image(systemName: "plus.circle.fill")
                                .font(AppFonts.captionEmphasized)
                            Text("Add transaction")
                                .font(AppFonts.captionEmphasized)
                        }
                        .foregroundColor(.accentColor)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
    }
}

#Preview("Light") {
    EmptyTransactionsView()
        .background(AppColors.backgroundPrimary)
}

#Preview("Dark") {
    EmptyTransactionsView()
        .background(AppColors.backgroundPrimary)
        .preferredColorScheme(.dark)
}

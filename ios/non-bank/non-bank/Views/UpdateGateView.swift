import SwiftUI

/// Full-screen, CRITICAL-ONLY app-update gate, presented above everything by
/// `RootView` when `AppUpdateService.check()` returns `.critical` (the running
/// app is below the server's minimum supported version). Primary "Update" CTA
/// only, NO dismiss affordance; `RootView` additionally applies
/// `.interactiveDismissDisabled(true)` so the user can't swipe past it.
/// Optional "a newer version is available" prompts are intentionally not shown.
///
/// Standard color context (this is a top-level app gate, not a sub-app), so
/// it uses the page-level warm tokens — `AppColors.backgroundPrimary`,
/// `textPrimary`/`textSecondary`, and `accentBold` for the white-on-fill
/// CTA (the ≥3:1 dark-mode rule). Both light and dark are handled by the
/// dynamic tokens.
struct UpdateGateView: View {
    /// Where the "Update" button sends the user (resolved by
    /// `AppUpdateService` from the server policy's `storeUrl`).
    let storeURL: URL

    @Environment(\.openURL) private var openURL

    private let title = "Update required"
    private let message =
        "This version of non-bank is no longer supported. Update to keep using the app."

    var body: some View {
        ZStack {
            AppColors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.xxl) {
                Spacer()

                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 64, weight: .regular))
                    .foregroundColor(AppColors.accent)
                    .accessibilityHidden(true)

                VStack(spacing: AppSpacing.sm) {
                    Text(title)
                        .font(AppFonts.title)
                        .foregroundColor(AppColors.textPrimary)
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(AppFonts.bodyRegular)
                        .foregroundColor(AppColors.textSecondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, AppSpacing.lg)

                Spacer()

                VStack(spacing: AppSpacing.md) {
                    // PRIMARY filled CTA. White-on-fill → `accentBold`
                    // (project rule: never `accent`/`accentColor` here).
                    Button {
                        openURL(storeURL)
                    } label: {
                        Text("Update")
                            .font(AppFonts.bodyEmphasized)
                            .foregroundColor(AppColors.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.lg)
                            .background(
                                RoundedRectangle(cornerRadius: AppRadius.large)
                                    .fill(AppColors.accentBold)
                            )
                    }
                    .buttonStyle(.plain)
                    // No "Later"/dismiss button: this gate is critical-only,
                    // so there is intentionally no escape — the user must
                    // update to continue.
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
        }
    }
}

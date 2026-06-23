import SwiftUI

/// Full-screen app-update gate, presented above everything by `RootView`
/// when `AppUpdateService.check()` returns a non-`.none` requirement.
///
/// One screen, two behaviours, selected by `isCritical`:
///   - **optional** — "Update available". Primary "Update" CTA plus a
///     low-emphasis "Later" button that dismisses the cover.
///   - **critical** — "Update required". Primary "Update" CTA only; NO
///     dismiss affordance. `RootView` additionally applies
///     `.interactiveDismissDisabled(true)` so the user can't swipe past it.
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
    /// Forced update when `true`: no "Later", no swipe-to-dismiss.
    let isCritical: Bool

    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss

    private var title: String {
        isCritical ? "Update required" : "Update available"
    }

    private var message: String {
        isCritical
            ? "This version of non-bank is no longer supported. Update to keep using the app."
            : "A new version of non-bank is available with the latest fixes and improvements."
    }

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

                    // Low-emphasis dismiss — optional updates only. Absent
                    // for critical so there is no escape from the gate.
                    if !isCritical {
                        Button {
                            dismiss()
                        } label: {
                            Text("Later")
                                .font(AppFonts.body)
                                .foregroundColor(AppColors.textSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, AppSpacing.sm)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AppSpacing.lg)
                .padding(.bottom, AppSpacing.xl)
            }
        }
    }
}

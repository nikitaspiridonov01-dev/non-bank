import SwiftUI

/// The app's first reusable transient toast — a single icon + line that
/// slides in from the top, auto-dismisses, and never blocks touches
/// (`allowsHitTesting(false)`). Transient-overlay precedent: `FireworksView`.
/// Warm design-system tokens only (no system grays / pure whites).
struct ToastView: View {
    let message: String
    var systemIcon: String = "person.2.fill"

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: systemIcon)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(AppColors.accentBold)
            Text(message)
                .font(AppFonts.bodySmallEmphasized)
                .foregroundColor(AppColors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AppSpacing.md)
        .padding(.vertical, AppSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .fill(AppColors.backgroundElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
                .strokeBorder(AppColors.border, lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, AppSpacing.lg)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

// MARK: - Presentation

extension View {
    /// Present a transient toast bound to an optional message. When the
    /// binding becomes non-nil the toast slides in from the top and
    /// auto-clears the binding after `duration` seconds. Mount once high in
    /// the hierarchy (e.g. MainTabView) so it survives sheet/tab changes.
    func toast(message: Binding<String?>, duration: TimeInterval = 4) -> some View {
        modifier(ToastPresenter(message: message, duration: duration))
    }
}

private struct ToastPresenter: ViewModifier {
    @Binding var message: String?
    let duration: TimeInterval
    @State private var dismissTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let message {
                    ToastView(message: message)
                        .padding(.top, AppSpacing.sm)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .allowsHitTesting(false)
                        .onAppear { scheduleDismiss() }
                }
            }
            .animation(AppMotion.normal, value: message)
    }

    private func scheduleDismiss() {
        dismissTask?.cancel()
        dismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.normal) { message = nil }
        }
    }
}

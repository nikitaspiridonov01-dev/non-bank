import SwiftUI
import UIKit

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
    /// binding becomes non-nil the toast slides in from the top, fires a
    /// success haptic, and auto-clears the binding after `duration` seconds.
    ///
    /// The toast is rendered in a dedicated overlay `UIWindow` ABOVE every
    /// sheet/fullScreenCover — an in-view `.overlay` is covered by any
    /// presented sheet (sheets live in a higher presentation layer than the
    /// presenter's own overlay), which is why a pairing toast fired while the
    /// share/transaction sheet was up appeared "under" the screen.
    func toast(message: Binding<String?>, duration: TimeInterval = 4) -> some View {
        modifier(ToastPresenter(message: message, duration: duration))
    }
}

private struct ToastPresenter: ViewModifier {
    @Binding var message: String?
    let duration: TimeInterval

    func body(content: Content) -> some View {
        content
            .onChange(of: message) { newValue in
                guard let newValue, !newValue.isEmpty else { return }
                ToastWindowPresenter.shared.show(newValue, duration: duration) {
                    // Clear the binding once the window dismisses so an
                    // identical follow-up message re-triggers onChange.
                    if message == newValue { message = nil }
                }
            }
    }
}

/// Hosts the toast in a transient, non-interactive `UIWindow` at
/// `.alert + 1` level so it floats above tab content AND any presented
/// sheet. The window is torn down on dismiss so it never intercepts touches
/// or lingers. `@MainActor` — all UIKit window work is main-thread only.
@MainActor
final class ToastWindowPresenter {
    static let shared = ToastWindowPresenter()
    private init() {}

    private var window: UIWindow?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String,
              icon: String = "person.2.fill",
              duration: TimeInterval = 4,
              onDismiss: @escaping () -> Void) {
        guard let scene = Self.activeScene() else { onDismiss(); return }

        // Tactile confirmation that a friend connected / a sync landed.
        let haptic = UINotificationFeedbackGenerator()
        haptic.prepare()
        haptic.notificationOccurred(.success)

        dismissTask?.cancel()

        let window = self.window ?? UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.backgroundColor = .clear
        // Never steal taps — the toast is purely informational and the
        // content/sheet underneath must stay fully interactive.
        window.isUserInteractionEnabled = false
        let host = UIHostingController(rootView: ToastWindowContainer(message: message, icon: icon))
        host.view.backgroundColor = .clear
        window.rootViewController = host
        window.isHidden = false
        self.window = window

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.window?.isHidden = true
            self?.window = nil
            onDismiss()
        }
    }

    private static func activeScene() -> UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }
}

/// Top-anchored container that drives the slide-in/out so the windowed toast
/// keeps the same motion as the old in-view overlay.
private struct ToastWindowContainer: View {
    let message: String
    let icon: String
    @State private var shown = false

    var body: some View {
        VStack {
            if shown {
                ToastView(message: message, systemIcon: icon)
                    .padding(.top, AppSpacing.sm)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
        .onAppear { withAnimation(AppMotion.normal) { shown = true } }
    }
}

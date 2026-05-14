import SwiftUI

// MARK: - Root View

/// Top-level host that gates the splash → main-app transition.
///
/// Behaviour:
///  - On every cold launch (and on every scene re-entry from a hard
///    swipe-up), shows `SplashView` first.
///  - Holds the splash for **at least 1.5 seconds** (per spec) so the
///    brand moment registers, then cross-fades into the next screen.
///  - After the splash floor, first-launch users go through
///    `OnboardingView`; everyone else lands directly in `MainTabView`.
///
/// We deliberately use a value-based `if` swap (not a `ZStack` overlay)
/// so the splash view tree is fully torn down once gone — no hidden
/// Lottie kept rendering in the background.
struct RootView: View {
    /// Toggled to `true` after the 1.5 s minimum splash duration. Drives
    /// the swap from `SplashView` to `MainTabView`. Init at `false` so
    /// the splash is always the first thing users see.
    @State private var splashDone: Bool = false

    /// First-launch onboarding gate. Sits between splash and tab view
    /// so the user can't bypass it by force-quitting mid-flow.
    @ObservedObject private var onboarding = OnboardingService.shared

    /// Minimum on-screen duration for the splash. The owner asked for
    /// "не короче, чем 1.5 секунды" so we use 1.5 here. Adjust here
    /// (and only here) if the brand moment ever needs tuning.
    private static let minimumSplashDuration: Duration = .seconds(1.5)

    var body: some View {
        Group {
            if splashDone {
                if onboarding.isCompleted {
                    MainTabView()
                        .transition(.opacity)
                } else {
                    OnboardingView()
                        .transition(.opacity)
                }
            } else {
                SplashView()
                    .transition(.opacity)
                    .task {
                        // `task` cancels automatically if the view goes
                        // away before the sleep finishes — no need for
                        // manual cancellation tokens. `try?` swallows
                        // CancellationError on view dismantle.
                        try? await Task.sleep(for: Self.minimumSplashDuration)
                        withAnimation(.easeInOut(duration: 0.35)) {
                            splashDone = true
                        }
                    }
            }
        }
        .animation(.easeInOut(duration: 0.35), value: onboarding.isCompleted)
    }
}

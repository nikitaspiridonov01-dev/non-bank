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

    /// Result of the once-per-launch app-update check. `nil` until the
    /// async check resolves to a non-`.none` requirement; drives the
    /// `.fullScreenCover` below. Optional case is cleared on "Later"
    /// dismiss; critical case is never cleared from in here (no escape).
    @State private var updateRequirement: UpdateRequirement?

    /// Latch so the update gate runs (and can pop) at most once per
    /// launch — a dismissed optional update must not immediately re-pop.
    @State private var didRunUpdateCheck = false

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
        // Kick off the app-update check once, AFTER the splash floor lifts.
        // Non-blocking (its own `Task`); fail-open inside the service means
        // a slow / failed check just leaves `updateRequirement == nil` and
        // nothing presents. Guarded by `didRunUpdateCheck` so it runs at
        // most once per launch.
        .onChange(of: splashDone) { _, done in
            guard done, !didRunUpdateCheck else { return }
            didRunUpdateCheck = true
            Task {
                let requirement = await AppUpdateService().check()
                if requirement != .none {
                    updateRequirement = requirement
                }
            }
        }
        // Top-level update gate. For `.critical` it is non-dismissible:
        // `interactiveDismissDisabled(true)` blocks the swipe and the view
        // itself renders no "Later"/close affordance. For `.optional` the
        // "Later" button + normal swipe both dismiss it; we never re-show
        // it this launch (`didRunUpdateCheck` stays true).
        .fullScreenCover(item: $updateRequirement) { requirement in
            switch requirement {
            case .none:
                // Unreachable — `.none` is filtered before binding — but
                // keeps the switch exhaustive without a forced unwrap.
                EmptyView()
            case .optional(let storeURL):
                UpdateGateView(storeURL: storeURL, isCritical: false)
            case .critical(let storeURL):
                UpdateGateView(storeURL: storeURL, isCritical: true)
                    .interactiveDismissDisabled(true)
            }
        }
    }
}

/// `Identifiable` conformance so `UpdateRequirement` can drive a
/// `.fullScreenCover(item:)`. The two presenting cases get stable, distinct
/// ids; `.none` is never bound (it's filtered before assignment) but still
/// needs an id for the synthesized switch.
extension UpdateRequirement: Identifiable {
    var id: String {
        switch self {
        case .none: return "none"
        case .optional: return "optional"
        case .critical: return "critical"
        }
    }
}

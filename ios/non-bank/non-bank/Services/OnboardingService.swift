import Foundation
import Combine

/// Tracks whether the first-launch onboarding flow has been completed.
/// Single source of truth for the flag is `UserDefaults`; observers
/// (the `RootView` gate, debug screens) stay in sync via `@Published`.
///
/// The flag is intentionally device-scoped, not synced via iCloud:
///   - it's about UI orientation on first install, not user data;
///   - a freshly-restored phone or a new family member's iPad should
///     see the onboarding once, even if iCloud sync brings prior
///     transactions over.
@MainActor
final class OnboardingService: ObservableObject {
    static let shared = OnboardingService()

    private enum Keys {
        static let isCompleted = "onboarding.isCompleted"
    }

    @Published var isCompleted: Bool {
        didSet { UserDefaults.standard.set(isCompleted, forKey: Keys.isCompleted) }
    }

    private init() {
        self.isCompleted = UserDefaults.standard.bool(forKey: Keys.isCompleted)
    }

    /// Mark the flow done. Called from `OnboardingView` on the final
    /// "Get started" tap.
    func markCompleted() {
        isCompleted = true
    }

    /// Test-only reset hook. Not invoked anywhere in production code;
    /// useful when QA wants to re-trigger onboarding without nuking
    /// the entire app.
    func reset() {
        isCompleted = false
    }
}

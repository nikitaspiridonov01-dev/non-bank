import Foundation
import StoreKit
import UIKit

/// Asks for an App Store rating at a moment the user is likely happy:
/// right after their second completed split. Apple throttles the
/// system prompt to a few times a year regardless, so we only *offer*
/// it once per app version and let StoreKit decide whether to show it.
enum ReviewPromptService {
    private static let splitCountKey = "reviewPrompt.completedSplits"
    private static let promptedVersionKey = "reviewPrompt.promptedVersion"
    private static let splitsBeforePrompt = 2

    /// Call once per completed split. The prompt itself is deferred so
    /// the sheet that finished the split has time to dismiss first.
    static func noteSplitCompleted() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: splitCountKey) + 1
        defaults.set(count, forKey: splitCountKey)
        guard count >= splitsBeforePrompt else { return }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard defaults.string(forKey: promptedVersionKey) != version else { return }
        defaults.set(version, forKey: promptedVersionKey)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            let scene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            guard let scene else { return }
            AppStore.requestReview(in: scene)
        }
    }
}

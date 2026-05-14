import Foundation
import Combine

/// User-controlled toggle for anonymous analytics. Default is **on**
/// — that's the explicit product decision (anonymous-only data, no
/// IDFA, no PII, App Store "Data Not Linked to You"). The class still
/// exists so the user can flip the switch from Settings → Privacy and
/// so we have a clean boundary if GDPR / DMA rules tighten and we
/// have to add a hard opt-in prompt.
///
/// Wires into the `AnalyticsServiceProtocol` master switch — flipping
/// the published flag immediately stops every downstream `track` /
/// `setUserProperty` call.
@MainActor
final class AnalyticsConsentService: ObservableObject {
    static let shared = AnalyticsConsentService()

    private enum Keys {
        static let isEnabled = "analytics.consent.isEnabled"
        /// `true` once `isEnabled` has been written by the user at
        /// least once. Lets us distinguish "user explicitly turned it
        /// off" from "first launch, default applies." Useful if we
        /// ever change the default — existing users keep their
        /// preference.
        static let hasUserSet = "analytics.consent.hasUserSet"
    }

    /// Defaults to `true` (anonymous analytics on) per the v1 product
    /// decision. Users who flip it off in Settings have their choice
    /// persisted.
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.isEnabled)
            UserDefaults.standard.set(true, forKey: Keys.hasUserSet)
            analytics?.setEnabled(isEnabled)
        }
    }

    /// Set on app boot. Weak to avoid retain cycles with the service
    /// container — the analytics service outlives this object anyway.
    weak var analytics: AnalyticsServiceProtocol?

    private init() {
        if UserDefaults.standard.object(forKey: Keys.isEnabled) != nil {
            self.isEnabled = UserDefaults.standard.bool(forKey: Keys.isEnabled)
        } else {
            // Default for fresh installs: anonymous analytics on.
            // Mirrors the disclosure in `LicensesView` and the
            // Privacy Policy.
            self.isEnabled = true
        }
    }
}


import Foundation

/// Backend-agnostic analytics surface. Call-sites only see this
/// protocol; the actual implementation (Firebase, PostHog, NoOp for
/// debug / tests) is wired up at app boot via `DIContainer`.
///
/// `AnyObject + Sendable` so:
///   - `weak` references work from the consent service (avoids a
///     retain cycle with the singleton),
///   - the service is safe to pass into Tasks. Concrete implementations
///     must use thread-safe internal state (Firebase's
///     `Analytics.logEvent` is already thread-safe).
protocol AnalyticsServiceProtocol: AnyObject, Sendable {

    /// Fire a one-off event. Each `AnalyticsEvent` case knows its own
    /// name + param dictionary, so call-sites stay one-liners.
    func track(_ event: AnalyticsEvent)

    /// Persist a long-lived user-level property. Firebase keeps the
    /// last-set value attached to the install for cohort filtering;
    /// re-setting with the same value is a cheap no-op.
    func setUserProperty(_ property: AnalyticsUserProperty)

    /// Convenience for SwiftUI screen tracking — Firebase auto-tracks
    /// UIKit but not SwiftUI views. View modifiers call this on
    /// `.onAppear`.
    func trackScreen(_ name: String)

    /// Master switch. Honoured by the implementation — when `false`,
    /// `track` / `setUserProperty` become no-ops so opt-out / consent
    /// frameworks can sit on top of the service without each call-site
    /// guarding individually.
    func setEnabled(_ enabled: Bool)
}

extension AnalyticsServiceProtocol {
    func trackScreen(_ name: String) {
        track(.screenView(screenName: name))
    }
}

// MARK: - NoOp implementation

/// Default implementation used in tests, debug builds (when
/// `-D ANALYTICS_DISABLED` is set), and as the fallback when no
/// Firebase SDK is linked. Logs to console in DEBUG for sanity
/// checks and drops events on the floor otherwise.
final class NoOpAnalyticsService: AnalyticsServiceProtocol {
    private let logToConsole: Bool

    init(logToConsole: Bool = false) {
        self.logToConsole = logToConsole
    }

    func track(_ event: AnalyticsEvent) {
        guard logToConsole else { return }
        #if DEBUG
        print("[Analytics] \(event.name) \(event.parameters)")
        #endif
    }

    func setUserProperty(_ property: AnalyticsUserProperty) {
        guard logToConsole else { return }
        #if DEBUG
        print("[Analytics] user_property \(property.name)=\(property.stringValue)")
        #endif
    }

    func setEnabled(_ enabled: Bool) {
        // NoOp service has nothing to toggle.
    }
}

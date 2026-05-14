import Foundation

#if canImport(FirebaseAnalytics)
import FirebaseAnalytics

/// Firebase-backed `AnalyticsServiceProtocol`. Only compiled when the
/// `FirebaseAnalytics` module is actually linked into the project —
/// the `#if canImport` guard means the file is dead-code-stripped when
/// the SDK isn't installed, so the project still builds cleanly during
/// the bring-up phase (before the user adds the SPM dependency in
/// Xcode).
///
/// Why a thin wrapper rather than calling `Analytics.logEvent` from
/// view code:
///   - **Single source of truth.** Event names + params live in
///     `AnalyticsEvent`; this file just forwards. A typo can't sneak
///     in at the call-site.
///   - **Backend swap-ability.** Wanting to add PostHog or replace
///     Firebase becomes one new conformer to the protocol, not a
///     50-call-site refactor.
///   - **Privacy guardrails.** Future PII filtering / hashing / IDFA
///     guards land here, not in 50 view modifiers.
final class FirebaseAnalyticsService: AnalyticsServiceProtocol {

    /// Mutable enable flag. Marked `nonisolated(unsafe)` because the
    /// `Sendable` conformance requires immutable storage; the only
    /// writes happen on the main thread via `setEnabled` (called from
    /// `AnalyticsConsentService` on the main actor), so the unsafe
    /// annotation is true to the actual runtime contract.
    nonisolated(unsafe) private var enabled: Bool

    init(enabled: Bool) {
        self.enabled = enabled
        Analytics.setAnalyticsCollectionEnabled(enabled)
    }

    func track(_ event: AnalyticsEvent) {
        guard enabled else { return }
        Analytics.logEvent(event.name, parameters: event.parameters)
    }

    func setUserProperty(_ property: AnalyticsUserProperty) {
        guard enabled else { return }
        Analytics.setUserProperty(property.stringValue, forName: property.name)
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        Analytics.setAnalyticsCollectionEnabled(enabled)
    }
}

#else

/// Stub that exists when Firebase isn't linked. Same surface area as
/// the real implementation so call-sites and DI registration stay
/// unchanged across the bring-up boundary.
final class FirebaseAnalyticsService: AnalyticsServiceProtocol {
    private let fallback = NoOpAnalyticsService()
    init(enabled: Bool) {}
    func track(_ event: AnalyticsEvent) { fallback.track(event) }
    func setUserProperty(_ property: AnalyticsUserProperty) { fallback.setUserProperty(property) }
    func setEnabled(_ enabled: Bool) {}
}

#endif

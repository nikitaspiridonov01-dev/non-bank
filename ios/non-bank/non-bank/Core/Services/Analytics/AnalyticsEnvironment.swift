import SwiftUI

// MARK: - Analytics EnvironmentValue
//
// Lets any SwiftUI view reach the registered analytics service via
// `@Environment(\.analytics)` without threading it manually through
// every initialiser. The default value resolves out of `DIContainer`
// at first access so an env-injection at the root is optional —
// views work either way.
//
// Why an env value rather than a global singleton: tests and previews
// can substitute a stub via `.environment(\.analytics, ...)`, and the
// SwiftUI dependency-injection story stays consistent with how
// `dismiss`, `colorScheme`, etc. are accessed.

private struct AnalyticsServiceKey: EnvironmentKey {
    static let defaultValue: AnalyticsServiceProtocol = {
        DIContainer.shared.resolve(AnalyticsServiceProtocol.self)
    }()
}

extension EnvironmentValues {
    var analytics: AnalyticsServiceProtocol {
        get { self[AnalyticsServiceKey.self] }
        set { self[AnalyticsServiceKey.self] = newValue }
    }
}

// MARK: - Screen-tracking modifier
//
// Wrap the body of any pushed / presented destination with
// `.trackScreen("ScreenName")` to fire a `screen_view` event on
// appear. Also detects sub-second bounces (back-out within 1s) and
// fires `screen_bounced_quick` as a discoverability signal.

private struct ScreenTracker: ViewModifier {
    let screenName: String
    @Environment(\.analytics) private var analytics
    @State private var appearedAt: Date?

    func body(content: Content) -> some View {
        content
            .onAppear {
                appearedAt = Date()
                analytics.trackScreen(screenName)
            }
            .onDisappear {
                guard let appearedAt else { return }
                let dwellMs = Int(Date().timeIntervalSince(appearedAt) * 1000)
                if dwellMs < 1000 {
                    analytics.track(.screenBouncedQuick(
                        screen: screenName,
                        dwellMs: dwellMs
                    ))
                }
                self.appearedAt = nil
            }
    }
}

extension View {
    /// Fires `screen_view` on appear; if the user backs out within
    /// 1 second, also fires `screen_bounced_quick`. Apply once per
    /// pushed / presented destination root.
    func trackScreen(_ name: String) -> some View {
        modifier(ScreenTracker(screenName: name))
    }
}

// MARK: - Sheet open / dismiss tracking
//
// Captures the open + dismiss pair with dwell time. The dismiss
// `action` defaults to `.swipedDown` if no explicit close path fires
// — use the imperative API (`AnalyticsSheetSession`) when the call-
// site needs to distinguish `cancelled` from `completed`.

/// Token returned when a sheet starts tracking; the call-site keeps
/// it in `@State` and asks it to record the outcome on close. Holds
/// the start timestamp so dwell can be computed without the call-
/// site managing its own clock.
struct AnalyticsSheetSession {
    let name: String
    let openedAt: Date
}

extension AnalyticsServiceProtocol {
    /// Begin tracking a sheet. Returns a session token the call-site
    /// passes back to `endSheet(...)` on close — that's what carries
    /// the open-timestamp so dwell is honest even when state hops
    /// between view re-creations.
    func beginSheet(name: String, source: String) -> AnalyticsSheetSession {
        track(.sheetOpened(name: name, source: source))
        return AnalyticsSheetSession(name: name, openedAt: Date())
    }

    /// End the sheet session. Pass `action` to distinguish the
    /// outcome (`.completed` = user confirmed, `.cancelled` = user
    /// hit X / Cancel, `.swipedDown` = system gesture).
    func endSheet(_ session: AnalyticsSheetSession, action: SheetDismissAction) {
        let dwell = Date().timeIntervalSince(session.openedAt)
        track(.sheetDismissed(
            name: session.name,
            action: action,
            dwellSecondsBucket: AnalyticsBuckets.dwellSeconds(dwell)
        ))
    }
}

// MARK: - First-use feature tracker
//
// `featureFirstUse` should fire exactly once per install per feature.
// Persisted in UserDefaults so app relaunches don't re-fire. Used by
// instrumentation hot-paths via `analytics.recordFeatureUseIfFirst(...)`.

private enum FirstUseStore {
    private static let prefix = "analytics.firstUse."

    static func isFirstTime(for feature: AnalyticsFeature) -> Bool {
        !UserDefaults.standard.bool(forKey: prefix + feature.rawValue)
    }

    static func markUsed(_ feature: AnalyticsFeature) {
        UserDefaults.standard.set(true, forKey: prefix + feature.rawValue)
    }
}

extension AnalyticsServiceProtocol {
    /// Fire `featureFirstUse(feature)` only the first time this
    /// install touches the named feature. Subsequent calls are a
    /// cheap no-op (one UserDefaults read). Safe to drop into hot
    /// code paths.
    func recordFeatureUseIfFirst(_ feature: AnalyticsFeature) {
        guard FirstUseStore.isFirstTime(for: feature) else { return }
        FirstUseStore.markUsed(feature)
        track(.featureFirstUse(feature: feature))
    }
}

// MARK: - Activation milestones (first-time)
//
// "Activation" events are once-per-install milestones — the user did
// X for the very first time. Fire them from the relevant happy path
// (transaction saved, split completed, friend created); the helper
// here gates on UserDefaults so multiple call-sites are safe.

private enum ActivationStore {
    private static let prefix = "analytics.activation."

    static func hasFired(_ key: String) -> Bool {
        UserDefaults.standard.bool(forKey: prefix + key)
    }

    static func markFired(_ key: String) {
        UserDefaults.standard.set(true, forKey: prefix + key)
    }
}

/// Install timestamp, used by activation events to compute
/// `time_since_install_minutes_bucket`. Set on first launch (by
/// `non_bankApp.bootstrapInstallDate()`); falls back to "now" if
/// the boot path was somehow skipped.
private enum InstallClock {
    private static let key = "analytics.installedAt"

    static func bootstrap() {
        guard UserDefaults.standard.object(forKey: key) == nil else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: key)
    }

    static func minutesSinceInstall() -> Int {
        let installedAt = UserDefaults.standard.double(forKey: key)
        guard installedAt > 0 else { return 0 }
        let interval = Date().timeIntervalSince1970 - installedAt
        return max(0, Int(interval / 60))
    }
}

extension AnalyticsServiceProtocol {
    /// Call once on app boot — stamps the install timestamp the first
    /// time it sees a fresh install so activation buckets compute
    /// against that anchor.
    func bootstrapInstallClock() {
        InstallClock.bootstrap()
    }

    func recordActivationFirstTransactionIfNeeded() {
        guard !ActivationStore.hasFired("first_transaction") else { return }
        ActivationStore.markFired("first_transaction")
        track(.activationFirstTransaction(
            timeSinceInstallMinutesBucket: AnalyticsBuckets.minutesSinceInstall(InstallClock.minutesSinceInstall())
        ))
    }

    func recordActivationFirstSplitIfNeeded() {
        guard !ActivationStore.hasFired("first_split") else { return }
        ActivationStore.markFired("first_split")
        track(.activationFirstSplit(
            timeSinceInstallMinutesBucket: AnalyticsBuckets.minutesSinceInstall(InstallClock.minutesSinceInstall())
        ))
    }

    func recordActivationFirstFriendIfNeeded(source: FriendCreationSource) {
        guard !ActivationStore.hasFired("first_friend") else { return }
        ActivationStore.markFired("first_friend")
        track(.activationFirstFriendAdded(source: source))
    }

    func recordActivationFirstReceiptScannedIfNeeded(outcome: ReceiptScanOutcome) {
        guard !ActivationStore.hasFired("first_receipt") else { return }
        ActivationStore.markFired("first_receipt")
        track(.activationFirstReceiptScanned(
            timeSinceInstallMinutesBucket: AnalyticsBuckets.minutesSinceInstall(InstallClock.minutesSinceInstall()),
            outcome: outcome
        ))
    }

    func recordActivationFirstShareSentIfNeeded() {
        guard !ActivationStore.hasFired("first_share") else { return }
        ActivationStore.markFired("first_share")
        track(.activationFirstShareLinkSent)
    }
}

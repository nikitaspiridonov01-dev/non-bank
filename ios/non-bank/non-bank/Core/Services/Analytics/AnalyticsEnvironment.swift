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

    /// Convenience: fire `transactionDeleted` with the standard
    /// derived params. `hadReceiptItems` is the caller's
    /// responsibility because most delete-sites don't carry a
    /// `ReceiptItemStore` reference — pass `false` when unknown
    /// and the field reads as a conservative under-count rather
    /// than a wrong-direction overcount.
    func trackTransactionDeleted(_ tx: Transaction, hadReceiptItems: Bool) {
        let ageDays = Calendar.current
            .dateComponents([.day], from: tx.date, to: Date()).day ?? 0
        track(.transactionDeleted(
            hadSplit: tx.isSplit,
            hadReceiptItems: hadReceiptItems,
            ageDaysBucket: AnalyticsBuckets.dateRangeDays(max(0, ageDays))
        ))
    }

    /// Single funnel-correct call-site for `receiptScanSucceeded`.
    /// Encapsulates the new per-event params (provider, language,
    /// store-category, image size, attempted-providers) so the call-
    /// sites in `CreateTransactionModal` / `TransactionModeFlowSheet`
    /// stay one-liners and the mapping logic doesn't drift between
    /// them.
    ///
    /// `attemptedProvidersCount` defaults to 1 because the backend
    /// doesn't currently surface the router fall-through depth in its
    /// response. Bump this when the protocol grows that field.
    func trackReceiptScanSucceeded(
        _ result: HybridReceiptParser.Result,
        imageBytes: Int,
        durationSeconds: Double
    ) {
        let confidence: ScanConfidence = {
            switch result.confidence {
            case .high:   return .high
            case .medium: return .medium
            case .low:    return .low
            }
        }()
        let (parser, provider): (ScanParser, ScanProvider) = {
            switch result.source {
            case .cloud(let providerName):
                return (.cloud, ScanProvider(rawValue: providerName) ?? .unknown)
            case .ocrFallback:
                return (.ocrFallback, .ocrFallback)
            }
        }()
        // Derived counts — discount lines have negative totals, fee
        // and tax keywords are in the item names. Coarse but useful
        // for "what does a typical receipt look like" segmentation.
        let items = result.parsedReceipt.items
        let discounts = items.filter { ($0.total ?? 0) < 0 }.count
        let fees = items.filter { item in
            let n = item.name.lowercased()
            return n.contains("fee") || n.contains("service") || n.contains("delivery")
        }.count
        let taxes = items.filter { item in
            let n = item.name.lowercased()
            return n.contains("tax") || n.contains("vat") || n.contains("tip")
        }.count

        track(.receiptScanSucceeded(
            itemsCountBucket: AnalyticsBuckets.count(items.count),
            confidence: confidence,
            parser: parser,
            durationSecondsBucket: AnalyticsBuckets.seconds(durationSeconds),
            discountCount: discounts,
            feeCount: fees,
            taxCount: taxes,
            provider: provider,
            attemptedProvidersCount: result.attemptedProvidersCount,
            imageSizeKbBucket: AnalyticsBuckets.imageSizeKb(imageBytes),
            language: ReceiptLanguage(rawValue: result.parsedReceipt.language ?? "") ?? .other,
            storeCategory: StoreCategory.from(suggestedCategory: result.parsedReceipt.suggestedCategory),
            poolRemainingBucket: result.poolRemaining.map(AnalyticsBuckets.poolRemaining),
            poolLow: result.poolLow,
            reconciliationPasses: result.reconciliationPasses,
            cloudFallbackReason: result.cloudFallbackReason
        ))
    }
}

extension HybridReceiptParser.Result {
    /// When a scan returns no usable items, prefer a capacity-specific
    /// failure reason over the generic `no_items`: if the cloud path fell
    /// back because it was rate-limited or the provider pool was exhausted,
    /// THAT is why the scan failed (local OCR just couldn't save it).
    /// Surfacing it keeps capacity-driven total failures visible in
    /// analytics instead of masked as ordinary parse failures.
    var emptyScanErrorType: ScanErrorType {
        switch cloudFallbackReason {
        case .rateLimited:          return .rateLimited
        case .providersUnavailable: return .providersUnavailable
        default:                    return .noItems
        }
    }
}

extension AnalyticsServiceProtocol {
    /// Generic error sink. Use when a dedicated event (e.g.
    /// `receiptScanFailed`) isn't appropriate. Keeps `code` stable
    /// across runs by hashing the error description when there's
    /// no domain-specific code available — raw `localizedDescription`
    /// values drift with system locale and explode dashboard
    /// cardinality.
    func trackError(
        domain: String,
        error: Error,
        recoverable: Bool,
        contextScreen: String? = nil
    ) {
        let nsError = error as NSError
        let code: String = {
            if !nsError.domain.isEmpty && nsError.code != 0 {
                return "\(nsError.domain).\(nsError.code)"
            }
            // Fingerprint the message into a low-cardinality token.
            let hash = abs(nsError.localizedDescription.hashValue) % 100000
            return "msg_" + String(hash, radix: 36)
        }()
        track(.errorOccurred(
            domain: domain,
            code: code,
            recoverable: recoverable,
            contextScreen: contextScreen
        ))
    }
}

// MARK: - User-property refresh
//
// Called at app boot and after key actions to keep the cohort-level
// properties on Firebase up to date. Cheap — each `setUserProperty`
// is a single in-memory write on the Firebase SDK side, no network
// hop per call.

extension AnalyticsServiceProtocol {
    /// Re-derives every user-property the dashboards segment on from
    /// the current store state. Safe to call repeatedly — Firebase
    /// no-ops re-sets with the same value.
    ///
    /// Call sites:
    ///   - `non_bankApp.onChange(scenePhase)` when foregrounded —
    ///     covers daily refresh + the day-bucket roll-over.
    ///   - After any large state change that flips a bucket (first
    ///     transaction created, friend added, etc.) — caller can
    ///     fire it as a follow-up to the specific event.
    func refreshUserProperties(
        transactionStore: TransactionStore,
        friendStore: FriendStore,
        currencyStore: CurrencyStore
    ) {
        let txCount = transactionStore.transactions.count
        let splitCount = transactionStore.transactions.filter { $0.isSplit }.count
        let friendCount = friendStore.friends.count
        setUserProperty(.txCountBucket(AnalyticsBuckets.count(txCount)))
        setUserProperty(.splitCountBucket(AnalyticsBuckets.count(splitCount)))
        setUserProperty(.friendCountBucket(AnalyticsBuckets.friendCount(friendCount)))
        setUserProperty(.connectedFriendCount(AnalyticsBuckets.friendCount(friendStore.friends.filter { $0.isConnected }.count)))
        setUserProperty(.defaultCurrency(currencyStore.selectedCurrency))
        let days = InstallClock.minutesSinceInstall() / (60 * 24)
        setUserProperty(.daysSinceInstallBucket(AnalyticsBuckets.daysSinceInstall(days)))
        setUserProperty(.hasICloudSync(SyncManager.isCloudKitEnabled))
    }
}

extension StoreCategory {
    /// Maps the parser's `suggestedCategory` (a user-category name like
    /// "Groceries") to the coarse `StoreCategory` analytics bucket.
    /// Anything outside the known set collapses to `.other` —
    /// never echo the raw name (PII risk for user-renamed categories).
    static func from(suggestedCategory: String?) -> StoreCategory {
        guard let raw = suggestedCategory?.lowercased() else { return .other }
        switch raw {
        case "groceries":     return .groceries
        case "food":          return .restaurant
        case "entertainment": return .entertainment
        case "transport":     return .transport
        case "fashion":       return .fashion
        case "electronics":   return .electronics
        case "healthcare":    return .healthcare
        case "utilities", "rent", "subscription":
            return .utilities
        case "maintenance", "hotel", "pet", "family", "education", "gift":
            return .services
        default:
            return .other
        }
    }
}

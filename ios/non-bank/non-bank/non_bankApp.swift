//
//  non_bankApp.swift
//  non-bank
//
//  Created by Nikita Spiridonov on 28. 3. 2026..
//

import SwiftUI
import UserNotifications

#if canImport(FirebaseCore)
import FirebaseCore
#endif

@main
struct non_bankApp: App {
    @StateObject var currencyStore = CurrencyStore()
    @StateObject var router = NavigationRouter()
    @StateObject var syncManager = SyncManager()
    @StateObject private var notificationCoordinator: NotificationCoordinator
    /// Receives incoming share-transaction deep links and publishes the
    /// decoded payload to whichever view is interested (see Phase 4 UI).
    @StateObject var shareLinkCoordinator = ShareLinkCoordinator()

    // Data stores live at the app level so every screen — including
    // splash gates / onboarding / lock overlays that sit above
    // `MainTabView` — sees the same instance via `@EnvironmentObject`.
    // Previously these were declared on `MainTabView`, but `RootView`
    // now also presents `OnboardingView`, which itself uses
    // `CurrencyDropdownButton` (transitively `transactionStore`).
    // Without lifting them, the dropdown crashed with the classic
    // "No ObservableObject of type …" fatal error.
    @StateObject var transactionStore = TransactionStore()
    @StateObject var categoryStore = CategoryStore(defaults: CategoryStore.defaultCategories)
    @StateObject var friendStore = FriendStore()
    @StateObject var receiptItemStore = ReceiptItemStore()

    init() {
        // Firebase must boot before DIContainer registers the analytics
        // service — `Analytics.logEvent` will silently no-op until
        // `FirebaseApp.configure()` has run. Guarded so the build still
        // succeeds when the SDK isn't linked.
        #if canImport(FirebaseCore)
        FirebaseApp.configure()
        #endif

        DIContainer.shared.registerDefaults()

        // Wire the consent service to the analytics implementation so
        // flipping the toggle in Settings → Privacy takes effect
        // immediately. Done after `registerDefaults` so the service
        // exists in the container.
        let analytics = DIContainer.shared.resolve(AnalyticsServiceProtocol.self)
        AnalyticsConsentService.shared.analytics = analytics
        // Honour the persisted user preference at boot — the consent
        // service constructor reads UserDefaults; pushing the value to
        // the implementation here keeps the two in sync from frame one.
        analytics.setEnabled(AnalyticsConsentService.shared.isEnabled)

        // Build the coordinator before SwiftUI's StateObject machinery so we
        // can install it as the system notification center delegate at app
        // launch — otherwise tapping a notification before the first view
        // appears would have no listener.
        let coordinator = NotificationCoordinator()
        UNUserNotificationCenter.current().delegate = coordinator
        _notificationCoordinator = StateObject(wrappedValue: coordinator)
    }

    var body: some Scene {
        WindowGroup {
            // `RootView` gates the splash-then-main transition. It owns
            // the 1.5 s splash floor; environment objects propagate
            // through to MainTabView once the splash dismisses.
            RootView()
                .environmentObject(currencyStore)
                .environmentObject(router)
                .environmentObject(syncManager)
                .environmentObject(notificationCoordinator)
                .environmentObject(shareLinkCoordinator)
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(friendStore)
                .environmentObject(receiptItemStore)
                // Both deep-link channels — current and dormant:
                //  - `onOpenURL` fires for the active path
                //    (`nonbank://share?p=…` — the in-page JS on the
                //    Cloudflare share preview hands off to this
                //    scheme), and would also fire for Universal Links
                //    (`https://<universalLinkHost>/transaction/?p=…`)
                //    once those are activated. See the top-of-file
                //    doc in `SharedTransactionLink.swift` for the
                //    activation checklist. We filter inside the
                //    coordinator via `SharedTransactionLink.isShareURL`.
                //  - `onContinueUserActivity` is the legacy hook for
                //    cold-start Universal-Link taps; it's a no-op
                //    today (no `associated-domains` entitlement →
                //    iOS never delivers user activities of this type)
                //    but stays wired so the moment Universal Links
                //    flip on, cold-start handling works without an
                //    app-update.
                .onOpenURL { url in
                    shareLinkCoordinator.handle(url: url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL {
                        shareLinkCoordinator.handle(url: url)
                    }
                }
        }
    }
}

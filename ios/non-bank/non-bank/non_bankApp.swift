//
//  non_bankApp.swift
//  non-bank
//
//  Created by Nikita Spiridonov on 28. 3. 2026..
//

import SwiftUI
import UserNotifications

@main
struct non_bankApp: App {
    @StateObject var currencyStore = CurrencyStore()
    @StateObject var router = NavigationRouter()
    @StateObject var syncManager = SyncManager()
    @StateObject private var notificationCoordinator: NotificationCoordinator
    /// Receives incoming share-transaction deep links and publishes the
    /// decoded payload to whichever view is interested (see Phase 4 UI).
    @StateObject var shareLinkCoordinator = ShareLinkCoordinator()

    init() {
        DIContainer.shared.registerDefaults()
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
                // Both deep-link channels:
                //  - `onOpenURL` fires for custom-scheme links (`nonbank://share?p=…`)
                //    AND for Universal Links (`https://share.nonbank.app/s/?p=…`)
                //    on iOS 14+. We filter inside the coordinator via
                //    `SharedTransactionLink.isShareURL`.
                //  - `onContinueUserActivity` is the legacy hook needed only
                //    if the app is launched COLD by a Universal Link tap.
                //    Hooking both keeps behaviour consistent across
                //    cold-start and warm-resume.
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

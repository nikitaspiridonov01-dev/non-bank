import UIKit
import UserNotifications

/// Minimal app delegate bridged into the SwiftUI lifecycle via
/// `@UIApplicationDelegateAdaptor`. Its only job is the APNs device-token
/// callbacks — a `UIApplicationDelegate`-only API that SwiftUI's `App`
/// doesn't surface. Firebase boot stays in `non_bankApp.init()`, and
/// notification PRESENTATION stays in `NotificationCoordinator`; this type
/// deliberately does nothing else.
final class AppDelegate: NSObject, UIApplicationDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // If notifications were authorized on a previous launch, re-register
        // so a rotated APNs token still reaches the backend. First-time
        // permission + registration happens in `NotificationService
        // .requestAuthorization` (on grant).
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        // Dev (Xcode) builds talk to the APNs sandbox; TestFlight / App
        // Store builds talk to production. The entitlement is promoted to
        // `production` at store export, matching this.
        #if DEBUG
        let env = "sandbox"
        #else
        let env = "production"
        #endif
        let myID = UserIDService.currentID()
        Task {
            await SyncDeliveryService.registerToken(userID: myID, token: hex, env: env)
        }
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        #if DEBUG
        print("[Push] registerForRemoteNotifications failed: \(error.localizedDescription)")
        #endif
    }
}

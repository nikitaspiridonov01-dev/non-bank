import Foundation
import Combine
import UserNotifications
import UIKit

/// Bridges the system notification center into SwiftUI state.
///
/// - Forwards a tapped notification's transaction `syncID` into
///   `pendingTransactionSyncID` so the UI can pop open the matching card.
/// - Asks the system to keep delivering banner alerts even when the app is
///   in the foreground — otherwise scheduled reminders fire silently.
final class NotificationCoordinator: NSObject, ObservableObject, UNUserNotificationCenterDelegate {

    /// `syncID` of the transaction whose notification was just tapped, or
    /// `nil` once the UI has consumed the event.
    @MainActor @Published var pendingTransactionSyncID: String?

    /// Set true when the "friends are now synced" notification is tapped from
    /// the BACKGROUND — drives a switch to the Profile tab + a push of
    /// `FriendsView`. Reset by the UI once it has navigated. A foreground tap
    /// leaves this untouched (just dismisses the banner).
    @MainActor @Published var pendingOpenFriends = false

    @MainActor func consumePendingTransaction() {
        pendingTransactionSyncID = nil
    }

    @MainActor func consumePendingOpenFriends() {
        pendingOpenFriends = false
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo

        // Pairing ("friends are now synced") notification: route to the
        // Friends screen, but only when tapped from the background. A
        // foreground tap just dismisses the banner. `applicationState` is
        // read here (delegate runs on the main thread) so we capture it at
        // tap time, before any async hop.
        if userInfo[NotificationService.userInfoTypeKey] as? String == NotificationService.pairedType {
            let isForeground = UIApplication.shared.applicationState == .active
            if !isForeground {
                Task { @MainActor [weak self] in
                    self?.pendingOpenFriends = true
                }
            }
            completionHandler()
            return
        }

        let syncID = userInfo[NotificationService.userInfoSyncIDKey] as? String
        Task { @MainActor [weak self] in
            self?.pendingTransactionSyncID = syncID
            // The tap can arrive while the app is ALREADY running (foreground
            // banner tap, or returning from background). In the foreground
            // case `scenePhase` doesn't transition, so the scene-activation
            // pull never fires and the tapped (remote-synced) transaction is
            // never fetched — the screen then can't open. Pull the sync inbox
            // here so the tx is applied, after which the count-change observer
            // pops the card open. Harmless for local reminder taps: the tx is
            // already present and the pull is an idempotent no-op fetch.
            await SyncEngine.shared.pullAndApply()
        }
        completionHandler()
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // A push arriving while the app is foreground doesn't trigger the
        // tap path or a scenePhase transition, so neither inbox pull fires.
        // Pull here too so a foreground push (e.g. the reciprocal pairing
        // handshake nudge) applies immediately. Idempotent no-op fetch
        // otherwise.
        Task { await SyncEngine.shared.pullAndApply() }
        completionHandler([.banner, .sound, .badge])
    }
}

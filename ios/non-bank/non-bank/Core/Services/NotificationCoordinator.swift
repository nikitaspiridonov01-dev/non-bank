import Foundation
import Combine
import UserNotifications

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

    @MainActor func consumePendingTransaction() {
        pendingTransactionSyncID = nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
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
        completionHandler([.banner, .sound, .badge])
    }
}

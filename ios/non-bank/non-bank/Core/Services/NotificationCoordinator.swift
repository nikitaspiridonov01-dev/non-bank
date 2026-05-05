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

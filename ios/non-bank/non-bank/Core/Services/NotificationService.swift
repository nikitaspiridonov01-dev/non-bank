import Foundation
import UserNotifications
import UIKit

/// Local-notification scheduling for future-dated and recurring transactions.
///
/// Strategy:
/// - **One-off future** (`date > now`, no `repeatInterval`) → a single
///   `UNCalendarNotificationTrigger` at the exact date/time.
/// - **Recurring parent** (`repeatInterval != nil`) → one repeating
///   `UNCalendarNotificationTrigger` per sub-pattern (e.g., one per weekday for
///   weekly splits, one per day-of-month for monthly). The first few
///   occurrences of future-start recurrings may fire early since the system
///   trigger doesn't take a start-date constraint — spawning logic in the app
///   still respects `tx.date`, so no phantom transactions are created.
///
/// Notifications are keyed by `tx.syncID` so edits/deletes can cancel the
/// right set without affecting other transactions.
enum NotificationService {

    // MARK: - Authorization

    /// Request permission once at app start; hooks in `MainTabView.onAppear`.
    /// On grant, also register for remote (APNs) push so server-synced
    /// shared expenses can nudge the recipient immediately — the device
    /// token arrives in `AppDelegate` and is forwarded to the backend.
    static func requestAuthorization() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                guard granted else { return }
                DispatchQueue.main.async {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
    }

    // MARK: - Public API

    /// `userInfo["type"]` marker carried by the pairing notification so the
    /// tap handler (`NotificationCoordinator`) can route it to the Friends
    /// screen instead of the transaction-card path.
    static let userInfoTypeKey = "type"
    /// Value of `userInfoTypeKey` for the "friends are now synced" alert.
    static let pairedType = "paired"

    /// Posts an immediate local notification announcing that two friends just
    /// got synced. Replaces the old in-app pairing toast — fires on BOTH sides
    /// (recipient pairing + sharer handshake) with the same copy. Tapping it
    /// from the background opens the Friends screen (see NotificationCoordinator).
    static func postPaired(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = [userInfoTypeKey: pairedType]
        // Tiny delay so the request is delivered as a notification even when
        // the app is foreground at post time (zero-interval triggers are
        // rejected by the system).
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        let request = UNNotificationRequest(
            identifier: "paired-\(UUID().uuidString)",
            content: content,
            trigger: trigger
        )
        add([request])
    }

    /// Cancels any pending notifications for `transaction` and schedules a
    /// fresh set if the transaction is future-dated or recurring.
    static func schedule(for transaction: Transaction) {
        cancel(for: transaction) {
            if let interval = transaction.repeatInterval {
                add(recurringRequests(for: transaction, interval: interval))
            } else if transaction.date > Date() {
                add([oneOffRequest(for: transaction)])
            }
        }
    }

    /// Cancel all pending notifications that belong to `transaction`.
    static func cancel(for transaction: Transaction, then completion: (() -> Void)? = nil) {
        let prefix = identifierPrefix(for: transaction)
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            if !ids.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
            completion?()
        }
    }

    /// Removes any pending requests we own (`tx-…` identifiers) that don't
    /// match an expected request from one of the live transactions. Useful at
    /// app launch to evict orphans left behind by interrupted delete flows or
    /// older app builds.
    static func cleanupStale(transactions: [Transaction]) {
        var expected = Set<String>()
        for tx in transactions {
            let prefix = identifierPrefix(for: tx)
            if let interval = tx.repeatInterval {
                switch interval {
                case .daily:
                    expected.insert("\(prefix)daily")
                case .weekly(_, _, let days):
                    for day in days {
                        expected.insert("\(prefix)weekly-\(day.rawValue)")
                    }
                case .monthly(_, _, let days):
                    for day in days {
                        expected.insert("\(prefix)monthly-\(day)")
                    }
                case .yearly:
                    expected.insert("\(prefix)yearly")
                }
            } else if tx.date > Date() {
                expected.insert("\(prefix)once")
            }
        }

        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let staleIDs = requests.compactMap { req -> String? in
                guard req.identifier.hasPrefix("tx-") else { return nil }
                return expected.contains(req.identifier) ? nil : req.identifier
            }
            if !staleIDs.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: staleIDs)
            }
        }
    }

    // MARK: - Request Builders

    private static func identifierPrefix(for tx: Transaction) -> String {
        "tx-\(tx.syncID)-"
    }

    private static func oneOffRequest(for tx: Transaction) -> UNNotificationRequest {
        let comps = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: tx.date
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        return UNNotificationRequest(
            identifier: "\(identifierPrefix(for: tx))once",
            content: buildContent(for: tx),
            trigger: trigger
        )
    }

    private static func recurringRequests(
        for tx: Transaction,
        interval: RepeatInterval
    ) -> [UNNotificationRequest] {
        let content = buildContent(for: tx)
        let prefix = identifierPrefix(for: tx)

        switch interval {
        case .daily(let hour, let minute):
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            return [
                UNNotificationRequest(
                    identifier: "\(prefix)daily",
                    content: content,
                    trigger: trigger
                )
            ]

        case .weekly(let hour, let minute, let daysOfWeek):
            return daysOfWeek.map { day in
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                comps.weekday = day.rawValue
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                return UNNotificationRequest(
                    identifier: "\(prefix)weekly-\(day.rawValue)",
                    content: content,
                    trigger: trigger
                )
            }

        case .monthly(let hour, let minute, let daysOfMonth):
            return daysOfMonth.map { day in
                var comps = DateComponents()
                comps.hour = hour
                comps.minute = minute
                comps.day = day
                let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
                return UNNotificationRequest(
                    identifier: "\(prefix)monthly-\(day)",
                    content: content,
                    trigger: trigger
                )
            }

        case .yearly(let hour, let minute, let month, let day):
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            comps.month = month.rawValue
            comps.day = day
            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
            return [
                UNNotificationRequest(
                    identifier: "\(prefix)yearly",
                    content: content,
                    trigger: trigger
                )
            ]
        }
    }

    private static func buildContent(for tx: Transaction) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        let sign = tx.isIncome ? "+" : "–"
        let formatted = NumberFormatting.integerPart(tx.amount)
        content.title = tx.isIncome ? "Scheduled income" : "Scheduled expense"
        content.body = "\(tx.emoji) \(tx.title): \(sign)\(formatted) \(tx.currency)"
        content.sound = .default
        // Carry the syncID so the notification handler can look up the
        // transaction when the user taps the alert.
        content.userInfo = [Self.userInfoSyncIDKey: tx.syncID]
        return content
    }

    /// Key used inside `UNNotificationContent.userInfo` to surface the
    /// transaction's `syncID` to the tap handler.
    static let userInfoSyncIDKey = "transactionSyncID"

    private static func add(_ requests: [UNNotificationRequest]) {
        let center = UNUserNotificationCenter.current()
        for request in requests {
            center.add(request) { _ in }
        }
    }
}

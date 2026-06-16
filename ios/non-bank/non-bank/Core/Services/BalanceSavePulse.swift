import Foundation
import Combine
import UIKit

/// One-shot signal that a user-driven create/edit SAVE just changed the
/// balance — the trigger for the Home-screen "Net total" count-up + the
/// success haptic.
///
/// **Why a dedicated signal (vs. observing the balance directly):** the
/// displayed total recomputes on lots of events that are NOT a save —
/// initial load, tab switches, sync pulls, currency change, the
/// include-potential-expenses toggle. Animating + buzzing on all of
/// those would feel random. Instead the save action (and only the save
/// action) calls `fire()`, bumping `pulseID`. `BalanceHeaderView`
/// watches `pulseID`: a change means "roll the number"; a balance change
/// WITHOUT a fresh `pulseID` snaps instantly with no animation/haptic.
///
/// Shared singleton so the deeply-nested create modal can poke it
/// without threading a new `@EnvironmentObject` through the whole view
/// tree; the Home balance view holds it as an `@ObservedObject`.
@MainActor
final class BalanceSavePulse: ObservableObject {

    static let shared = BalanceSavePulse()

    /// Monotonic counter. Every `fire()` increments it; the balance view
    /// keys its count-up animation off changes to this value.
    @Published private(set) var pulseID: Int = 0

    private init() {}

    /// Call from the create/edit save path right after the store write.
    /// Fires the standard success haptic and bumps `pulseID` so the Home
    /// balance rolls to its new value. (An earlier ramping "counter spin-up"
    /// haptic was reverted — the plain success notification is preferred.)
    func fire() {
        pulseID &+= 1
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
}

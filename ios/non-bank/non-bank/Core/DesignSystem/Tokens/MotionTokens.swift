import SwiftUI

// MARK: - Motion Tokens
//
// Centralised animation language. Replaces the scattered inline
// `easeInOut(duration: 0.18 / 0.20 / 0.22 / 0.25 / 0.30 / 0.35)` calls
// across ~20 view files.
//
// **Why bother**: a redesign that says "make all UI feel snappier"
// becomes a one-line change here; without this, you'd hunt 30+
// callsites and risk drift.
//
// Categories:
// - **Speed** — `fast` / `normal` / `slow` for general UI transitions
//   (sheet open, pill toggle, tooltip fade, content swap).
// - **Spring** — for state-driven layout changes that need physical
//   feel (collapse/expand, drag-back, FAB pop).
// - **Disabled** — when you explicitly want to skip animation
//   (instant updates that would otherwise inherit a parent's
//   implicit animation).

enum AppMotion {

    // MARK: - Speed

    /// 0.15s easeInOut — quick state flips (selection, hover,
    /// tooltip fade). Use when the user shouldn't notice the
    /// transition, only the result.
    static let fast = Animation.easeInOut(duration: 0.15)

    /// 0.22s easeInOut — default for most UI transitions
    /// (toggle a card, swap content in a sheet, ring-on-tap).
    /// Replaces the cluster of 0.18 / 0.20 / 0.22 inline values.
    static let normal = Animation.easeInOut(duration: 0.22)

    /// 0.35s easeInOut — slower transitions where the user should
    /// see the animation arc (splash → main, big modal swaps).
    static let slow = Animation.easeInOut(duration: 0.35)

    // MARK: - Spring

    /// Soft spring — natural feel for content that "settles into
    /// place" (scroll-to-top, collapse-from-drag). Matches the
    /// inline `spring(response: 0.5, dampingFraction: 0.9)` used
    /// in the home-screen scroll behaviour.
    static let spring = Animation.spring(response: 0.5, dampingFraction: 0.9)

    /// Snappier spring — interactive controls (chip select,
    /// segmented picker change). Tighter response, slightly less
    /// damping for a hint of bounce.
    static let snappy = Animation.spring(response: 0.35, dampingFraction: 0.85)

    /// Bouncy spring — celebratory / playful (e.g. hero number
    /// landing on a sheet open). Use sparingly — too much bounce
    /// reads as toy-like in a finance app.
    static let bouncy = Animation.spring(response: 0.45, dampingFraction: 0.7)
}

// MARK: - Balance Counter Motion
//
// Shared tuning for the Home-screen "Net total" count-up that plays
// when the user creates or edits a transaction. Pulled out into its own
// token so the roll duration lives in one place — change the count-up
// length with a one-line edit.
enum BalanceCounterMotion {

    /// Total spin-up time for the count-up + ramping haptic (~0.75s).
    /// Long enough to read as a deliberate roll, short enough not to
    /// stall the user after the create modal dismisses.
    static let duration: TimeInterval = 0.75

    /// Drives the digit roll. `easeOut` so the counter sprints out of
    /// the gate and decelerates into the final value — the classic
    /// "spinning to a stop" feel. Paired with `.contentTransition(
    /// .numericText(value:))` on the balance digits.
    static var animation: Animation { .easeOut(duration: duration) }
}


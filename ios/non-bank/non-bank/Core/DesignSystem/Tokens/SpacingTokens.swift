import SwiftUI

// MARK: - Layout Tokens
//
// Three enums:
// - `AppSpacing`  — generic 4-pt scale. Use for `.padding(...)`,
//                   `HStack(spacing:)`, `VStack(spacing:)` etc.
// - `AppRadius`   — corner-radius scale.
// - `AppSizes`    — component-specific layout constants
//                   (FAB size, balance-header height, …). Don't add
//                   generic spacing here — use `AppSpacing` instead.

// MARK: - AppSpacing (preferred for new code)
//
// Strict 4-pt rhythm. Replaces the 92 hardcoded `.padding(.horizontal, 16)`
// / `.vertical, 12)` etc. scattered across views. The de-facto scale
// already in use is **4 / 8 / 12 / 16 / 20 / 24** — codified here so a
// redesign can globally re-tune the rhythm in one file.
//
// Naming convention follows familiar t-shirt sizes:
//   - xxs (2)  — gap between baseline-aligned glyphs
//   - xs  (4)  — tight inter-element gap
//   - sm  (8)  — small gap (chip internal padding)
//   - md  (12) — medium gap (row vertical padding, narrative line gap)
//   - lg  (16) — large gap / **standard horizontal page padding**
//   - xl  (20) — extra-large / **standard card inset**
//   - xxl (24) — section breaks
//   - xxxl(32) — major section / hero spacing
enum AppSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32

    // MARK: Semantic aliases (preferred — survive scale tweaks)
    //
    // When a value's role is meaningful ("the page's horizontal
    // gutter" rather than "16 pt"), prefer the semantic alias — the
    // redesign can shift the rhythm without re-hunting raw values.

    /// Standard horizontal padding for full-width content
    /// (transaction rows, quick-filter bars, page sections). 16pt.
    static let pageHorizontal = lg
    /// Standard inset for card content (Insights card body,
    /// detail sheets). 20pt.
    static let cardInset = xl
    /// Vertical rhythm between sibling cards in a scroll. 14pt
    /// has been the de-facto value; rounded down to the scale.
    static let cardGap = md
    /// Row pill internal vertical padding. 12pt.
    static let rowVertical = md
    /// Row pill internal horizontal padding. 14pt is in use;
    /// rounded down to scale value of `md`. Legacy `AppSizes`
    /// constants remain for places that need 14 specifically.
    static let rowHorizontal = md
}

enum AppRadius {
    /// 8pt — small chip / picker pill.
    static let small: CGFloat = 8
    /// 12pt — standard chip / button.
    static let medium: CGFloat = 12
    /// 16pt — card surface (Insights cards, sheet content).
    static let large: CGFloat = 16
    /// 18pt — extra-large; used in one place currently.
    static let xlarge: CGFloat = 18
    /// 22pt — FAB.
    static let fab: CGFloat = 22

    // MARK: Semantic aliases

    /// Tappable row pill inside an Insights card. 14pt is the
    /// in-use value; not on the standard scale, kept verbatim so
    /// existing layouts don't drift.
    static let rowPill: CGFloat = 14
    /// Card surface — `large`.
    static let card = large
    /// Chip / segmented control — `medium`.
    static let chip = medium
}

enum AppSizes {
    // Transaction row
    static let emojiFrame: CGFloat = 40
    static let rowVerticalPadding: CGFloat = 12
    static let dividerLeading: CGFloat = 70

    // Balance header
    static let balanceHeight: CGFloat = 60
    static let trendBarWidth: CGFloat = 1.5
    static let trendBarHeight: CGFloat = 72
    static let headerExpandedHeight: CGFloat = 305
    static let headerFilterHeight: CGFloat = 420
    static let headerExtraTopPadding: CGFloat = 32
    static let headerCollapseThreshold: CGFloat = 140.0

    // FAB (floating action button)
    static let fabSize: CGFloat = 64
    static let fabOffset: CGFloat = -16

    // Tab bar
    static let tabBarBottomPadding: CGFloat = 8
    static let tabBarHorizontalPadding: CGFloat = 8
    static let tabBarCenterSpacing: CGFloat = 36

    // Chips / Pills
    static let chipHorizontalPadding: CGFloat = 12
    static let chipVerticalPadding: CGFloat = 8

    // Reminders
    static let reminderBadgeHeight: CGFloat = 20
    static let reminderRowVerticalPadding: CGFloat = 14

    // Trend bars
    static let trendBarsCount = 44
}

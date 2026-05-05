import SwiftUI

// MARK: - Color Tokens (Adaptive)
// Single source of truth for all colors in the app.
// These tokens adapt automatically to Light/Dark using dynamic UIColor providers
// and prefer system semantic colors for accessibility.

enum AppColors {

    // Helper to build dynamic Color from light/dark UIColors
    private static func dynamic(_ light: UIColor, _ dark: UIColor) -> Color {
        return Color(UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }

    // MARK: - Backgrounds
    // Use system backgrounds to get proper grouped/list appearances and accessibility.
    static var backgroundPrimary: Color { Color(.systemBackground) }
    static var backgroundElevated: Color { Color(.secondarySystemBackground) }
    static var backgroundChip: Color { Color(.tertiarySystemBackground) }

    // Overlay used to modulate blur materials: in Dark, slightly darken; in Light, keep clear.
    static var backgroundOverlay: Color {
        dynamic(UIColor.clear, UIColor.black.withAlphaComponent(0.55))
    }

    // MARK: - Text
    static var textPrimary: Color { Color(.label) }
    static var textSecondary: Color { Color(.secondaryLabel) }
    static var textTertiary: Color { Color(.tertiaryLabel) }
    static var textQuaternary: Color { Color(.quaternaryLabel) }
    static var textDisabled: Color { Color(.placeholderText) }

    // Text intended to be placed on top of the accent gradient / filled buttons
    static var textOnAccent: Color { Color.white }

    // MARK: - Balance
    // Use subtle grays in Light and existing values in Dark for familiarity.
    static var balanceSign: Color {
        dynamic(UIColor.systemGray, UIColor(red: 0.49, green: 0.53, blue: 0.56, alpha: 1.0))
    }
    static var balanceDecimal: Color {
        dynamic(UIColor.systemGray2, UIColor(red: 0.64, green: 0.66, blue: 0.71, alpha: 1.0))
    }
    static var balanceCurrency: Color {
        dynamic(UIColor.systemBlue, UIColor(red: 0.22, green: 0.55, blue: 1.0, alpha: 1.0))
    }

    // MARK: - Accent / Action
    static var accentGradientTop: Color {
        // Keep brand gradient consistent across themes
        Color(red: 0.42, green: 0.64, blue: 1.0)
    }
    static var accentGradientBottom: Color {
        Color(red: 0.21, green: 0.47, blue: 1.0)
    }
    static var accentShadow: Color {
        Color.blue.opacity(0.32)
    }

    // MARK: - Reminders / Split
    static var reminderAccent: Color {
        dynamic(
            UIColor(red: 0.90, green: 0.55, blue: 0.10, alpha: 1.0),   // light: deeper orange
            UIColor.systemOrange                                         // dark: system default
        )
    }
    static var splitAccent: Color { Color(.systemPurple) }

    /// Reminder card background
    static var reminderBackgroundTint: Color {
        dynamic(
            UIColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1.0),   // light: very light warm
            UIColor(red: 0.06, green: 0.04, blue: 0.03, alpha: 1.0)    // dark: near-black warm
        )
    }

    /// Emoji icon background on reminder card
    static var reminderEmojiBackground: Color {
        dynamic(
            UIColor(white: 1.0, alpha: 0.85),
            UIColor.white.withAlphaComponent(0.08)
        )
    }

    /// Notes card fill on reminder card
    static var reminderNotesFill: Color {
        dynamic(
            UIColor.white,
            UIColor.white.withAlphaComponent(0.05)
        )
    }

    /// Notes card border on reminder card
    static var reminderNotesBorder: Color {
        dynamic(
            UIColor(white: 0.85, alpha: 1.0),
            UIColor.white.withAlphaComponent(0.08)
        )
    }

    /// Timeline/occurrence block background on reminder card
    static var reminderTimelineBackground: Color {
        dynamic(
            UIColor(white: 1.0, alpha: 0.75),
            UIColor.white.withAlphaComponent(0.06)
        )
    }

    // MARK: - Semantic (preferred for new code)
    //
    // Use these for *meaning*, not appearance. A semantic token says
    // "this is a danger signal" — the redesign can re-tune the actual
    // hue without touching every callsite.

    /// Positive / favorable signal: income up, expenses down,
    /// successful action, savings opportunity. Adapts dynamically
    /// across light/dark via the system green.
    static var success: Color { Color(.systemGreen) }

    /// Negative / unfavorable signal: error, expense growing,
    /// balance shrinking. System red, dynamic across modes.
    static var danger: Color { Color(.systemRed) }

    /// Informational / neutral signal — links, hints, secondary
    /// CTAs. System blue, dynamic.
    static var info: Color { Color(.systemBlue) }

    /// Solid accent for interactive elements (buttons, taps,
    /// active filter). Picks up the user's system accent if set,
    /// otherwise falls back to the system default. Distinct from
    /// `accentGradientTop/Bottom` which are reserved for the FAB
    /// brand gradient.
    static var accent: Color { Color.accentColor }

    /// Generic warning state (deprecation, advisory). Same hue as
    /// the existing `warning` token but with semantic naming.
    /// Existing `warning` is kept as alias below.
    static var caution: Color { Color(.systemOrange) }

    // MARK: - Money semantics (preferred for new code)
    //
    // Tied to `success` / `danger` so the entire "money in vs out"
    // colour vocabulary moves together if/when the redesign tweaks
    // the green or red.

    /// Income / money coming in. Same hue as `success` so the two
    /// stay in lockstep visually.
    static var incomeAccent: Color { success }

    /// Outgoing expense — used for "spent more" highlights, expense
    /// trend up, big-purchase deltas, etc. Replaces the prior reuse
    /// of `reminderAccent` for non-reminder purposes; going forward
    /// `reminderAccent` is reserved for actual reminders.
    static var expenseAccent: Color { reminderAccent }

    // MARK: - Generic warning (existing usage)
    static var warning: Color { Color(.systemOrange) }

    // MARK: - Border
    static var border: Color { Color(.separator) }

    // MARK: - Trend Bar
    static var trendBarDefault: Color { Color(.label).opacity(0.18) }
    static var trendBarRecent: Color { Color(.label).opacity(0.34) }
    static var trendBarDimmed: Color { Color(.label).opacity(0.08) }
    static var trendBarHovered: Color { Color(.label) }

    // MARK: - Insights / Analytics

    /// Card surface for the Insights screen. Light mode matches the
    /// standard elevated default; **dark mode is deliberately darker
    /// than `backgroundElevated`** so Insights cards read as embedded
    /// in the page rather than floating above it (matches the design
    /// prototype where the card "wells" into the screen).
    static var insightCard: Color {
        dynamic(
            UIColor.secondarySystemBackground,
            UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        )
    }

    /// Row pill background inside an Insights card. One step *lighter*
    /// than `insightCard` so each row reads as a distinct chip against
    /// the deep-dark card surface. In light mode it falls back to the
    /// standard chip fill.
    static var insightRowFill: Color {
        dynamic(
            UIColor.tertiarySystemBackground,
            UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1.0)
        )
    }
}

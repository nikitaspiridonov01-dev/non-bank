import SwiftUI

// MARK: - Color Context
//
// Sub-palette switcher driven by SwiftUI's environment. Lets entire
// screens declare "I'm a Reminders surface" / "I'm a Split surface"
// once at the root, and have child views (badges, headers, empty
// states, pixel illustrations) auto-pick up the matching colour
// vocabulary without each view having to know its parent context.
//
// **Why an environment value (not duplicate tokens)?**
// The alternative is to define `remindersAccent` / `splitAccent`
// alongside the default `accent`, then have every Reminders / Split
// screen rebind its child views' accent manually. That works but
// scales badly: 30 callsites × 2 contexts = 60 explicit overrides
// the redesign has to chase whenever a token shifts. Environment-
// driven means each screen does a single `.colorContext(.reminders)`
// at the top and the sub-palette flows down for free.
//
// **What flips per context:**
//   - `accent` / `accentBold` — for inline highlights & filled CTAs
//   - `surfaceTint` — page / card background hue (warm cream for
//     Reminders, light pink for Split, default neutral otherwise)
//   - `pixelTint` — `PixelTint` for `*Illustration` views so empty
//     states inside a Reminders screen feel red, inside Split feel
//     purple, etc.
//
// **What does NOT flip:** `textPrimary` / `textSecondary` /
// `textTertiary` / `danger` / `success` / `info` — those are
// system-semantic and should read the same regardless of context.
// Body text on a Reminders screen is the same `label` colour as on
// Home; a danger-red destroy action stays wine across all contexts.
//
// **Usage:**
//
//     RemindersListView()
//         .colorContext(.reminders)
//
//     // Inside a child view:
//     @Environment(\.colorContext) private var context
//     var body: some View {
//         Text("Tomorrow")
//             .foregroundColor(context.accent)
//             .background(context.surfaceTint)
//     }

enum ColorContext: Equatable {
    /// Default app palette — warm-orange primary, neutral surfaces.
    case standard

    /// Reminders sub-palette — warm calendar-red accent, warm cream
    /// surface tint, red pixel-illustration tint.
    case reminders

    /// Split sub-palette — soft lavender accent, light pink surface
    /// tint, purple pixel-illustration tint.
    case split
}

// MARK: - Token derivations

extension ColorContext {

    /// Inline-highlight accent for this context. Use for things like
    /// "$X" in narrative copy, active filter tints, accent borders.
    var accent: Color {
        switch self {
        case .standard:  return AppColors.accent
        case .reminders: return AppColors.reminderAccent
        case .split:     return AppColors.splitAccent
        }
    }

    /// Filled-button accent for this context — deeper variant so
    /// white text on top hits ≥3:1 contrast.
    ///
    /// For Split this routes to `AppColors.splitAccentBold` — the
    /// static deep violet (`#6E46B4`) that pairs cleanly with white
    /// in both themes. The default `splitAccent` brightens to a pale
    /// lavender in dark mode and was the reason `splitAccentBold`
    /// was introduced in `ColorTokens.swift`; this enum returning
    /// the lighter `splitAccent` was a leftover from when the bold
    /// variant didn't exist yet.
    var accentBold: Color {
        switch self {
        case .standard:  return AppColors.accentBold
        case .reminders: return AppColors.reminderAccentBold
        case .split:     return AppColors.splitAccentBold
        }
    }

    /// Surface background tint that gives the screen its
    /// "atmosphere". Reminders → warm cream, Split → light pink,
    /// standard → the default `backgroundPrimary` (system-managed).
    var surfaceTint: Color {
        switch self {
        case .standard:  return AppColors.backgroundPrimary
        case .reminders: return AppColors.reminderBackgroundTint
        case .split:     return AppColors.splitBackgroundTint
        }
    }

    /// Card / row fill for this context — the warm sub-app surface the
    /// Reminders / Split palettes already expose (`reminderCardFill` /
    /// `splitCardFill`), with `backgroundElevated` (soft beige) as the
    /// standard fallback. Used as a UNIFORM layer UNDER a per-row
    /// `.glassEffect` so iOS-26 Liquid Glass samples a constant backdrop
    /// instead of a size-dependent slice of the live MeshGradient page —
    /// a taller row (wrapped name / extra chip line) otherwise reads
    /// lighter than a short one. Deliberately never a system gray or
    /// pure white (warm-palette rule).
    var cardFill: Color {
        switch self {
        case .standard:  return AppColors.backgroundElevated
        case .reminders: return AppColors.reminderCardFill
        case .split:     return AppColors.splitCardFill
        }
    }

    /// Under-fill for a glass row/card. The gradient-backed sub-app
    /// surfaces (reminders / split) need a uniform fill so the per-row
    /// `.glassEffect` doesn't sample a size-dependent slice of the live
    /// gradient. The FLAT `.standard` surface does not — there, plain glass
    /// (exactly like the transaction card's items preview) reads cleaner
    /// than the soft-beige `backgroundElevated` panel, which looked murky in
    /// light mode. So `.standard` returns `.clear` (glass shows the flat page
    /// through); reminders / split keep their warm `cardFill`.
    var glassUnderFill: Color {
        self == .standard ? .clear : cardFill
    }

    /// Matching `PixelTint` so animated illustrations on this
    /// context's screens automatically theme to it.
    var pixelTint: PixelTint {
        switch self {
        case .standard:  return .neutral
        case .reminders: return .reminders
        case .split:     return .split
        }
    }
}

// MARK: - Environment plumbing

private struct ColorContextKey: EnvironmentKey {
    static let defaultValue: ColorContext = .standard
}

extension EnvironmentValues {
    /// The current colour context. Defaults to `.standard`. Set via
    /// `.colorContext(_:)` modifier from any ancestor view.
    var colorContext: ColorContext {
        get { self[ColorContextKey.self] }
        set { self[ColorContextKey.self] = newValue }
    }
}

extension View {
    /// Declares this view (and its descendants) as belonging to a
    /// particular colour context — Reminders, Split, or the
    /// `standard` default. Child views that read
    /// `@Environment(\.colorContext)` will pick up the matching
    /// sub-palette automatically.
    func colorContext(_ context: ColorContext) -> some View {
        environment(\.colorContext, context)
    }
}

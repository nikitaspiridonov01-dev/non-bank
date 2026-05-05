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
    //
    // Light mode hand-tuned to a **warm cream / soft beige** palette
    // rather than the cool blue-grey iOS defaults. The warm primary
    // accent (`#F18A4D`) sits awkwardly against cool grey — the page
    // looked clinical and the orange jumped out as alien. Warm-tinted
    // surfaces give the orange somewhere to land naturally and lift
    // overall warmth without sacrificing clarity.
    //
    // Dark mode stays on system semantic colours (`systemBackground`
    // family) — they already feel right against the orange in dark.
    //
    // Three steps with **clearly distinct lightness** so chips read
    // as elevated against the page, not like a different shade of
    // the same colour:
    //   - `backgroundPrimary` — page-level surface, brightest cream
    //   - `backgroundElevated` — cards / sheets, ~5% darker
    //   - `backgroundChip` — pill / chip fills, ~10% darker

    static var backgroundPrimary: Color {
        dynamic(
            UIColor(red: 0.99, green: 0.98, blue: 0.97, alpha: 1.0),  // ~#FCFAF7 warm cream
            UIColor.systemBackground                                   // dark stays system
        )
    }

    static var backgroundElevated: Color {
        dynamic(
            UIColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1.0),  // ~#F5EFEA soft beige
            UIColor.secondarySystemBackground
        )
    }

    static var backgroundChip: Color {
        dynamic(
            UIColor(red: 0.91, green: 0.87, blue: 0.82, alpha: 1.0),  // ~#E7DEDC visible but not heavy
            UIColor.tertiarySystemBackground
        )
    }

    // Overlay used to modulate blur materials: in Dark, slightly darken; in Light, keep clear.
    static var backgroundOverlay: Color {
        dynamic(UIColor.clear, UIColor.black.withAlphaComponent(0.55))
    }

    // MARK: - Text
    //
    // Light mode hand-tuned to **warm-tinted** greys (slight brown
    // bias toward `rgb(80, 65, 55)`-ish) rather than iOS's default
    // cold blue-greys. Warm greys harmonise with the orange accent
    // and the cream backgrounds; cold greys clashed and looked
    // clinical. Tertiary / quaternary also get **stronger opacity**
    // than the system defaults so faded labels actually remain
    // readable (system `tertiaryLabel` = 30% → too washed out on a
    // cream background; bumped to ~50%).
    //
    // Dark mode stays on system labels — they're tuned correctly
    // against `systemBackground` already.

    static var textPrimary: Color {
        dynamic(
            UIColor(red: 0.16, green: 0.13, blue: 0.10, alpha: 1.0),  // ~#29211A warm near-black
            UIColor.label
        )
    }

    static var textSecondary: Color {
        dynamic(
            UIColor(red: 0.36, green: 0.30, blue: 0.24, alpha: 1.0),  // ~#5C4D3D warm dark-grey
            UIColor.secondaryLabel
        )
    }

    static var textTertiary: Color {
        dynamic(
            UIColor(red: 0.50, green: 0.43, blue: 0.36, alpha: 1.0),  // ~#806D5C medium warm-grey
            UIColor.tertiaryLabel
        )
    }

    static var textQuaternary: Color {
        dynamic(
            UIColor(red: 0.62, green: 0.55, blue: 0.48, alpha: 1.0),  // ~#9E8C7B light warm-grey (still visible on cream)
            UIColor.quaternaryLabel
        )
    }

    static var textDisabled: Color { Color(.placeholderText) }

    // Text intended to be placed on top of the accent gradient / filled buttons
    static var textOnAccent: Color { Color.white }

    // MARK: - Balance
    // Sign and decimal stay subtle gray; currency code is metadata
    // (no longer call-to-action) so it picks up `secondaryLabel`.
    static var balanceSign: Color {
        dynamic(UIColor.systemGray, UIColor(red: 0.49, green: 0.53, blue: 0.56, alpha: 1.0))
    }
    static var balanceDecimal: Color {
        dynamic(UIColor.systemGray2, UIColor(red: 0.64, green: 0.66, blue: 0.71, alpha: 1.0))
    }
    /// Currency code chip next to balance digits ("USD"). Picks up
    /// the warm primary `accent` so the chip telegraphs "interactive"
    /// without an extra chevron icon. The neutral grey alternative
    /// (`.secondaryLabel`) was clean but read as static metadata —
    /// users didn't realise the chip opens a currency picker.
    /// Token shared across `BalanceHeaderView`, `CreateTransactionModal`,
    /// and `DebtSummaryView` so the affordance is consistent.
    static var balanceCurrency: Color { accent }

    // MARK: - Accent / Action
    //
    // Primary accent is the warm Maple-orange `#F18A4D`. Defined in
    // `AccentColor.colorset` (Asset Catalog) so it picks up via
    // `Color.accentColor` and `AppColors.accent` everywhere — including
    // SwiftUI controls (toggles, links, navigation tints).
    //
    // The legacy blue gradient tokens below are kept to avoid breaking
    // any existing callsite during the redesign sweep. The chrome they
    // used to drive (FAB, etc.) is moving to the new black-pill +
    // Liquid Glass pattern (`ctaSurface` / `ctaForeground`).

    /// **Legacy.** Old blue FAB gradient top. New code should use
    /// `ctaSurface` instead. Kept as transition shim until the sweep
    /// retires the gradient FAB.
    static var accentGradientTop: Color {
        Color(red: 0.42, green: 0.64, blue: 1.0)
    }
    /// **Legacy.** Old blue FAB gradient bottom. See `accentGradientTop`.
    static var accentGradientBottom: Color {
        Color(red: 0.21, green: 0.47, blue: 1.0)
    }
    /// **Legacy.** Old blue drop shadow under FAB.
    static var accentShadow: Color {
        Color.blue.opacity(0.32)
    }

    // MARK: - CTA surface
    //
    // Black-pill primary CTA (Maple/Strike vocabulary). `ctaSurface`
    // adapts to light/dark via `Color(.label)` — black in light, white
    // in dark — so the FAB / big black buttons look iconic in both
    // modes. `ctaForeground` is the inverse (white on light, black on
    // dark) for icon/label content sitting on top.

    /// Background of the primary CTA pill (FAB, big black buttons).
    /// Uses `Color(.label)` so it inverts cleanly between modes.
    static var ctaSurface: Color { Color(.label) }

    /// Foreground (icon / label) on top of `ctaSurface`. Inverts so
    /// it's always the high-contrast counterpart of the surface.
    static var ctaForeground: Color { Color(.systemBackground) }

    // MARK: - Bold accent variants (filled-background contexts)
    //
    // White text on the warm `accent` (`#F18A4D`) only hits ~2.6:1
    // contrast — fails WCAG AA even for large text. The lighter accent
    // is the right choice for **tints** (borders, glyphs, decorative
    // highlights) but hurts readability when used as a **filled
    // button background** with white/light label.
    //
    // The `*Bold` variants below are deeper / more saturated so white
    // text on them lands at ≥3:1 (large-text AA) and the eye doesn't
    // strain. Use them on `.borderedProminent` buttons, alert chips,
    // any filled accent surface where text sits inside.
    //
    // Same pattern for `reminderAccentBold` — calendar-red filled
    // contexts get the deeper variant.

    /// Bolder primary accent — for **filled** CTA surfaces.
    /// White-on-this lands ≥3:1 (large text WCAG AA).
    ///
    /// Both light and dark variants are **deeper / more saturated**
    /// than the lighter `accent` so white text on top stays readable.
    /// Counter-intuitive for dark mode (brighter would feel native),
    /// but Apple does the same — `Color.accentColor` system blue is
    /// `#0A84FF` in dark mode, deeper than the light `#007AFF`.
    static var accentBold: Color {
        dynamic(
            UIColor(red: 0.72, green: 0.36, blue: 0.13, alpha: 1.0),  // ~#B85C21 — deeper warm
            UIColor(red: 0.78, green: 0.40, blue: 0.16, alpha: 1.0)   // ~#C66629 — same deep in dark
        )
    }

    /// Bolder reminder accent — for **filled** reminder surfaces.
    /// White-on-this lands ≥3:1 across both modes.
    static var reminderAccentBold: Color {
        dynamic(
            UIColor(red: 0.65, green: 0.18, blue: 0.16, alpha: 1.0),  // ~#A52E29 — deep warm-red
            UIColor(red: 0.72, green: 0.23, blue: 0.21, alpha: 1.0)   // ~#B83A36 — slightly brighter
        )
    }

    // MARK: - Reminders / Split

    /// Reminders accent — the warm calendar-red (`#EB534E`,
    /// RGB 235/83/78). Differentiates Reminders from the warm primary
    /// orange so a reminder pill never reads as a generic accent.
    static var reminderAccent: Color {
        dynamic(
            UIColor(red: 235/255, green: 83/255, blue: 78/255, alpha: 1.0),    // #EB534E
            UIColor(red: 245/255, green: 99/255, blue: 94/255, alpha: 1.0)     // brighter for dark
        )
    }

    /// Split accent — soft lavender (`#B79AD4`, RGB 183/154/212). Pairs
    /// with `splitBackgroundTint` for the "Split atmosphere".
    static var splitAccent: Color {
        dynamic(
            UIColor(red: 183/255, green: 154/255, blue: 212/255, alpha: 1.0),  // #B79AD4
            UIColor(red: 200/255, green: 175/255, blue: 225/255, alpha: 1.0)   // brighter for dark
        )
    }

    /// Reminder card background — warm cream in light, warm near-black in dark.
    static var reminderBackgroundTint: Color {
        dynamic(
            UIColor(red: 0.97, green: 0.93, blue: 0.91, alpha: 1.0),   // light: warm cream
            UIColor(red: 0.08, green: 0.04, blue: 0.04, alpha: 1.0)    // dark: warm near-black
        )
    }

    /// Split surface tint — **muted lavender** in light, violet
    /// near-black in dark. Tuned to be only ~5% saturated so the
    /// page reads as "neutral with a cool whisper" rather than
    /// "purple page" — same low-saturation philosophy as the
    /// `reminderBackgroundTint` warm-cream (which is barely warm,
    /// not "orange page"). A muted base lets the lavender accent
    /// elements actually pop against it.
    static var splitBackgroundTint: Color {
        dynamic(
            UIColor(red: 0.94, green: 0.92, blue: 0.95, alpha: 1.0),  // ~#EFEBF2 muted lavender
            UIColor(red: 0.06, green: 0.05, blue: 0.09, alpha: 1.0)   // dark: violet near-black
        )
    }

    // MARK: - Split sub-palette (mirror of `reminder*` family)
    //
    // Split screens are a "sub-app" with their own coherent surface
    // hierarchy — same vocabulary the Reminders sub-palette already
    // exposes. Without these, list rows / cards on Split screens
    // showed through to the main `backgroundElevated` cream and
    // the Split atmosphere broke at every nested layer.

    /// Card / row fill on Split screens — distinctly more saturated
    /// lavender than `splitBackgroundTint` so cards/rows clearly
    /// "lift" off the page. Earlier near-white whisper variant
    /// (`#F8F4FC`) gave only ~3% brightness diff against the page
    /// `#EFEBF2`, so pills practically disappeared. Now ~7% brighter
    /// with a clearer violet bias — reads as "purple card on subtle
    /// lavender page", not "two near-identical neutrals".
    static var splitCardFill: Color {
        dynamic(
            UIColor(red: 0.99, green: 0.97, blue: 1.00, alpha: 1.0),  // ~#FCF7FF crisp near-white with clear violet
            UIColor.white.withAlphaComponent(0.06)
        )
    }

    /// Chip / pill fill on Split screens — small "interactive but not
    /// primary" surfaces (group filter chips, currency-row pills).
    /// Distinctly more saturated lavender than `splitCardFill` so
    /// chips read as a different surface step (not just "another
    /// card"). Closer to the original spec lavender hue.
    static var splitChipFill: Color {
        dynamic(
            UIColor(red: 0.88, green: 0.83, blue: 0.93, alpha: 1.0),  // ~#E1D3ED clearer lavender chip
            UIColor.white.withAlphaComponent(0.10)
        )
    }

    /// Divider / border colour on Split screens — subtle lavender so
    /// the seams between rows don't fall back to the warm-cream
    /// `border` token (which would clash with the cool lavender).
    static var splitBorder: Color {
        dynamic(
            UIColor(red: 0.85, green: 0.81, blue: 0.89, alpha: 1.0),  // ~#D9CFE3 lavender separator
            UIColor.white.withAlphaComponent(0.10)
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

    /// Destructive / dangerous signal — irreversible actions,
    /// errors, swipe-to-delete. **Hue-distinct from `reminderAccent`**:
    /// reminder is warm calendar-red (hue ~3°, orange-leaning red),
    /// `danger` is wine/rose (hue ~340°, magenta-leaning). The two
    /// reds sit on opposite sides of pure red so the eye reads
    /// "delete" and "reminder fired" as different categories, not
    /// just "different shades of the same red".
    static var danger: Color {
        dynamic(
            UIColor(red: 0.62, green: 0.07, blue: 0.22, alpha: 1.0),  // ~#9F1239 — deep wine/rose
            UIColor(red: 0.85, green: 0.16, blue: 0.42, alpha: 1.0)   // ~#D8296B — vivid rose for dark
        )
    }

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

    /// Outgoing expense — used for "spent X" highlights, expense
    /// trend up, big-purchase deltas. **Neutral by design**: amounts
    /// are weighty (bold) but not coloured — colour is reserved for
    /// signals (reminders, success, danger, primary CTA), not for
    /// everyday spend. Maps to `textPrimary` so the amount stays
    /// prominent without a hue association.
    static var expenseAccent: Color { textPrimary }

    // MARK: - Generic warning (existing usage)
    static var warning: Color { Color(.systemOrange) }

    // MARK: - Border
    //
    // Light mode warm-tinted separator (matches the new warm-cream
    // surface palette). Dark mode stays on system `separator` which
    // is already tuned correctly against dark backgrounds.
    static var border: Color {
        dynamic(
            UIColor(red: 0.84, green: 0.80, blue: 0.76, alpha: 1.0),  // ~#D7CCC2 warm separator
            UIColor.separator
        )
    }

    // MARK: - Trend Bar
    static var trendBarDefault: Color { Color(.label).opacity(0.18) }
    static var trendBarRecent: Color { Color(.label).opacity(0.34) }
    static var trendBarDimmed: Color { Color(.label).opacity(0.08) }
    static var trendBarHovered: Color { Color(.label) }

    // MARK: - Insights / Analytics

    /// Card surface for the Insights screen. Light mode picks up the
    /// warm-cream beige (one step deeper than `backgroundPrimary`) so
    /// the card reads as elevated against the page; **dark mode is
    /// deliberately darker than `backgroundElevated`** so Insights
    /// cards "well" into the screen.
    static var insightCard: Color {
        dynamic(
            UIColor(red: 0.96, green: 0.94, blue: 0.92, alpha: 1.0),   // matches backgroundElevated warm cream
            UIColor(red: 0.08, green: 0.08, blue: 0.09, alpha: 1.0)
        )
    }

    /// Row pill background inside an Insights card. One step lighter
    /// than `insightCard` (more cream/beige) so each row reads as a
    /// distinct chip; in dark, one step lighter than the dark card
    /// surface for the same purpose.
    static var insightRowFill: Color {
        dynamic(
            UIColor(red: 0.99, green: 0.97, blue: 0.95, alpha: 1.0),   // brighter cream than insightCard
            UIColor(red: 0.13, green: 0.13, blue: 0.14, alpha: 1.0)
        )
    }
}

import SwiftUI

// MARK: - Typography Tokens
//
// **Two layers**:
// 1. **Scale tokens** — semantic role-based (display/title/body/caption/...).
//    All NEW code should use these. The redesign can re-tune the entire
//    type scale by editing one definition here without touching views.
// 2. **Legacy tokens** — original `labelPrimary` / `rowAmountInteger` /
//    `balanceInteger` etc. Kept for backwards compatibility with the
//    149 existing callsites. Each maps onto a scale token below.
//    Migration to scale tokens happens in the design-system Step 5
//    sweep — until then, both worlds coexist.
//
// All tokens are **fixed-pt sizes** (not Dynamic-Type-aware). Scaling
// for accessibility is a separate, post-redesign initiative — see the
// audit's "A18 / Dynamic Type" entry. The fonts here are designed for
// the layouts as drawn; flipping to `@ScaledMetric` would re-layout the
// whole app and is intentionally out of scope right now.

enum AppFonts {

    // MARK: - Scale (preferred)

    // ── Display ── extra-large, hero / attention-grabbing ──
    /// 54pt light — balance hero on the home screen.
    static let displayHero = Font.system(size: 54, weight: .light, design: .default)
    /// 36pt bold — sheet hero amount (calendar day detail).
    static let displayLarge = Font.system(size: 36, weight: .bold)
    /// 28pt bold — sheet titles, big stat numbers.
    static let displayMedium = Font.system(size: 28, weight: .bold)

    // ── Title ── primary screen / card titles ──
    /// 26pt bold — card headline questions ("On which day…?").
    static let title = Font.system(size: 26, weight: .bold)
    /// 24pt bold — narrative-card body sentence.
    static let titleSmall = Font.system(size: 24, weight: .bold)
    /// 22pt bold — secondary screen titles, profile name.
    static let heading = Font.system(size: 22, weight: .bold)

    // ── Body ── primary content ──
    /// 17pt medium — primary row labels (transaction title, stat tile).
    static let body = Font.system(size: 17, weight: .medium)
    /// 17pt semibold — emphasized body text, CTA links inside cards.
    static let bodyEmphasized = Font.system(size: 17, weight: .semibold)
    /// 17pt regular — body text without weight emphasis (form inputs,
    /// note tags, friend list rows).
    static let bodyRegular = Font.system(size: 17, weight: .regular)
    /// 18pt medium — slightly larger body for prominent labels (debt
    /// summary headers, picker amount currency, calendar empty-state).
    static let bodyLarge = Font.system(size: 18, weight: .medium)
    /// 15pt medium — secondary row labels.
    static let bodySmall = Font.system(size: 15, weight: .medium)
    /// 15pt semibold — emphasized small body / inline button labels.
    static let bodySmallEmphasized = Font.system(size: 15, weight: .semibold)
    /// 15pt regular — secondary row labels without emphasis.
    static let bodySmallRegular = Font.system(size: 15, weight: .regular)
    /// 18pt semibold — secondary headings, picker section titles.
    static let subhead = Font.system(size: 18, weight: .semibold)

    // ── Caption / Footnote ── auxiliary ──
    /// 14pt regular — row description, body subtitle, helper text.
    static let caption = Font.system(size: 14, weight: .regular)
    /// 14pt medium — emphasized caption / inline label.
    static let captionEmphasized = Font.system(size: 14, weight: .medium)
    /// 14pt semibold — strong caption (chip labels, period pills, calendar
    /// week-day headers).
    static let captionStrong = Font.system(size: 14, weight: .semibold)
    /// 13pt semibold — section header content (use with `sectionHeaderTracking`).
    static let footnote = Font.system(size: 13, weight: .semibold)
    /// 13pt medium — small UI labels (period picker pills, tab chips,
    /// inline metadata).
    static let metaText = Font.system(size: 13, weight: .medium)
    /// 13pt regular — small caption-level labels without emphasis.
    static let metaRegular = Font.system(size: 13, weight: .regular)
    /// 12pt medium — metadata, secondary timestamps.
    static let captionSmall = Font.system(size: 12, weight: .medium)
    /// 12pt semibold — strong small-caption (chip labels, currency-pill
    /// labels, badge text on tiles).
    static let captionSmallStrong = Font.system(size: 12, weight: .semibold)
    /// 11pt semibold — micro labels (badges, pills, accent uppercase tags).
    static let micro = Font.system(size: 11, weight: .semibold)

    // ── Money / Amount ── composable on top of body rows ──
    /// 16pt bold — sign character (`+` / `−`) in amount displays.
    static let amountSign = Font.system(size: 16, weight: .bold)
    /// 19pt bold — integer part of an amount in row contexts.
    static let amountInteger = Font.system(size: 19, weight: .bold)
    /// 14pt medium — cents + currency code in row contexts.
    static let amountCurrency = Font.system(size: 14, weight: .medium)

    // ── Section header ──
    /// Bold uppercase pattern. Use with `.tracking(sectionHeaderTracking)`
    /// and `textCase(.uppercase)`.
    static let sectionHeader = Font.system(size: 13, weight: .bold)
    static let sectionHeaderTracking: CGFloat = 1.0

    // ── Emoji ──
    /// 40pt — standalone hero emoji (splash / onboarding).
    static let emojiHero = Font.system(size: 40)
    /// 34pt — large icon-tile emoji (Insights cards, history hero tiles).
    static let emojiTile = Font.system(size: 34)
    /// 28pt — emoji in transaction-list rows (40×40 frame).
    static let emojiLarge = Font.system(size: 28)
    /// 22pt — emoji in compact tiles (40×40 frame, secondary screens).
    static let emojiMedium = Font.system(size: 22)
    /// 15pt — inline / chip-sized emoji.
    static let emojiSmall = Font.system(size: 15)

    // ── Tab bar / FAB ──
    static let tabIcon = Font.system(size: 24, weight: .regular)
    static let tabLabel = Font.caption2
    static let fabIcon = Font.system(size: 28, weight: .bold)

    // ── Icon glyphs (SF Symbols sized via .font(...)) ──
    /// 36pt light — large empty-state icons (`Image(systemName:)`).
    static let iconHero = Font.system(size: 36, weight: .light)
    /// 20pt regular — standard inline action icons (selection circles,
    /// rotate buttons, picker confirmation glyphs).
    static let iconLarge = Font.system(size: 20)
    /// 10pt semibold — small chevrons / arrows in pills + buttons.
    static let iconSmall = Font.system(size: 10, weight: .semibold)
    /// 9pt semibold — micro chevrons / split badges.
    static let iconMicro = Font.system(size: 9, weight: .semibold)

    // MARK: - Legacy aliases
    //
    // Kept so existing callsites continue to compile during the
    // migration. Each maps onto the closest scale token. Do **not**
    // use these in new code — pick the scale token directly.

    /// Use `displayHero` instead.
    static let balanceInteger = displayHero
    /// Use `displayMedium` (or `Font.system(size: 28, weight: .light)`
    /// directly if you specifically want light weight) instead.
    static let balanceDecimal = Font.system(size: 28, weight: .light)
    /// 32pt medium — balance sign character. No exact scale equivalent;
    /// kept for `BalanceHeaderView`'s specific layout.
    static let balanceSign = Font.system(size: 32, weight: .medium)
    /// 24pt medium — balance currency code. No exact scale equivalent.
    static let balanceCurrency = Font.system(size: 24, weight: .medium)

    /// Use `body` instead. (17pt medium primary row labels.)
    static let labelPrimary = body
    /// Use `bodySmall` instead. (15pt medium secondary row labels.)
    static let labelSecondary = bodySmall
    /// Use `captionEmphasized` instead. (14pt medium.)
    static let labelCaption = captionEmphasized
    /// Use `captionSmall` instead — but with a **bolder weight**.
    /// Original: 12/bold; new captionSmall: 12/medium. Migrate
    /// callsites consciously.
    static let labelSmall = Font.system(size: 12, weight: .bold)

    /// Use `caption` instead.
    static let rowDescription = caption
    /// Use `amountSign` instead.
    static let rowAmountSign = amountSign
    /// Use `amountInteger` instead.
    static let rowAmountInteger = amountInteger
    /// Use `amountCurrency` instead.
    static let rowAmountCurrency = amountCurrency

    /// Use `micro` (11pt semibold) — original was 11pt medium. Slight
    /// weight bump on migration; usually visually indistinguishable.
    static let badgeLabel = Font.system(size: 11, weight: .medium)
}

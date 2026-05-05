import SwiftUI

// MARK: - Pixel Illustration Kit
//
// Lightweight SwiftUI pixel-art primitives shared by all
// `*Illustration` views in this folder.
//
// Why this exists: every illustration is a grid of coloured cells +
// some animated overlay. Repeating the same `Canvas` pixel-fill helper
// across each file would bloat the call sites. Centralising here means
// a new illustration is ~30 lines (palette + cell list + overlay).
//
// **Drawing model**
// Every illustration draws onto a fixed virtual grid (typically 14×14)
// centered in a square frame. The view scales the grid up so each cell
// renders at integer multiples of `1pt` — no anti-aliasing on cell
// edges, the look stays crisply pixel.
//
// All animation is driven by `TimelineView(.animation)` — no
// per-illustration `@State` clocks. Cheaper, simpler, and means
// illustrations pause cleanly when off-screen.

// MARK: - PixelGrid
//
// One grid cell = one logical "pixel" of the illustration. Stored as
// (col, row, width, height, color) so a cell can span multiple grid
// units (used when adjacent same-coloured cells are drawn as a single
// rect — keeps cell counts manageable).

struct PixelCell {
    let col: Int
    let row: Int
    let width: Int
    let height: Int
    let color: Color

    init(_ col: Int, _ row: Int, _ width: Int = 1, _ height: Int = 1, _ color: Color) {
        self.col = col
        self.row = row
        self.width = width
        self.height = height
        self.color = color
    }
}

// MARK: - Drawing helper

extension GraphicsContext {
    /// Fills a `PixelCell` onto the context, scaling by `unit` (size of
    /// one grid cell in points). Optional `xOffset` / `yOffset` are in
    /// grid units, used by animation code to shift parts of the
    /// illustration (e.g. a breathing body offset by 0.5 cells).
    ///
    /// Each rect is **expanded by 0.5pt on every side** so adjacent
    /// cells overlap by 1pt — this hides the hairline gaps that the
    /// renderer's anti-aliasing leaves between perfectly-tiled cells
    /// at fractional unit sizes. Same trick as the splash-screen pixel
    /// art used to fix sub-pixel seams.
    mutating func fill(
        _ cell: PixelCell,
        unit: CGFloat,
        xOffset: CGFloat = 0,
        yOffset: CGFloat = 0
    ) {
        let bleed: CGFloat = 0.5
        let rect = CGRect(
            x: (CGFloat(cell.col) + xOffset) * unit - bleed,
            y: (CGFloat(cell.row) + yOffset) * unit - bleed,
            width: CGFloat(cell.width) * unit + bleed * 2,
            height: CGFloat(cell.height) * unit + bleed * 2
        )
        fill(Path(rect), with: .color(cell.color))
    }
}

// MARK: - PixelTint
//
// Tint vocabulary every illustration speaks. Gives callers one knob
// (`tint: PixelTint`) instead of three separate colours, and ensures
// the lighter / darker derivations stay coherent across the family.

struct PixelTint: Equatable {
    /// Main body / structure colour.
    let body: Color
    /// Lighter variant for highlights (cat belly, plant inner leaf).
    let light: Color
    /// Darker variant for accent details (closed eye, ear inside).
    let dark: Color

    /// Neutral grayscale — the default for empty-state illustrations
    /// where the figure should recede behind the copy.
    ///
    /// Hand-tuned light/dark values rather than `Color(.systemGray*)`
    /// because the system grays invert "wrong" for illustrations:
    /// `systemGray3` is light-on-light in light mode but **dark**-on-
    /// dark in dark mode, so a cat made of system grays disappears in
    /// dark. We need the **same perceptual lightness** in both modes —
    /// medium-light gray that reads against white *or* black.
    static let neutral = PixelTint(
        body: Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.62, alpha: 1.0)   // bright enough to show on dark bg
                : UIColor(white: 0.72, alpha: 1.0)   // medium gray on white bg
        }),
        light: Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.78, alpha: 1.0)   // belly highlight
                : UIColor(white: 0.85, alpha: 1.0)
        }),
        dark: Color(UIColor { trait in
            trait.userInterfaceStyle == .dark
                ? UIColor(white: 0.45, alpha: 1.0)   // accent detail darker than body
                : UIColor(white: 0.50, alpha: 1.0)
        })
    )

    /// Warm primary (Maple-orange) — for celebratory / brand moments.
    static let primary = PixelTint(
        body: AppColors.accent,
        light: AppColors.accent.opacity(0.5),
        dark: AppColors.accent.opacity(0.85)
    )

    /// Reminders palette — calendar-red.
    static let reminders = PixelTint(
        body: AppColors.reminderAccent,
        light: AppColors.reminderAccent.opacity(0.5),
        dark: AppColors.reminderAccent.opacity(0.85)
    )

    /// Split palette — soft lavender.
    static let split = PixelTint(
        body: AppColors.splitAccent,
        light: AppColors.splitAccent.opacity(0.5),
        dark: AppColors.splitAccent.opacity(0.85)
    )

    /// Success — system green.
    static let success = PixelTint(
        body: AppColors.success,
        light: AppColors.success.opacity(0.5),
        dark: AppColors.success.opacity(0.85)
    )
}

// MARK: - PixelIllustrationSize

enum PixelIllustrationSize {
    case compact   // 80pt — inline pill row
    case standard  // 120pt — list-screen empty
    case hero      // 180pt — full-page empty / splash

    var points: CGFloat {
        switch self {
        case .compact:  return 80
        case .standard: return 120
        case .hero:     return 180
        }
    }
}

import SwiftUI

// MARK: - Sleeping Cat Illustration
//
// Curled-up sleeping cat — the canonical "nothing to do here yet"
// figure. Used in:
//   - `EmptyTransactionsView` (Home empty state, replaces Lottie)
//   - generic empty-state placeholders elsewhere
//
// **Animation**
//   - The whole body sways ±0.15 grid units vertically over a 3.2s
//     cycle (gentle breathing).
//   - Three "Z"s drift up out of frame in sequence, each fading in
//     and out over a 3s cycle, staggered 1s apart.
//
// **Theming**
// Pass `tint: PixelTint` to colour the figure. Defaults to
// `.neutral` (system grayscale) so the empty state doesn't shout.
// For Reminders / Split contexts, pass `.reminders` or `.split` —
// the body colour, lighter belly, and darker eye/detail all flip
// together.

struct SleepingCatIllustration: View {

    var tint: PixelTint = .neutral
    var size: PixelIllustrationSize = .standard

    /// Grid resolution. Matches the HTML reference's 14-unit grid so
    /// the proportions translate 1:1.
    private let gridSize: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, canvasSize in
                let unit = canvasSize.width / CGFloat(gridSize)

                // Breathing offset: ±0.15 grid units over a 3.2s cycle.
                let breathPhase = sin(t * (2 * .pi / 3.2))
                let breathOffsetY = CGFloat(breathPhase) * 0.15

                drawBody(in: &ctx, unit: unit, yOffset: breathOffsetY)
                drawZs(in: &ctx, unit: unit, t: t)
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityHidden(true)
    }

    // MARK: - Body
    //
    // Coordinates translated from the HTML reference 1:1 (each `rect`
    // there at 10×10pt becomes one grid cell at our resolution). Layer
    // order matches HTML: body underneath, belly + detail on top.

    private func drawBody(
        in ctx: inout GraphicsContext,
        unit: CGFloat,
        yOffset: CGFloat
    ) {
        let body = tint.body
        let light = tint.light
        let dark = tint.dark

        // Body cells (under-layer)
        let bodyCells: [PixelCell] = [
            // main rounded body
            PixelCell(2, 9, 10, 1, body),
            PixelCell(2, 10, 11, 1, body),
            PixelCell(2, 11, 11, 1, body),
            PixelCell(3, 12, 9, 1, body),

            // head tucked into curl
            PixelCell(2, 8, 2, 1, body),
            PixelCell(1, 9, 1, 1, body),
            PixelCell(1, 8, 1, 1, body),
            PixelCell(2, 7, 1, 1, body),

            // ear tip (inner ear is detail-coloured below)
            // (2,7) is part of body, (3,7) is detail

            // tail curled up around the right side
            PixelCell(13, 10, 1, 2, body),
            PixelCell(12, 12, 1, 1, body),
        ]
        for cell in bodyCells {
            ctx.fill(cell, unit: unit, yOffset: yOffset)
        }

        // Lighter belly + chest highlight
        let bellyCells: [PixelCell] = [
            PixelCell(4, 11, 7, 1, light),
            PixelCell(5, 12, 5, 1, light),
        ]
        for cell in bellyCells {
            ctx.fill(cell, unit: unit, yOffset: yOffset)
        }

        // Dark detail: ear-tip dot + closed eye
        let detailCells: [PixelCell] = [
            PixelCell(3, 7, 1, 1, dark),    // ear tip / inner ear
            PixelCell(2, 9, 2, 1, dark),    // closed eye stripe
        ]
        for cell in detailCells {
            ctx.fill(cell, unit: unit, yOffset: yOffset)
        }
    }

    // MARK: - Sleeping "Z"s
    //
    // Three Z marks, each a 3-pixel diagonal stroke (top, middle,
    // bottom) drawn as 3 separate cells. Each Z drifts up ~3 grid
    // units while fading in then out over a 3s cycle, staggered 1s
    // apart — at any moment 1–2 Z's are visible on screen.

    private func drawZs(
        in ctx: inout GraphicsContext,
        unit: CGFloat,
        t: TimeInterval
    ) {
        let cycle: TimeInterval = 3.0
        let starts: [CGPoint] = [
            CGPoint(x: 10, y: 5),   // largest, lowest start
            CGPoint(x: 8.5, y: 3.5),
            CGPoint(x: 7.2, y: 2.0),
        ]
        let scales: [CGFloat] = [1.0, 0.8, 0.6]

        for (index, origin) in starts.enumerated() {
            let delay = TimeInterval(index) * 1.0
            let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
            // Drift up by 2 grid units across the cycle
            let driftUp = CGFloat(phase) * 2.0
            // Opacity: triangle envelope (0 → 1 → 0 across the cycle)
            let opacity = 1.0 - abs(CGFloat(phase) * 2.0 - 1.0)

            let scale = scales[index]
            let zColor = tint.body.opacity(opacity)

            // Z is 3 cells: top stroke, diagonal mid, bottom stroke.
            // Drawn as scaled small rects so the smaller Z's stay
            // sharp at their reduced size.
            let zCells: [PixelCell] = [
                PixelCell(0, 0, 3, 1, zColor),   // top
                PixelCell(1, 1, 1, 1, zColor),   // diagonal mid
                PixelCell(0, 2, 3, 1, zColor),   // bottom
            ]

            for cell in zCells {
                let xCell = origin.x + CGFloat(cell.col) * scale
                let yCell = origin.y + CGFloat(cell.row) * scale - driftUp

                let rect = CGRect(
                    x: xCell * unit,
                    y: yCell * unit,
                    width: CGFloat(cell.width) * scale * unit,
                    height: CGFloat(cell.height) * scale * unit
                )
                ctx.fill(Path(rect), with: .color(zColor))
            }
        }
    }
}

// MARK: - Preview

#Preview("Neutral") {
    SleepingCatIllustration()
        .padding()
}

#Preview("Reminders tint") {
    SleepingCatIllustration(tint: .reminders, size: .hero)
        .padding()
}

#Preview("Split tint") {
    SleepingCatIllustration(tint: .split, size: .hero)
        .padding()
}

import SwiftUI

// MARK: - Search Illustration
//
// Magnifying glass + small peeking cat at the bottom. For
// "no results found" empty states (search, filter-with-zero-hits).
//
// **Animation**
//   - The magnifier drifts in a subtle diamond pattern across a 4s
//     loop — reinforces "actively searching".
//   - The cat at the bottom blinks at irregular intervals (eyes
//     close briefly every ~3s).

struct SearchIllustration: View {

    var tint: PixelTint = .neutral
    var size: PixelIllustrationSize = .standard

    private let gridSize: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, canvasSize in
                let unit = canvasSize.width / CGFloat(gridSize)

                drawCat(in: &ctx, unit: unit, t: t)
                drawMagnifier(in: &ctx, unit: unit, t: t)
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityHidden(true)
    }

    // MARK: - Peeking cat (lower-right corner)

    private func drawCat(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        let body = tint.body
        let dark = tint.dark

        // Body shape (peeking from below the bottom edge)
        let bodyCells: [PixelCell] = [
            PixelCell(8, 9, 4, 1, body),    // ear ridge
            PixelCell(7, 10, 6, 1, body),
            PixelCell(7, 11, 6, 1, body),
            PixelCell(8, 12, 4, 1, body),
        ]
        for cell in bodyCells {
            ctx.fill(cell, unit: unit)
        }

        // Eyes — blink every ~3s. Closed eye = single pixel of dark
        // (instead of vertical 1×1 open eye).
        let blinkCycle: TimeInterval = 3.0
        let phase = t.truncatingRemainder(dividingBy: blinkCycle) / blinkCycle
        let isBlinking = phase > 0.92  // blink for last 8% of cycle (~0.24s)

        if isBlinking {
            // Closed eyes — short horizontal lines
            ctx.fill(PixelCell(8, 11, 1, 1, dark), unit: unit)
            ctx.fill(PixelCell(11, 11, 1, 1, dark), unit: unit)
        } else {
            // Open eyes — single dark pixels
            ctx.fill(PixelCell(8, 10, 1, 1, dark), unit: unit)
            ctx.fill(PixelCell(11, 10, 1, 1, dark), unit: unit)
        }
    }

    // MARK: - Magnifier (drifts)

    private func drawMagnifier(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        let body = tint.body
        let inner = tint.light
        let dark = tint.dark

        // Diamond drift pattern — 4-second cycle, ±1 cell in each
        // direction.
        let cycle: TimeInterval = 4.0
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let driftX = sin(phase * 2 * .pi) * 1.0
        let driftY = cos(phase * 2 * .pi) * 0.5

        // Lens (rounded square): 5×5 cells, with corners removed
        let lensX = 1.5 + driftX
        let lensY = 1.5 + driftY

        let lensCells: [PixelCell] = [
            // Top/bottom edges
            PixelCell(1, 0, 3, 1, body),
            PixelCell(1, 4, 3, 1, body),
            // Left/right edges
            PixelCell(0, 1, 1, 3, body),
            PixelCell(4, 1, 1, 3, body),
            // Inner glass
            PixelCell(1, 1, 3, 3, inner),
            // Lens highlight (top-left)
            PixelCell(1, 1, 2, 1, body.opacity(0.4)),
        ]
        for cell in lensCells {
            ctx.fill(
                cell,
                unit: unit,
                xOffset: lensX,
                yOffset: lensY
            )
        }

        // Handle — diagonal stroke from lower-right of lens
        let handleCells: [PixelCell] = [
            PixelCell(4, 4, 1, 1, dark),
            PixelCell(5, 5, 1, 1, dark),
        ]
        for cell in handleCells {
            ctx.fill(
                cell,
                unit: unit,
                xOffset: lensX,
                yOffset: lensY
            )
        }
    }
}

#Preview("Neutral") {
    SearchIllustration(size: .hero)
        .padding()
}

#Preview("Reminders") {
    SearchIllustration(tint: .reminders, size: .hero)
        .padding()
}

#Preview("Dark") {
    SearchIllustration(size: .hero)
        .padding()
        .preferredColorScheme(.dark)
}

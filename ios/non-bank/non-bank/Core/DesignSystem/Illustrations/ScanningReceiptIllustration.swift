import SwiftUI

// MARK: - Scanning Receipt Illustration
//
// Pixel-art receipt with a magnifying glass slowly sweeping over the
// item rows — visual vocabulary for "we're reading your receipt right
// now". Same drawing kit as the empty-state family
// (`SearchIllustration`, `EmptyBoxIllustration`, …) so the loader
// reads as part of the same visual world.
//
// **Animation**
//   - The magnifier travels top→bottom→top across the item rows on a
//     3.2-second triangle-wave cycle. Slow enough to clearly "examine"
//     each line, quick enough that the loop never feels stalled.
//   - Three sparkle pixels around the glass twinkle (alpha-fade) on
//     staggered phases — reinforces the "AI processing" feel without
//     a separate progress glyph.

struct ScanningReceiptIllustration: View {

    var tint: PixelTint = .neutral
    var size: PixelIllustrationSize = .standard

    private let gridSize: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, canvasSize in
                let unit = canvasSize.width / CGFloat(gridSize)

                drawReceipt(in: &ctx, unit: unit)
                drawMagnifier(in: &ctx, unit: unit, t: t)
                drawSparkles(in: &ctx, unit: unit, t: t)
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityHidden(true)
    }

    // MARK: - Receipt (static)

    private func drawReceipt(in ctx: inout GraphicsContext, unit: CGFloat) {
        let body = tint.body
        let inner = tint.light
        let dark = tint.dark

        // Outline — single-pixel border drawn as four edges so it stays
        // crisp at every illustration size.
        let outline: [PixelCell] = [
            PixelCell(3, 1, 8, 1, body),    // top edge
            PixelCell(3, 12, 8, 1, body),   // bottom edge
            PixelCell(3, 2, 1, 10, body),   // left edge
            PixelCell(10, 2, 1, 10, body),  // right edge
        ]
        for cell in outline { ctx.fill(cell, unit: unit) }

        // Paper interior — the lighter tint variant, so text rows on
        // top read with reasonable contrast against the page.
        ctx.fill(PixelCell(4, 2, 6, 10, inner), unit: unit)

        // Text rows — header, then a stack of item lines with naturally
        // varying widths, then a total line slightly wider/bolder. The
        // gaps between rows are intentional whitespace on the paper.
        let textRows: [PixelCell] = [
            PixelCell(5, 3, 4, 1, dark),    // header
            PixelCell(5, 5, 3, 1, dark),    // item 1
            PixelCell(5, 7, 4, 1, dark),    // item 2
            PixelCell(5, 9, 2, 1, dark),    // item 3
            PixelCell(5, 11, 4, 1, body),   // total (uses body for emphasis)
        ]
        for cell in textRows { ctx.fill(cell, unit: unit) }
    }

    // MARK: - Magnifier (drifts vertically)

    private func drawMagnifier(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        let body = tint.body
        let inner = tint.light
        let dark = tint.dark

        // Triangle-wave sweep over the receipt item rows. `phase < 0.5`
        // is the way down, `phase >= 0.5` is the way back up — gives a
        // back-and-forth scan without a hard reset.
        let cycle: TimeInterval = 3.2
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let triangle: Double = phase < 0.5 ? phase * 2 : (1 - phase) * 2
        // Sweep yOffset over rows 1..6 so the lens centre lands on rows
        // 3..8 (covering header through item 3).
        let yOffset = 1.0 + triangle * 5.0
        let xOffset: Double = 6.5  // sits slightly right of receipt centre

        // 5×5 lens — same shape vocabulary as `SearchIllustration` so the
        // two illustrations feel like family.
        let lensCells: [PixelCell] = [
            PixelCell(1, 0, 3, 1, body),       // top edge
            PixelCell(1, 4, 3, 1, body),       // bottom edge
            PixelCell(0, 1, 1, 3, body),       // left edge
            PixelCell(4, 1, 1, 3, body),       // right edge
            PixelCell(1, 1, 3, 3, inner),      // glass
            PixelCell(1, 1, 2, 1, body.opacity(0.4)),  // top-left highlight
        ]
        for cell in lensCells {
            ctx.fill(cell, unit: unit, xOffset: xOffset, yOffset: yOffset)
        }

        // Diagonal handle stroking out from the lens's lower-right.
        let handleCells: [PixelCell] = [
            PixelCell(4, 4, 1, 1, dark),
            PixelCell(5, 5, 1, 1, dark),
        ]
        for cell in handleCells {
            ctx.fill(cell, unit: unit, xOffset: xOffset, yOffset: yOffset)
        }
    }

    // MARK: - Sparkles (twinkle around the glass)

    private func drawSparkles(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        // Three sparkle positions — fixed in the grid, alpha-modulated
        // on staggered phases so they twinkle out-of-phase. Conveys
        // "AI is doing magic" without a separate spinner glyph.
        let sparkles: [(col: Int, row: Int, phaseOffset: Double)] = [
            (1, 4, 0.0),
            (12, 6, 0.33),
            (2, 9, 0.66),
        ]
        let cycle: TimeInterval = 1.6
        for spark in sparkles {
            let p = ((t / cycle) + spark.phaseOffset).truncatingRemainder(dividingBy: 1.0)
            // Bell-curve fade — 0 at the edges, 1 in the middle of each
            // local cycle.
            let alpha = sin(p * .pi)
            guard alpha > 0.05 else { continue }
            ctx.fill(
                PixelCell(spark.col, spark.row, 1, 1, tint.body.opacity(alpha)),
                unit: unit
            )
        }
    }
}

#Preview("Neutral") {
    ScanningReceiptIllustration(size: .hero)
        .padding()
}

#Preview("Primary") {
    ScanningReceiptIllustration(tint: .primary, size: .hero)
        .padding()
}

#Preview("Dark") {
    ScanningReceiptIllustration(size: .hero)
        .padding()
        .preferredColorScheme(.dark)
}

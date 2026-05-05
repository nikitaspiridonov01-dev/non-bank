import SwiftUI

// MARK: - Empty Box Illustration
//
// Open cardboard box with floating dust motes. The "this list is
// empty" figure — different visual vocabulary from `SleepingCat`
// for screens that need a non-cat alternative (split transactions
// list, search-with-zero-hits, generic data-list empty states).
//
// **Animation**
//   - Dashed line inside the box pulses (3 stops staggered) so the
//     emptiness reads as "actively empty" rather than static.
//   - Two dust motes drift up and fade out across a 2–2.5s cycle,
//     reinforcing the "nothing settled here" feel.

struct EmptyBoxIllustration: View {

    var tint: PixelTint = .neutral
    var size: PixelIllustrationSize = .standard

    private let gridSize: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, canvasSize in
                let unit = canvasSize.width / CGFloat(gridSize)

                drawBox(in: &ctx, unit: unit, t: t)
                drawDust(in: &ctx, unit: unit, t: t)
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityHidden(true)
    }

    // MARK: - Box body

    private func drawBox(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        let body = tint.body
        let dark = tint.dark
        let inner = tint.light

        let boxCells: [PixelCell] = [
            // Side walls
            PixelCell(3, 5, 1, 7, body),
            PixelCell(10, 5, 1, 7, body),
            // Bottom
            PixelCell(3, 11, 8, 1, body),
            // Inner shadow (slightly darker to suggest depth)
            PixelCell(4, 5, 6, 6, inner),
            PixelCell(4, 11, 6, 1, dark),
            // Open flaps (top edges)
            PixelCell(3, 3, 2, 2, body),
            PixelCell(4, 2, 1, 1, dark),
            PixelCell(9, 3, 2, 2, body),
            PixelCell(9, 2, 1, 1, dark),
        ]
        for cell in boxCells {
            ctx.fill(cell, unit: unit)
        }

        // Pulsing dashed line — 3 dots pulse staggered. Dots are 1×1
        // cells centred horizontally inside the box. Cycle 1.5s.
        let dotPositions: [(Int, Int)] = [(5, 7), (7, 7), (9, 7)]
        let cycle: TimeInterval = 1.5
        for (index, pos) in dotPositions.enumerated() {
            let delay = TimeInterval(index) * 0.3
            let phase = ((t - delay).truncatingRemainder(dividingBy: cycle)) / cycle
            let opacity = 0.3 + 0.7 * abs(sin(phase * .pi))
            ctx.fill(
                PixelCell(pos.0, pos.1, 1, 1, body.opacity(opacity)),
                unit: unit
            )
        }
    }

    // MARK: - Floating dust

    private func drawDust(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        // Two dust motes drifting up out of the box, fading.
        let motes: [(start: CGPoint, cycle: TimeInterval, delay: TimeInterval)] = [
            (CGPoint(x: 6.5, y: 4.5), 2.5, 0),
            (CGPoint(x: 8.0, y: 4.0), 2.8, 0.7),
        ]

        for mote in motes {
            let phase = ((t - mote.delay).truncatingRemainder(dividingBy: mote.cycle)) / mote.cycle
            let yPos = CGFloat(mote.start.y) - CGFloat(phase) * 4.0   // drift up 4 cells
            let opacity = 1.0 - abs(CGFloat(phase) * 2.0 - 1.0)         // fade in then out

            let rect = CGRect(
                x: CGFloat(mote.start.x) * unit - unit * 0.25,
                y: yPos * unit - unit * 0.25,
                width: unit * 0.5,
                height: unit * 0.5
            )
            ctx.fill(Path(rect), with: .color(tint.body.opacity(opacity)))
        }
    }
}

#Preview("Neutral") {
    EmptyBoxIllustration(size: .hero)
        .padding()
}

#Preview("Reminders tint") {
    EmptyBoxIllustration(tint: .reminders, size: .hero)
        .padding()
}

#Preview("Split tint") {
    EmptyBoxIllustration(tint: .split, size: .hero)
        .padding()
}

#Preview("Dark") {
    EmptyBoxIllustration(size: .hero)
        .padding()
        .preferredColorScheme(.dark)
}

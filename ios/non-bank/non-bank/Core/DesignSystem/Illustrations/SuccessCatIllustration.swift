import SwiftUI

// MARK: - Success Cat Illustration
//
// Bouncing happy cat with falling confetti — the celebratory figure
// for post-action successes (split saved, sync completed, reminder
// resolved). Works as a one-shot moment or a longer-running celebration
// depending on the host context.
//
// **Animation**
//   - Cat bounces up and down across a 0.8s cycle (squash-and-stretch
//     vibe).
//   - Four confetti pieces rain from random staggered start positions,
//     each drifting down at its own speed and fading near the bottom.

struct SuccessCatIllustration: View {

    var tint: PixelTint = .success
    var size: PixelIllustrationSize = .standard

    private let gridSize: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, canvasSize in
                let unit = canvasSize.width / CGFloat(gridSize)

                drawConfetti(in: &ctx, unit: unit, t: t)
                drawCat(in: &ctx, unit: unit, t: t)
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityHidden(true)
    }

    // MARK: - Bouncing cat

    private func drawCat(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        // Bounce: -0.5 cell at peak, 0 at rest, ~0.8s cycle
        let cycle: TimeInterval = 0.8
        let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
        let bounceY = -abs(sin(phase * .pi)) * 0.5

        let body = tint.body
        let light = tint.light
        let dark = tint.dark

        // Body shape — sitting upright, looking front
        let cells: [PixelCell] = [
            // Ears
            PixelCell(4, 4, 1, 1, body),
            PixelCell(9, 4, 1, 1, body),
            PixelCell(5, 4, 1, 1, body),
            PixelCell(8, 4, 1, 1, body),
            // Inner ears
            PixelCell(4, 5, 1, 1, dark),
            PixelCell(9, 5, 1, 1, dark),

            // Head
            PixelCell(3, 5, 8, 1, body),
            PixelCell(3, 6, 8, 1, body),
            PixelCell(3, 7, 8, 1, body),

            // Happy ^ ^ eyes
            PixelCell(4, 6, 1, 1, dark),
            PixelCell(5, 7, 1, 1, dark),
            PixelCell(6, 6, 0, 0, .clear),  // gap (no draw)
            PixelCell(8, 6, 1, 1, dark),
            PixelCell(9, 7, 1, 1, dark),

            // Smile
            PixelCell(5, 8, 4, 1, dark),

            // Body
            PixelCell(3, 9, 8, 1, body),
            PixelCell(3, 10, 8, 1, body),
            PixelCell(3, 11, 8, 1, body),
            // Belly highlight
            PixelCell(5, 10, 4, 1, light),
            PixelCell(5, 11, 4, 1, light),

            // Paws
            PixelCell(4, 12, 2, 1, body),
            PixelCell(8, 12, 2, 1, body),
        ]
        for cell in cells where cell.width > 0 {
            ctx.fill(cell, unit: unit, yOffset: bounceY)
        }
    }

    // MARK: - Confetti

    private func drawConfetti(in ctx: inout GraphicsContext, unit: CGFloat, t: TimeInterval) {
        let pieces: [(start: CGPoint, cycle: TimeInterval, delay: TimeInterval, color: Color)] = [
            (CGPoint(x: 1, y: 1), 2.0, 0.0, AppColors.accent),
            (CGPoint(x: 12, y: 2), 2.3, 0.4, AppColors.success),
            (CGPoint(x: 11, y: 0), 2.5, 0.9, AppColors.accent),
            (CGPoint(x: 2, y: 0), 2.2, 1.3, AppColors.success),
        ]

        for piece in pieces {
            let phase = ((t - piece.delay).truncatingRemainder(dividingBy: piece.cycle)) / piece.cycle
            let yPos = CGFloat(piece.start.y) + CGFloat(phase) * 12.0  // fall to bottom
            let opacity = 1.0 - max(0, (CGFloat(phase) - 0.7) / 0.3)    // fade in last 30%

            let rect = CGRect(
                x: CGFloat(piece.start.x) * unit - unit * 0.25,
                y: yPos * unit - unit * 0.25,
                width: unit * 0.6,
                height: unit * 0.6
            )
            ctx.fill(Path(rect), with: .color(piece.color.opacity(opacity)))
        }
    }
}

#Preview("Success default") {
    SuccessCatIllustration(size: .hero)
        .padding()
}

#Preview("Reminders") {
    SuccessCatIllustration(tint: .reminders, size: .hero)
        .padding()
}

#Preview("Dark") {
    SuccessCatIllustration(size: .hero)
        .padding()
        .preferredColorScheme(.dark)
}

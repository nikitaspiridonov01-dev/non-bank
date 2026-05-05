import SwiftUI

// MARK: - Growing Plant Illustration
//
// Pot with a stem that grows leaves over time, ending with a small
// sparkle at the top of the bud. Encouraging "let's start growing"
// figure for onboarding and "Nothing to analyse yet"-style empty
// states where the message is "add data and watch it grow".
//
// **Animation**
//   - Stem rises from soil over the first ~1.5s.
//   - Two leaves fade in staggered (left at 1.5s, right at 2s).
//   - A small bud appears at the top at 2.5s.
//   - Sparkle pulses at the top continuously after 3s — the loop
//     point. Cycle length: 4s, then resets and replays.

struct GrowingPlantIllustration: View {

    var tint: PixelTint = .success
    var size: PixelIllustrationSize = .standard

    private let gridSize: Int = 14

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate

            Canvas { ctx, canvasSize in
                let unit = canvasSize.width / CGFloat(gridSize)
                let cycle: TimeInterval = 4.0
                let phase = t.truncatingRemainder(dividingBy: cycle)

                drawPot(in: &ctx, unit: unit)
                drawStem(in: &ctx, unit: unit, phase: phase)
                drawLeaves(in: &ctx, unit: unit, phase: phase)
                drawBudAndSparkle(in: &ctx, unit: unit, t: t, phase: phase)
            }
        }
        .frame(width: size.points, height: size.points)
        .accessibilityHidden(true)
    }

    // MARK: - Pot

    private func drawPot(in ctx: inout GraphicsContext, unit: CGFloat) {
        let body = tint.body
        let dark = tint.dark
        // Pot — wider at top, narrower at bottom. Soil rim on top.
        let cells: [PixelCell] = [
            // Soil rim
            PixelCell(4, 10, 6, 1, dark),
            // Pot body (orange-ish in original, here uses tint.body so theming holds)
            PixelCell(4, 11, 6, 1, body),
            PixelCell(5, 12, 4, 1, body),
            PixelCell(5, 13, 4, 1, body),
        ]
        for cell in cells {
            ctx.fill(cell, unit: unit)
        }
    }

    // MARK: - Stem (animated grow)

    private func drawStem(in ctx: inout GraphicsContext, unit: CGFloat, phase: TimeInterval) {
        // Stem grows from y=10 up to y=5 over the first 1.5s.
        let growProgress = min(phase / 1.5, 1.0)
        let topRow = 10 - Int(round(5 * growProgress))   // 10 → 5

        // Single column at col=6, from topRow to 9
        for row in topRow...9 {
            ctx.fill(
                PixelCell(6, row, 1, 1, tint.light),
                unit: unit
            )
            ctx.fill(
                PixelCell(7, row, 1, 1, tint.body),
                unit: unit
            )
        }
    }

    // MARK: - Leaves (staggered fade-in)

    private func drawLeaves(in ctx: inout GraphicsContext, unit: CGFloat, phase: TimeInterval) {
        // Left leaf appears at 1.5s, fades in over 0.5s
        let leftAlpha = clamp((phase - 1.5) / 0.5, 0, 1)
        // Right leaf appears at 2.0s, fades in over 0.5s
        let rightAlpha = clamp((phase - 2.0) / 0.5, 0, 1)

        if leftAlpha > 0 {
            let cells: [PixelCell] = [
                PixelCell(3, 6, 3, 1, tint.body.opacity(leftAlpha)),
                PixelCell(4, 7, 2, 1, tint.body.opacity(leftAlpha)),
                PixelCell(4, 6, 1, 1, tint.light.opacity(leftAlpha)),
            ]
            for cell in cells { ctx.fill(cell, unit: unit) }
        }

        if rightAlpha > 0 {
            let cells: [PixelCell] = [
                PixelCell(8, 7, 3, 1, tint.body.opacity(rightAlpha)),
                PixelCell(8, 8, 2, 1, tint.body.opacity(rightAlpha)),
                PixelCell(9, 7, 1, 1, tint.light.opacity(rightAlpha)),
            ]
            for cell in cells { ctx.fill(cell, unit: unit) }
        }
    }

    // MARK: - Bud + sparkle

    private func drawBudAndSparkle(
        in ctx: inout GraphicsContext,
        unit: CGFloat,
        t: TimeInterval,
        phase: TimeInterval
    ) {
        // Bud appears at 2.5s
        let budAlpha = clamp((phase - 2.5) / 0.5, 0, 1)
        if budAlpha > 0 {
            let cells: [PixelCell] = [
                PixelCell(6, 4, 2, 1, tint.body.opacity(budAlpha)),
                PixelCell(6, 3, 2, 1, tint.body.opacity(budAlpha)),
            ]
            for cell in cells { ctx.fill(cell, unit: unit) }
        }

        // Sparkle pulses after 3s (continuous independent of phase)
        if phase >= 3.0 {
            let sparkleCycle: TimeInterval = 1.5
            let sparklePhase = t.truncatingRemainder(dividingBy: sparkleCycle) / sparkleCycle
            let sparkleAlpha = abs(sin(sparklePhase * .pi))
            ctx.fill(
                PixelCell(6, 2, 2, 1, AppColors.accent.opacity(sparkleAlpha)),
                unit: unit
            )
        }
    }

    private func clamp(_ value: TimeInterval, _ min: TimeInterval, _ max: TimeInterval) -> CGFloat {
        CGFloat(Swift.min(max, Swift.max(min, value)))
    }
}

#Preview("Success") {
    GrowingPlantIllustration(size: .hero)
        .padding()
}

#Preview("Primary") {
    GrowingPlantIllustration(tint: .primary, size: .hero)
        .padding()
}

#Preview("Dark") {
    GrowingPlantIllustration(size: .hero)
        .padding()
        .preferredColorScheme(.dark)
}

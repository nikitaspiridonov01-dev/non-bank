import SwiftUI

/// A one-shot celebratory confetti / fireworks burst, drawn in pure
/// SwiftUI with no third-party packages.
///
/// Used by `TipJarView` as a transient overlay after a successful tip
/// purchase: a couple of bursts of warm-toned particles fan out from
/// the upper-middle of the screen, arc under gravity, fade, and the
/// whole view removes itself once the animation completes.
///
/// Rendering is done with a single `Canvas` driven by a `TimelineView`
/// animation clock, so the hundred-odd particles cost one layer rather
/// than one `View` each. Colours come from the warm design tokens
/// (`AppColors.accent` family + reminder/split hues) so the burst sits
/// inside the app's palette instead of pulling in raw system colours.
///
/// `allowsHitTesting(false)` means it never blocks the "Thank you!"
/// content or the close affordance underneath it. Honours Reduce Motion
/// by collapsing to a brief, static, low-key sparkle.
struct FireworksView: View {
    /// Total run time of the burst before it should be torn down.
    /// `TipJarView` matches its removal timer to this value.
    static let duration: TimeInterval = 2.2

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// A single confetti particle. Position is computed analytically
    /// from the elapsed time so we never have to mutate per-frame state.
    private struct Particle {
        let origin: UnitPoint        // launch point (fraction of canvas)
        let angle: Double            // radians, direction of travel
        let speed: Double            // points / second, initial
        let color: Color
        let size: CGFloat
        let spin: Double             // radians / second
        let delay: TimeInterval      // stagger so bursts don't all pop at t=0
    }

    private let particles: [Particle]
    private let start = Date()

    init() {
        // Two launch points (upper-left-of-centre and upper-right-of-
        // centre) so the burst reads as "fireworks" rather than a single
        // fountain. Warm-palette colour set only.
        let palette: [Color] = [
            AppColors.accent,
            AppColors.accentBold,
            AppColors.reminderAccent,
            AppColors.splitAccent,
            AppColors.success,
            AppColors.caution
        ]
        let origins: [UnitPoint] = [
            UnitPoint(x: 0.38, y: 0.30),
            UnitPoint(x: 0.62, y: 0.34)
        ]

        var built: [Particle] = []
        for (burstIndex, origin) in origins.enumerated() {
            let count = 46
            for i in 0..<count {
                // Fan particles across the full circle, with a little
                // jitter so the ring doesn't look mechanically even.
                let base = (Double(i) / Double(count)) * 2 * .pi
                let jitter = Double.random(in: -0.12...0.12)
                built.append(
                    Particle(
                        origin: origin,
                        angle: base + jitter,
                        speed: Double.random(in: 220...420),
                        color: palette[(i + burstIndex) % palette.count],
                        size: CGFloat.random(in: 5...10),
                        spin: Double.random(in: -6...6),
                        delay: Double(burstIndex) * 0.18
                    )
                )
            }
        }
        particles = built
    }

    var body: some View {
        if reduceMotion {
            reducedMotionSparkle
        } else {
            TimelineView(.animation) { timeline in
                let elapsed = timeline.date.timeIntervalSince(start)
                Canvas { context, size in
                    draw(in: &context, size: size, elapsed: elapsed)
                }
            }
            .allowsHitTesting(false)
            .ignoresSafeArea()
        }
    }

    // MARK: - Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize, elapsed: TimeInterval) {
        let gravity: Double = 520     // points / second^2, pulls confetti down
        for particle in particles {
            let t = elapsed - particle.delay
            guard t >= 0 else { continue }

            // Per-particle visible lifetime; particles outlive each other
            // slightly so the burst dissolves rather than cuts.
            let life = Self.duration - particle.delay
            guard t <= life else { continue }

            let ox = particle.origin.x * size.width
            let oy = particle.origin.y * size.height
            let vx = cos(particle.angle) * particle.speed
            let vy = sin(particle.angle) * particle.speed

            let x = ox + vx * t
            let y = oy + vy * t + 0.5 * gravity * t * t

            // Fade out over the back half of the particle's life.
            let progress = t / life
            let opacity = progress < 0.55 ? 1.0 : max(0, 1 - (progress - 0.55) / 0.45)

            var ctx = context
            ctx.opacity = opacity
            ctx.translateBy(x: x, y: y)
            ctx.rotate(by: .radians(particle.spin * t))

            // Small rounded rectangle = a tumbling confetti fleck.
            let rect = CGRect(
                x: -particle.size / 2,
                y: -particle.size / 2,
                width: particle.size,
                height: particle.size * 0.6
            )
            ctx.fill(
                Path(roundedRect: rect, cornerRadius: 1.5),
                with: .color(particle.color)
            )
        }
    }

    // MARK: - Reduced motion fallback

    /// A calm, near-static accent sparkle for users with Reduce Motion
    /// on — still acknowledges the purchase without flying particles.
    private var reducedMotionSparkle: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 64))
            .foregroundStyle(AppColors.accent)
            .opacity(0.9)
            .transition(.opacity)
            .allowsHitTesting(false)
    }
}

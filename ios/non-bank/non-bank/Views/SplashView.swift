import SwiftUI

// MARK: - Splash View

/// Animated launch screen shown every time the app opens. Implemented
/// in **pure SwiftUI** (not Lottie) so the first frame paints
/// instantly — Lottie's JSON-parse step introduced a visible ~1 s gap
/// between the static dark background and the animation kicking in.
///
/// Visuals:
///  - Dark-navy background (`#0F0F23`) matching the iOS launch screen
///    so there's no color pop at handoff.
///  - Orange glow halo gently pulsing (radial gradient, opacity 0.05↔0.5).
///  - 8-bit-style crystal made of `Rectangle()` pixels at the same
///    coordinates as the original SVG — scaled 1.0 ↔ 1.06 in a
///    breathing rhythm. Pixels overlap by 0.5pt so the dark background
///    can't peek through micro-gaps when the crystal is scaled.
///  - Stars scattered across the **whole screen** (not clustered around
///    the crystal) with staggered twinkle periods (0.8–1.6 s) — the
///    full-screen distribution makes the launch feel like a real night
///    sky rather than a tight halo.
///
/// Everything starts animating the moment the view materialises
/// because SwiftUI's animation modifiers don't have a load-from-disk
/// preroll the way Lottie does.
struct SplashView: View {
    /// Drives BOTH the crystal scale AND the glow opacity in lockstep.
    /// Initialized `false`; flipped to `true` `.onAppear` to kick off
    /// the auto-reversing repeat-forever animation.
    @State private var isPulsing: Bool = false

    /// Background tone — also used by the LaunchBackground color asset
    /// in `Info.plist` so the static iOS launch screen and our SwiftUI
    /// view share the exact same pixel value.
    private static let backgroundColor = Color(
        red: 0x0F / 255, green: 0x0F / 255, blue: 0x23 / 255
    )

    var body: some View {
        ZStack {
            Self.backgroundColor.ignoresSafeArea()

            // Stars layer — sits BEHIND the crystal and spans the whole
            // screen. Built via GeometryReader so the deterministic
            // pseudo-random positions scale with the device size.
            FullScreenStarField()
                .ignoresSafeArea()

            // The "icon" — same 200×200 logical canvas as the SVG.
            // Scaled into the screen via .frame(); the inner shapes
            // use absolute coords from the SVG.
            ZStack {
                glowHalo
                crystal
            }
            .frame(width: 200, height: 200)
            .scaleEffect(1.4)  // visually fills more of the screen
        }
        .onAppear {
            // `.repeatForever` autoreverse takes the animation back and
            // forth between `false`-state and `true`-state values. We
            // toggle once on appear to start; SwiftUI handles looping.
            withAnimation(
                .easeInOut(duration: 1.25).repeatForever(autoreverses: true)
            ) {
                isPulsing = true
            }
        }
    }

    // MARK: - Glow halo

    /// Radial gradient that brightens the area behind the crystal,
    /// pulsing from barely-visible to noticeable in lockstep with the
    /// crystal's scale animation. Same `isPulsing` driver = phases stay
    /// synchronised. Color is the same orange as the crystal so the
    /// glow looks like it's emanating from it rather than sitting under
    /// a different-colored light source.
    private var glowHalo: some View {
        RadialGradient(
            colors: [
                Color(red: 0xFC / 255, green: 0x7A / 255, blue: 0x4A / 255).opacity(0.6),
                Color(red: 0xFC / 255, green: 0x7A / 255, blue: 0x4A / 255).opacity(0.15),
                Color(red: 0xFC / 255, green: 0x7A / 255, blue: 0x4A / 255).opacity(0.0)
            ],
            center: .center,
            startRadius: 0,
            endRadius: 100
        )
        .opacity(isPulsing ? 0.5 : 0.05)
    }

    // MARK: - Crystal

    /// 8-bit-pixel crystal — same rectangle coordinates as the SVG.
    /// Each `Rectangle` is positioned on a 200×200 grid via offset.
    private var crystal: some View {
        ZStack {
            // Orange body
            ForEach(Array(crystalPixels.enumerated()), id: \.offset) { _, pixel in
                pixelRect(pixel)
            }
        }
        .scaleEffect(isPulsing ? 1.06 : 1.0)
    }

    /// Rectangle coords from the original SVG: (x, y, w, h, color).
    /// Order doesn't matter visually — `ZStack` flattens them into the
    /// same XY plane.
    ///
    /// Colors:
    ///   - body: `#FC7A4A` (orange) — matches AppIcon.
    ///   - highlight: `#FFB590` (lighter peach) — softer than pure
    ///     white, same hue family as the body so the highlight reads
    ///     as a light-source reflection rather than a separate sticker.
    private var crystalPixels: [PixelRect] {
        let orange = Color(red: 0xFC / 255, green: 0x7A / 255, blue: 0x4A / 255)
        let lightPeach = Color(red: 0xFF / 255, green: 0xB5 / 255, blue: 0x90 / 255)
        return [
            PixelRect(x: 80,  y: 60,  w: 40, h: 10, color: orange),
            PixelRect(x: 70,  y: 70,  w: 60, h: 10, color: orange),
            PixelRect(x: 60,  y: 80,  w: 80, h: 10, color: orange),
            PixelRect(x: 60,  y: 90,  w: 80, h: 10, color: orange),
            PixelRect(x: 60,  y: 100, w: 80, h: 10, color: orange),
            PixelRect(x: 70,  y: 110, w: 60, h: 10, color: orange),
            PixelRect(x: 80,  y: 120, w: 40, h: 10, color: orange),
            PixelRect(x: 90,  y: 130, w: 20, h: 10, color: orange),
            // Highlights — drawn after body so they paint on top.
            PixelRect(x: 80,  y: 70,  w: 10, h: 10, color: lightPeach),
            PixelRect(x: 70,  y: 80,  w: 10, h: 10, color: lightPeach)
        ]
    }

    // MARK: - Helpers

    /// Build a single `Rectangle` placed by absolute SVG-style coords
    /// inside the 200×200 ZStack. SwiftUI's frame is centered, so we
    /// offset the rect from the centre by `pixel.center - 100`.
    ///
    /// **Gap fix**: each rect is rendered slightly larger than its
    /// nominal size (`+overlap` pad on every side). Without the pad,
    /// SwiftUI's sub-pixel rounding leaves visible 0.5pt seams between
    /// adjacent "pixels" once the whole crystal scales (1.4× outer ×
    /// up-to-1.06 pulse) — those seams flash dark navy through the
    /// crystal. Padding produces a tiny overlap that the GPU happily
    /// composites into a clean fill.
    @ViewBuilder
    private func pixelRect(_ pixel: PixelRect) -> some View {
        let overlap: CGFloat = 0.5
        Rectangle()
            .fill(pixel.color)
            .frame(width: pixel.w + overlap * 2, height: pixel.h + overlap * 2)
            .offset(
                x: pixel.x + pixel.w / 2 - 100,
                y: pixel.y + pixel.h / 2 - 100
            )
    }
}

// MARK: - Pixel descriptor

private struct PixelRect {
    let x: CGFloat
    let y: CGFloat
    let w: CGFloat
    let h: CGFloat
    let color: Color
}

// MARK: - Full-screen star field

/// Stars scattered across the entire screen. Positions are
/// **deterministic** (seeded `SystemRandomNumberGenerator` replacement
/// with a fixed-sequence LCG) so the same device always gets the same
/// pattern and there's no flicker between launches. The field uses
/// `GeometryReader` so positions scale with the actual safe area —
/// looks the same proportional layout on iPhone SE through Pro Max.
private struct FullScreenStarField: View {
    /// Density tuned by eye on iPhone 17 Pro: ~30 stars feels like a
    /// "real" sky without becoming visual noise. Smaller devices get
    /// proportionally fewer because we cap by area.
    private static let baseStarCount: Int = 30

    /// Fixed seed so the layout is stable across launches. Changing
    /// this number reshuffles the entire field — useful for A/B'ing
    /// distributions during design review.
    private static let seed: UInt64 = 0x5_A1A_55EED_5

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(generateStars(in: geo.size), id: \.id) { star in
                    TwinklingStar(spec: star)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    /// Build the star layout once per geometry change. Uses a small
    /// LCG so we don't depend on `Foundation.SystemRandomNumberGenerator`
    /// (whose output isn't reproducible across launches).
    private func generateStars(in size: CGSize) -> [PositionedStar] {
        let yellow = Color(red: 0xFC / 255, green: 0xD3 / 255, blue: 0x4D / 255)
        let white = Color.white

        // Carve out a "no-stars" disc around the centre so stars don't
        // visually pile up on top of the crystal. The crystal occupies
        // roughly the central 280×280 box (200pt logical × 1.4 scale),
        // so we exclude an 180-radius circle there. (Smaller than the
        // crystal box because stars near the *corners* of the box still
        // look fine — only the centre disc looks crowded.)
        let centre = CGPoint(x: size.width / 2, y: size.height / 2)
        let exclusionRadius: CGFloat = 180

        var rng = LCG(seed: Self.seed)
        var stars: [PositionedStar] = []
        var attempts = 0
        let target = Self.baseStarCount

        while stars.count < target && attempts < target * 10 {
            attempts += 1
            let x = CGFloat(rng.nextDouble()) * size.width
            let y = CGFloat(rng.nextDouble()) * size.height
            let dx = x - centre.x
            let dy = y - centre.y
            if dx * dx + dy * dy < exclusionRadius * exclusionRadius {
                continue
            }
            let bigStar = rng.nextDouble() < 0.4
            let size: CGFloat = bigStar ? 8 : 4
            let color = rng.nextDouble() < 0.5 ? yellow : white
            // 0.7–1.7 s twinkle period — keeps the field feeling alive
            // without any single star dominating attention.
            let period = 0.7 + rng.nextDouble()
            stars.append(
                PositionedStar(
                    id: stars.count,
                    x: x, y: y,
                    size: size,
                    color: color,
                    period: period
                )
            )
        }
        return stars
    }
}

/// Star with absolute screen-space coords (set by FullScreenStarField).
private struct PositionedStar: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let color: Color
    let period: Double
}

/// One twinkling star. Each instance owns its own `@State` toggle so
/// stars phase independently — different periods + independent
/// `withAnimation` start times produce a feels-random twinkle field.
///
/// Coordinates are absolute screen-space (top-left origin), so the
/// view positions itself with `.position(x:y:)` rather than the
/// centre-relative `.offset` the crystal uses.
private struct TwinklingStar: View {
    let spec: PositionedStar
    @State private var bright: Bool = false

    var body: some View {
        Rectangle()
            .fill(spec.color)
            .frame(width: spec.size, height: spec.size)
            .opacity(bright ? 1.0 : 0.3)
            .position(x: spec.x, y: spec.y)
            .onAppear {
                withAnimation(
                    .easeInOut(duration: spec.period / 2)
                        .repeatForever(autoreverses: true)
                ) {
                    bright = true
                }
            }
    }
}

// MARK: - Tiny seeded RNG

/// Linear congruential generator. Numerical Recipes constants — fine
/// for visual placement, **not** for cryptography. We use it because
/// `SystemRandomNumberGenerator` isn't seedable, and we need
/// reproducible star layouts so the field is identical on every launch
/// (no jarring re-shuffle when the user reopens the app).
private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        // Mix the seed so seeds with low Hamming weight don't produce
        // trivially correlated initial outputs.
        self.state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextDouble() -> Double {
        // Top 53 bits → uniform [0, 1).
        Double(next() >> 11) / Double(1 << 53)
    }
}

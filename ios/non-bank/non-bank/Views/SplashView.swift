import SwiftUI

// MARK: - Splash View

/// Animated launch screen shown every time the app opens. Implemented
/// in **pure SwiftUI** (not Lottie) so the first frame paints
/// instantly — Lottie's JSON-parse step introduced a visible ~1 s gap
/// between the static dark background and the animation kicking in.
///
/// Visuals:
///  - Adaptive background sourced from the `LaunchBackground` color
///    asset — cream in light mode (so it matches the rest of the warm
///    palette inside the app), dark navy in dark mode. The static iOS
///    launch screen reads the same asset so there's no color pop at
///    handoff.
///  - Accent-coloured 8-bit crystal pulsing 1.0 ↔ 1.06 in sync with a
///    radial glow halo behind it. Pixels overlap by 0.5 pt so the
///    background can't peek through micro-gaps when the crystal scales.
///  - "non bank" wordmark below the crystal, hand-drawn pixel by pixel
///    in the same chunky style as the crystal so the whole splash reads
///    as one piece.
///  - Stars scattered across the **whole screen** with staggered
///    twinkle periods (0.8–1.6 s). Star colors adapt to the background
///    so they stay readable in both modes.
struct SplashView: View {
    /// Drives BOTH the crystal scale AND the glow opacity in lockstep.
    /// Initialized `false`; flipped to `true` `.onAppear` to kick off
    /// the auto-reversing repeat-forever animation.
    @State private var isPulsing: Bool = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()

            // Stars layer — sits BEHIND the crystal and spans the whole
            // screen.
            FullScreenStarField()
                .ignoresSafeArea()

            VStack(spacing: 28) {
                ZStack {
                    glowHalo
                    crystal
                }
                .frame(width: 200, height: 200)
                .scaleEffect(1.4)

                PixelWordmark()
                    .padding(.top, 8)
            }
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
    /// pulsing in lockstep with the crystal's scale animation. Tinted
    /// with the same accent as the crystal so it reads as light
    /// emanating from the gem.
    private var glowHalo: some View {
        RadialGradient(
            colors: [
                Color.accentColor.opacity(0.6),
                Color.accentColor.opacity(0.15),
                Color.accentColor.opacity(0.0)
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
            ForEach(Array(crystalPixels.enumerated()), id: \.offset) { _, pixel in
                pixelRect(pixel)
            }
        }
        .scaleEffect(isPulsing ? 1.06 : 1.0)
    }

    /// Rectangle coords from the original SVG. Body uses `accentColor`
    /// directly (so a future palette change ripples here automatically);
    /// the highlight is a 50 %-tinted-with-white version of the same
    /// accent, applied via `.opacity(0.55)` on a white overlay rather
    /// than a hard-coded peach hex.
    private var crystalPixels: [PixelRect] {
        let body = Color.accentColor
        let highlight = Color.white.opacity(0.55)
        return [
            PixelRect(x: 80,  y: 60,  w: 40, h: 10, color: body),
            PixelRect(x: 70,  y: 70,  w: 60, h: 10, color: body),
            PixelRect(x: 60,  y: 80,  w: 80, h: 10, color: body),
            PixelRect(x: 60,  y: 90,  w: 80, h: 10, color: body),
            PixelRect(x: 60,  y: 100, w: 80, h: 10, color: body),
            PixelRect(x: 70,  y: 110, w: 60, h: 10, color: body),
            PixelRect(x: 80,  y: 120, w: 40, h: 10, color: body),
            PixelRect(x: 90,  y: 130, w: 20, h: 10, color: body),
            // Highlights — drawn after body so they paint on top.
            PixelRect(x: 80,  y: 70,  w: 10, h: 10, color: highlight),
            PixelRect(x: 70,  y: 80,  w: 10, h: 10, color: highlight)
        ]
    }

    // MARK: - Helpers

    /// Build a single `Rectangle` placed by absolute SVG-style coords
    /// inside the 200×200 ZStack.
    ///
    /// **Gap fix**: each rect is rendered slightly larger than its
    /// nominal size (`+overlap` pad on every side). Without the pad,
    /// SwiftUI's sub-pixel rounding leaves visible 0.5 pt seams between
    /// adjacent "pixels" once the whole crystal scales (1.4× outer ×
    /// up-to-1.06 pulse) — those seams flash background through the
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

// MARK: - Pixel wordmark "non bank"

/// "non bank" rendered as a 4×5-pixel-per-glyph wordmark. Drawn pixel
/// by pixel so it sits naturally next to the chunky crystal — no need
/// to ship a custom TTF for one screen of pixel-art type.
///
/// Layout:
///   - Each glyph is 4 columns × 5 rows of "pixels".
///   - 1 column of empty space between letters within a word, 3 columns
///     between "non" and "bank".
///   - Each pixel renders as a `PixelSize × PixelSize` square. 6 pt
///     reads nicely on iPhone 17 Pro without overwhelming the crystal.
private struct PixelWordmark: View {
    private static let pixelSize: CGFloat = 6
    private static let intraLetterGap: Int = 1
    private static let interWordGap: Int = 3

    /// Constant white — the splash background is warm dark in both
    /// light and dark mode, so an adaptive `textPrimary` would flip
    /// to dark brown in light mode and disappear against the backdrop.
    private var inkColor: Color { .white }

    var body: some View {
        let glyphs: [[String]] = [
            Self.glyphN, Self.glyphO, Self.glyphN,
            Self.spaceColumns,
            Self.glyphB, Self.glyphA, Self.glyphN, Self.glyphK
        ]
        let layout = Self.layout(glyphs: glyphs)
        Canvas { ctx, _ in
            for cell in layout {
                let rect = CGRect(
                    x: CGFloat(cell.col) * Self.pixelSize,
                    y: CGFloat(cell.row) * Self.pixelSize,
                    width: Self.pixelSize,
                    height: Self.pixelSize
                )
                ctx.fill(Path(rect), with: .color(inkColor))
            }
        }
        .frame(
            width: CGFloat(Self.totalColumns(glyphs: glyphs)) * Self.pixelSize,
            height: CGFloat(Self.rowsPerGlyph) * Self.pixelSize
        )
        .accessibilityLabel("non bank")
    }

    // MARK: Glyph definitions
    //
    // Each glyph is an array of 5 rows; each row is a 4-character
    // string where "X" = filled pixel, "." = empty. Drawn in the same
    // chunky style as the crystal — designed by eye, not from a real
    // pixel font, so feel free to tweak rows directly if a letter
    // reads weirdly at small sizes.

    private static let rowsPerGlyph: Int = 5

    private static let glyphN: [String] = [
        "X..X",
        "XX.X",
        "X.XX",
        "X..X",
        "X..X"
    ]
    private static let glyphO: [String] = [
        ".XX.",
        "X..X",
        "X..X",
        "X..X",
        ".XX."
    ]
    private static let glyphB: [String] = [
        "XXX.",
        "X..X",
        "XXX.",
        "X..X",
        "XXX."
    ]
    private static let glyphA: [String] = [
        ".XX.",
        "X..X",
        "XXXX",
        "X..X",
        "X..X"
    ]
    private static let glyphK: [String] = [
        "X..X",
        "X.X.",
        "XX..",
        "X.X.",
        "X..X"
    ]
    private static let spaceColumns: [String] = Array(repeating: "...", count: 5)

    private struct Cell {
        let col: Int
        let row: Int
    }

    /// Expand glyphs into a flat `Cell` list with correct horizontal
    /// offsets and inter-letter gaps.
    private static func layout(glyphs: [[String]]) -> [Cell] {
        var cells: [Cell] = []
        var col = 0
        for (idx, glyph) in glyphs.enumerated() {
            let width = glyph.first?.count ?? 0
            for (rowIdx, row) in glyph.enumerated() {
                for (colIdx, char) in row.enumerated() where char == "X" {
                    cells.append(Cell(col: col + colIdx, row: rowIdx))
                }
            }
            col += width
            // Inter-letter spacing. Skip the gap after the last glyph.
            if idx < glyphs.count - 1 {
                col += intraLetterGap
            }
        }
        return cells
    }

    private static func totalColumns(glyphs: [[String]]) -> Int {
        var total = 0
        for (idx, glyph) in glyphs.enumerated() {
            total += glyph.first?.count ?? 0
            if idx < glyphs.count - 1 { total += intraLetterGap }
        }
        return total
    }
}

// MARK: - Full-screen star field

/// Stars scattered across the entire screen. Positions are
/// **deterministic** (seeded `SystemRandomNumberGenerator` replacement
/// with a fixed-sequence LCG) so the same device always gets the same
/// pattern and there's no flicker between launches.
private struct FullScreenStarField: View {
    private static let baseStarCount: Int = 30
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

    private func generateStars(in size: CGSize) -> [PositionedStar] {
        // The splash background is now warm dark (`#1B1410`) in both
        // light and dark themes, so the star palette is constant too:
        // warm yellow + white pop against the dark backdrop in the
        // same way they did on the original navy splash. No dynamic
        // colour needed — the splash isn't appearance-adaptive.
        let yellow = Color(red: 0xFC / 255, green: 0xD3 / 255, blue: 0x4D / 255)
        let white = Color.white

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
            let starSize: CGFloat = bigStar ? 8 : 4
            let color = rng.nextDouble() < 0.5 ? yellow : white
            let period = 0.7 + rng.nextDouble()
            stars.append(
                PositionedStar(
                    id: stars.count,
                    x: x, y: y,
                    size: starSize,
                    color: color,
                    period: period
                )
            )
        }
        return stars
    }
}

private struct PositionedStar: Identifiable {
    let id: Int
    let x: CGFloat
    let y: CGFloat
    let size: CGFloat
    let color: Color
    let period: Double
}

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
/// for visual placement, not for cryptography. We use it because
/// `SystemRandomNumberGenerator` isn't seedable, and we need
/// reproducible star layouts so the field is identical on every launch.
private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &* 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }

    mutating func nextDouble() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

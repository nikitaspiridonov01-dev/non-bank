import SwiftUI

// MARK: - Pixel Cat Generator
//
// Generates a deterministic 10x10 pixel cat from an ID string like
// "amber-lynx-7K2D". The same ID always produces the same cat.

enum PixelCatGenerator {

    struct Cat {
        let grid: [[Color?]]       // 10x10, nil = transparent
        let background: Color
        static let size = 10
    }

    // MARK: Public

    static func build(id: String, blackAndWhite: Bool = false) -> Cat {
        let (adj, noun, code) = parseId(id)

        let fur    = hslFrom(seed: adj + code,        sMin: 50, sMax: 92,  lMin: 40, lMax: 70)
        let eye    = hslFrom(seed: noun + code,       sMin: 70, sMax: 100, lMin: 50, lMax: 80)
        let nose   = hslFrom(seed: code + adj,        sMin: 60, sMax: 100, lMin: 58, lMax: 78)
        let belly  = hslFrom(seed: noun + adj,        sMin: 20, sMax: 55,  lMin: 70, lMax: 90)
        let accent = hslFrom(seed: code + noun + adj, sMin: 60, sMax: 100, lMin: 45, lMax: 72)

        let furDarkL = blackAndWhite ? max(8, fur.l - 22) : max(15, fur.l - 20)
        let furDark = HSL(hue: fur.hue, s: fur.s, l: furDarkL)

        let bgHue = rng(code + "H", 360)
        let bgL   = 10 + rng(code + "L", 10)
        let bgS   = blackAndWhite ? 18 : 18 + rng(code + "S", 18)
        let bg    = HSL(hue: bgHue, s: bgS, l: bgL)

        let cFur     = color(fur,     bw: blackAndWhite)
        let cFurDark = color(furDark, bw: blackAndWhite)
        let cEye     = color(eye,     bw: blackAndWhite)
        let cNose    = color(nose,    bw: blackAndWhite)
        let cBelly   = color(belly,   bw: blackAndWhite)
        let cAccent  = color(accent,  bw: blackAndWhite)
        let cBg      = color(bg,      bw: blackAndWhite)

        let hasCollar  = rng(adj + "collar",         3) != 0
        let hasSpot    = rng(adj + noun + code,      2) == 0
        let tailSide   = rng(noun + code + "tail",   2)
        let eyeShape   = rng(noun + code + "shape",  3)
        let whiskerLen = rng(code + "wsk",           2)
        let earTip     = rng(adj + "ear",            3)

        var g: [[Color?]] = Array(repeating: Array(repeating: nil, count: 10), count: 10)

        // Ears
        g[0][2] = cFur; g[0][3] = cFur; g[0][6] = cFur; g[0][7] = cFur
        let et: Color = (earTip == 2) ? cAccent : (earTip == 1) ? cFurDark : cFur
        g[1][2] = et;   g[1][3] = cFur; g[1][6] = cFur; g[1][7] = et

        // Head
        for x in 2...7 { g[2][x] = cFur; g[3][x] = cFur; g[4][x] = cFur }

        // Eyes
        g[3][3] = cEye; g[3][6] = cEye
        if eyeShape == 2 { g[3][2] = cEye; g[3][7] = cEye }
        if eyeShape == 1 { g[3][3] = cFurDark; g[3][6] = cFurDark }

        // Forehead spot
        if hasSpot { g[2][4] = cFurDark }

        // Nose
        g[4][4] = cNose; g[4][5] = cNose

        // Body
        for x in 2...7 { g[5][x] = cFur; g[6][x] = cFur; g[7][x] = cFur }

        // Belly patch
        g[6][4] = cBelly; g[6][5] = cBelly
        g[7][3] = cBelly; g[7][4] = cBelly; g[7][5] = cBelly; g[7][6] = cBelly

        // Collar
        if hasCollar { for x in 2...7 { g[5][x] = cAccent } }

        // Front paws
        g[8][3] = cFur; g[8][4] = cFur; g[8][5] = cFur; g[8][6] = cFur

        // Tail
        if tailSide == 0 {
            g[6][8] = cFur; g[7][8] = cFur; g[7][9] = cFur; g[8][9] = cFur
        } else {
            g[6][1] = cFur; g[7][1] = cFur; g[7][0] = cFur; g[8][0] = cFur
        }

        // Whiskers
        g[4][1] = cFurDark
        g[4][8] = cFurDark
        if whiskerLen == 1 { g[4][0] = cFurDark; g[4][9] = cFurDark }

        return Cat(grid: g, background: cBg)
    }

    // MARK: - ID parsing

    private static func parseId(_ id: String) -> (adj: String, noun: String, code: String) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "-").map(String.init)
        guard parts.count >= 3 else { return (trimmed, trimmed, trimmed) }
        let code = parts[parts.count - 1]
        let noun = parts[parts.count - 2]
        let adj  = parts[0..<(parts.count - 2)].joined(separator: "-")
        return (adj, noun, code)
    }

    // MARK: - Deterministic hashing

    private static func hash(_ str: String) -> Int {
        var h: Int32 = 5381
        for scalar in str.unicodeScalars {
            h = (31 &* h) &+ Int32(truncatingIfNeeded: scalar.value)
        }
        return Int(Int(h).magnitude)
    }

    private static func rng(_ seed: String, _ max: Int) -> Int {
        return hash(seed) % max
    }

    // MARK: - Color generation

    private struct HSL { let hue: Int; let s: Int; let l: Int }

    private static func hslFrom(seed: String, sMin: Int, sMax: Int, lMin: Int, lMax: Int) -> HSL {
        let hue = rng(seed + "H", 360)
        let s   = sMin + rng(seed + "S", sMax - sMin)
        let l   = lMin + rng(seed + "L", lMax - lMin)
        return HSL(hue: hue, s: s, l: l)
    }

    private static func color(_ hsl: HSL, bw: Bool) -> Color {
        if bw {
            let warmBias = sin(Double(hsl.hue) / 360.0 * .pi * 2) * 6
            let grey = min(95.0, max(8.0, Double(hsl.l) + warmBias)).rounded()
            return hslToColor(h: 0, s: 0, l: grey)
        }
        return hslToColor(h: Double(hsl.hue), s: Double(hsl.s), l: Double(hsl.l))
    }

    private static func hslToColor(h: Double, s: Double, l: Double) -> Color {
        let sNorm = s / 100.0
        let lNorm = l / 100.0
        let c = (1 - abs(2 * lNorm - 1)) * sNorm
        let hPrime = h / 60.0
        let x = c * (1 - abs(hPrime.truncatingRemainder(dividingBy: 2.0) - 1))

        var r = 0.0, g = 0.0, b = 0.0
        switch Int(hPrime) {
        case 0: r = c; g = x; b = 0
        case 1: r = x; g = c; b = 0
        case 2: r = 0; g = c; b = x
        case 3: r = 0; g = x; b = c
        case 4: r = x; g = 0; b = c
        default: r = c; g = 0; b = x
        }
        let m = lNorm - c / 2
        return Color(red: r + m, green: g + m, blue: b + m)
    }
}

// MARK: - SwiftUI View

/// Renders a pixel cat avatar for the given friend ID.
struct PixelCatView: View {
    let id: String
    let size: CGFloat
    var blackAndWhite: Bool = false

    var body: some View {
        let cat = PixelCatGenerator.build(id: id, blackAndWhite: blackAndWhite)
        let gridSize = PixelCatGenerator.Cat.size
        let cell = size / CGFloat(gridSize)
        let cornerRadius = size * 0.18

        Canvas { context, _ in
            let bgRect = CGRect(x: 0, y: 0, width: size, height: size)
            let bgPath = Path(roundedRect: bgRect, cornerRadius: cornerRadius)
            context.fill(bgPath, with: .color(cat.background))
            context.clip(to: bgPath)

            for y in 0..<gridSize {
                for x in 0..<gridSize {
                    guard let color = cat.grid[y][x] else { continue }
                    let rect = CGRect(
                        x: CGFloat(x) * cell,
                        y: CGFloat(y) * cell,
                        width: ceil(cell),
                        height: ceil(cell)
                    )
                    context.fill(Path(rect), with: .color(color))
                }
            }
        }
        .frame(width: size, height: size)
    }
}

/// A version of PixelCatView that fills its parent, maintaining a square aspect ratio.
struct PixelCatFillView: View {
    let id: String
    var blackAndWhite: Bool = false
    var cornerRadius: CGFloat = 0

    var body: some View {
        let cat = PixelCatGenerator.build(id: id, blackAndWhite: blackAndWhite)
        let gridSize = PixelCatGenerator.Cat.size

        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let cell = side / CGFloat(gridSize)
            let cr = cornerRadius

            Canvas { context, _ in
                let bgRect = CGRect(x: 0, y: 0, width: side, height: side)
                let bgPath = Path(roundedRect: bgRect, cornerRadius: cr)
                context.fill(bgPath, with: .color(cat.background))
                context.clip(to: bgPath)

                for y in 0..<gridSize {
                    for x in 0..<gridSize {
                        guard let color = cat.grid[y][x] else { continue }
                        let rect = CGRect(
                            x: CGFloat(x) * cell,
                            y: CGFloat(y) * cell,
                            width: ceil(cell),
                            height: ceil(cell)
                        )
                        context.fill(Path(rect), with: .color(color))
                    }
                }
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

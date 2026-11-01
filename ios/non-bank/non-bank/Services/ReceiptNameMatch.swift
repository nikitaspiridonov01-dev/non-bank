import Foundation

/// "Is this the same receipt line, read twice?" — the name half of the
/// question, shared by the two places that stitch overlapping reads back
/// together: the bands of a tall receipt (`HybridReceiptParser.mergeBandItems`)
/// and consecutive scroll screenshots (`ReceiptScanMerger`).
///
/// The same printed name comes back slightly different from two reads:
/// cut short at a slice edge ("…PREMIU" / "…PREMIUM 45% MM 200"), spaced
/// differently ("PREMIU M"), one letter misread ("…160GR M ARBO" /
/// "…160GR ARBO", "GAUDU" / "GAUDA"), even a Latin letter written as its
/// Cyrillic look-alike ("GAUDА"). Seen on a real Serbian receipt read in
/// three slices, where every seam duplicate survived the old exact/prefix
/// test and inflated the total.
nonisolated enum ReceiptNameMatch {

    /// Lowercased, diacritic-folded, letters and digits only, with Cyrillic
    /// letters that look like Latin ones mapped to them. Only ever compared
    /// with another key, never shown.
    static func key(_ name: String) -> String {
        let folded = name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        var out = ""
        for ch in folded where ch.isLetter || ch.isNumber {
            if ch.unicodeScalars.count == 1, let scalar = ch.unicodeScalars.first, let latin = homoglyphs[scalar] {
                out.unicodeScalars.append(latin)
            } else {
                out.append(ch)
            }
        }
        return out
    }

    /// Two keys of the same line: equal; one a prefix (4+ characters) of
    /// the other — a name cut short; or, for names of 12+ characters, at
    /// most one edit per 12 characters apart once the longer name's extra
    /// tail is ignored — a misread letter on top of a cut.
    static func similarKeys(_ a: String, _ b: String) -> Bool {
        guard !a.isEmpty, !b.isEmpty else { return false }
        if a == b { return true }
        let (shorter, longer) = a.count <= b.count ? (a, b) : (b, a)
        if shorter.count >= 4 && longer.hasPrefix(shorter) { return true }
        guard shorter.count >= 12 else { return false }
        return prefixEditDistance(Array(shorter), Array(longer), limit: max(1, shorter.count / 12)) != nil
    }

    /// Levenshtein distance between `short` and the closest prefix of
    /// `long` (deleting `long`'s tail is free), or nil once it exceeds
    /// `limit`. Banded, so a seam search's thousands of comparisons stay
    /// cheap.
    static func prefixEditDistance(_ short: [Character], _ long: [Character], limit: Int) -> Int? {
        let n = short.count, m = long.count
        guard n > 0 else { return 0 }
        let big = limit + 1
        // previous[j] = distance(short[0..<i-1], long[0..<j]); only j within
        // `limit` of i can stay under the limit.
        var previous = (0...m).map { $0 <= limit ? $0 : big }
        for i in 1...n {
            var current = Array(repeating: big, count: m + 1)
            if i <= limit { current[0] = i }
            let lo = max(1, i - limit), hi = min(m, i + limit)
            if lo <= hi {
                for j in lo...hi {
                    let substitute = previous[j - 1] + (short[i - 1] == long[j - 1] ? 0 : 1)
                    current[j] = min(substitute, previous[j] + 1, current[j - 1] + 1, big)
                }
            }
            previous = current
        }
        // The rest of `long` after the best prefix is free.
        let best = previous.min() ?? big
        return best <= limit ? best : nil
    }

    /// Cyrillic letters (lowercase, after folding) that are drawn like a
    /// Latin letter, mapped to it.
    private static let homoglyphs: [Unicode.Scalar: Unicode.Scalar] = [
        "а": "a", "в": "b", "е": "e", "к": "k", "м": "m", "н": "h", "о": "o",
        "р": "p", "с": "c", "т": "t", "у": "y", "х": "x", "і": "i", "ј": "j", "ѕ": "s",
    ]
}

import Foundation

/// Stitches the per-photo results of a multi-image receipt scan into one
/// receipt.
///
/// People capture long receipts — and especially delivery-app order screens
/// (Wolt, Glovo, Bolt) — as several screenshots taken while scrolling. Each
/// photo is parsed on its own, so the merge has to answer what the per-photo
/// parses can't:
///
/// 1. **What is the receipt's grand total?** It is printed once, at the
///    bottom, so it lives on one photo. The other photos report no total or —
///    despite the prompt asking for 0 — the sum of their own visible items.
///    Adding the per-photo totals together (the old behaviour) produced a
///    total no receipt ever printed, and a false "Prices don't add up"
///    warning on perfectly read screenshots: 3 550 (the first screenshot's
///    items) + 4 564.40 (the real total) = 8 114.40.
/// 2. **Which lines are the same line seen twice?** Consecutive scroll
///    screenshots overlap: the last items of one reappear at the top of the
///    next (`seamOverlap`). The photos may also have been picked out of
///    order, so the order with the most overlap is looked for
///    (`photoOrder`).
///
/// The printed total doubles as a checksum. Every seam can be read three
/// ways — as detected, with the unmatched lines around it dropped, or as no
/// overlap at all (two identical lines that really were ordered twice) — and
/// every combination is paired with every plausible total. The reading that
/// adds up wins, preferring the fewest departures from the default. When
/// nothing adds up, the default reading is kept and the total is the latest
/// one that is clearly a printed total (it covers more than its own photo's
/// items), so the review screen still flags a genuine misread.
enum ReceiptScanMerger {

    // MARK: - Merge

    static func merge(_ results: [HybridReceiptParser.Result]) -> HybridReceiptParser.Result {
        precondition(!results.isEmpty, "Caller must pass at least one result")
        if results.count == 1 { return results[0] }

        let receipts = results.map(\.parsedReceipt)
        let photos = receipts.map { $0.items.map(Line.init) }
        let readings = candidateReadings(photos)
        let defaultReading = readings[0].lines

        // Candidate totals, latest photo first: the grand total sits at the
        // bottom of the receipt, i.e. on the last screenshot.
        var totals: [TotalCandidate] = []
        for receipt in receipts.reversed() {
            guard let value = receipt.totalAmount, value > 0 else { continue }
            let ownItems = receipt.items.reduce(0) { $0 + $1.lineTotal }
            totals.append(TotalCandidate(
                value: value,
                // A total equal to this photo's own items is either a whole
                // separate receipt or a sum the model made up for a partial
                // screenshot — no evidence of a grand total covering more.
                printed: abs(value - ownItems) > tolerance(for: value)
            ))
        }
        let singleTotals = totals.count
        // Separate receipts photographed together: each carries its own
        // total and their sum is the bill. Only plausible when the photos
        // don't overlap — overlapping photos are views of ONE receipt.
        let lineCount = photos.reduce(0) { $0 + $1.count }
        if singleTotals >= 2, defaultReading.count == lineCount {
            totals.append(TotalCandidate(value: totals.reduce(0) { $0 + $1.value }, printed: false))
        }

        // The reading/total pair that adds up best. A printed total accepts
        // the usual 1 % window (the review screen flags any residual gap);
        // a total that isn't evidently printed must match exactly.
        var best: (key: [Int], reading: Int, total: Int)?
        for (ri, reading) in readings.enumerated() {
            let readingSum = sum(reading.lines)
            for (ti, total) in totals.enumerated() {
                let gap = abs(readingSum - total.value)
                guard gap <= (total.printed ? tolerance(for: total.value) : 0.05) else { continue }
                let key = [Int((gap * 100).rounded()), reading.departures, ri, ti]
                if let current = best, !key.lexicographicallyPrecedes(current.key) { continue }
                best = (key, ri, ti)
            }
        }

        let lines: [Line]
        let grandTotal: Double?
        if let best {
            lines = readings[best.reading].lines
            grandTotal = totals[best.total].value
        } else {
            lines = defaultReading
            grandTotal = totals.prefix(singleTotals).first(where: \.printed)?.value
        }

        let parsed = ParsedReceipt(
            storeName: receipts.compactMap { nonEmpty($0.storeName) }.first,
            date: receipts.compactMap { nonEmpty($0.date) }.first,
            items: lines.map(\.item),
            totalAmount: grandTotal,
            currency: receipts.compactMap { nonEmpty($0.currency) }.first,
            suggestedCategory: receipts.compactMap { nonEmpty($0.suggestedCategory) }.first,
            language: receipts.compactMap { nonEmpty($0.language) }.first
        )

        let confidence: HybridReceiptParser.Confidence
        if results.contains(where: { $0.source == .ocrFallback }) {
            // A photo read without AI stays "double-check" whatever the sums
            // say — same rule as a single local-OCR scan.
            confidence = results.map(\.confidence).min(by: { rank($0) < rank($1) }) ?? .low
        } else if best != nil || grandTotal == nil {
            // The receipt-level checksum passed, or there's no printed total
            // to check against (same as a single photo without a total).
            confidence = .high
        } else {
            confidence = .medium
        }

        let source: HybridReceiptParser.Source = results.first(where: { result in
            if case .cloud = result.source { return true }
            return false
        })?.source ?? .ocrFallback

        return HybridReceiptParser.Result(
            parsedReceipt: parsed,
            confidence: confidence,
            totalsMatch: HybridReceiptParser.totalsMatch(in: parsed),
            source: source,
            attemptedProvidersCount: results.map(\.attemptedProvidersCount).max() ?? 1,
            poolRemaining: results.compactMap(\.poolRemaining).min(),
            poolLow: results.contains { $0.poolLow },
            reconciliationPasses: results.map(\.reconciliationPasses).max() ?? 1,
            cloudFallbackReason: results.compactMap(\.cloudFallbackReason).first
        )
    }

    // MARK: - Readings

    /// One way of reading the merged item list, with how many choices it
    /// makes against the default (every seam as detected, preferred order).
    struct Reading {
        let lines: [Line]
        let departures: Int
    }

    /// Readings to test against the totals; the first one is the default.
    ///
    /// For the preferred order — and the pick order and best-overlap order
    /// when they differ — every combination of per-seam choices. Then two
    /// global fallbacks: lines repeating a line from an earlier photo
    /// removed, and plain concatenation.
    static func candidateReadings(_ photos: [[Line]]) -> [Reading] {
        let pickOrder = Array(photos.indices)
        let overlap = overlapMatrix(photos)
        let found = photoOrder(photos, overlap)
        // Honour the user's pick order unless reordering clearly overlaps
        // better (at least two more matching lines).
        let preferred = chainScore(found, overlap) >= chainScore(pickOrder, overlap) + 2 ? found : pickOrder
        var orders = [preferred]
        for order in [found, pickOrder] where !orders.contains(order) {
            orders.append(order)
        }

        var readings: [Reading] = []
        for (penalty, order) in orders.enumerated() {
            for reading in seamReadings(order.map { photos[$0] }) {
                readings.append(Reading(lines: reading.lines, departures: reading.departures + penalty))
            }
        }
        let worst = (readings.map(\.departures).max() ?? 0) + 1
        let ordered = preferred.map { photos[$0] }
        readings.append(Reading(lines: crossPhotoDeduped(ordered), departures: worst))
        readings.append(Reading(lines: ordered.flatMap { $0 }, departures: worst + 1))
        return readings
    }

    /// Default stitch of photos in the given order: every seam deduped as
    /// detected. Exposed for tests.
    static func stitch(_ photos: [[ReceiptItem]]) -> [ReceiptItem] {
        seamReadings(photos.map { $0.map(Line.init) })[0].lines.map(\.item)
    }

    private enum SeamChoice { case asDetected, dropUnmatched, noOverlap }

    /// All combinations of per-seam choices, default first. Capped so a
    /// pathological set can't explode; real sets produce a few dozen.
    private static func seamReadings(_ photos: [[Line]]) -> [Reading] {
        let cap = 256
        var out: [Reading] = []
        func walk(_ index: Int, _ merged: [Line], _ departures: Int) {
            guard out.count < cap else { return }
            guard index < photos.count else {
                out.append(Reading(lines: merged, departures: departures))
                return
            }
            let photo = photos[index]
            if photo.isEmpty {
                walk(index + 1, merged, departures)
                return
            }
            if merged.isEmpty {
                walk(index + 1, photo, departures)
                return
            }
            let seam = seamOverlap(merged, photo)
            var choices: [SeamChoice] = [.asDetected]
            if seam.skips > 0 { choices.append(.dropUnmatched) }
            if seam.run > 0 { choices.append(.noOverlap) }
            for (i, choice) in choices.enumerated() {
                walk(index + 1, joined(merged, photo, at: seam, choice), departures + (i == 0 ? 0 : 1))
            }
        }
        walk(0, [], 0)
        return out
    }

    /// Joins `later` onto `earlier` across `seam`. Of each duplicated pair
    /// the better reading is kept — the priced one, then the fuller name
    /// (a line cut at the screen edge loses the end of its name). Lines
    /// around the run that the other photo doesn't repeat are ambiguous — a
    /// line cut at the edge, or one the model skipped on the other photo. As
    /// detected, priced ones are kept (losing a real line is worse than a
    /// duplicate the total can expose) and unpriced fragments dropped.
    private static func joined(_ earlier: [Line], _ later: [Line], at seam: Seam, _ choice: SeamChoice) -> [Line] {
        if choice == .noOverlap { return earlier + later }
        var kept = Array(earlier.dropLast(seam.skippedTail))
        let runStart = kept.count - seam.run
        for k in 0..<seam.run {
            let mine = kept[runStart + k], theirs = later[seam.skippedHead + k]
            if (mine.amount == 0 && theirs.amount != 0)
                || ((mine.amount == 0) == (theirs.amount == 0) && theirs.key.count > mine.key.count) {
                kept[runStart + k] = theirs
            }
        }
        let keepUnmatched = choice == .asDetected
        let tail = earlier.suffix(seam.skippedTail).filter { keepUnmatched && $0.amount != 0 }
        let head = later.prefix(seam.skippedHead).filter { keepUnmatched && $0.amount != 0 }
        return kept + tail + head + Array(later.dropFirst(seam.skippedHead + seam.run))
    }

    /// Every photo's lines, minus lines that repeat a line from an EARLIER
    /// photo. Each earlier line absorbs at most one copy per later photo, so
    /// an item ordered twice (two lines on one photo) survives being seen
    /// again on the next one. Used only when a total confirms it — on its
    /// own it would also collapse genuine repeat purchases.
    private static func crossPhotoDeduped(_ photos: [[Line]]) -> [Line] {
        var kept: [Line] = []
        for photo in photos {
            var absorbed = Set<Int>()
            var fresh: [Line] = []
            for line in photo {
                if let j = kept.indices.first(where: { !absorbed.contains($0) && sameLine(kept[$0], line) }) {
                    absorbed.insert(j)
                } else {
                    fresh.append(line)
                }
            }
            kept += fresh
        }
        return kept
    }

    // MARK: - Photo order

    /// Order of the photos that maximises the total seam overlap; the pick
    /// order wins ties. Exhaustive for up to six photos, greedy beyond.
    static func photoOrder(_ photos: [[ReceiptItem]]) -> [Int] {
        let lines = photos.map { $0.map(Line.init) }
        return photoOrder(lines, overlapMatrix(lines))
    }

    private static func photoOrder(_ photos: [[Line]], _ overlap: [[Int]]) -> [Int] {
        let n = photos.count
        let pickOrder = Array(0..<n)
        guard n > 1 else { return pickOrder }
        if n <= 6 {
            var best = pickOrder
            var bestScore = chainScore(pickOrder, overlap)
            for order in permutations(pickOrder) {
                let score = chainScore(order, overlap)
                if score > bestScore {
                    best = order
                    bestScore = score
                }
            }
            return best
        }
        // Greedy: start at a photo nothing flows into, keep following the
        // strongest overlap, fall back to pick order when nothing overlaps.
        let start = pickOrder.first { j in pickOrder.allSatisfy { overlap[$0][j] == 0 } } ?? 0
        var order = [start]
        var used: Set<Int> = [start]
        while order.count < n {
            let last = order[order.count - 1]
            let remaining = pickOrder.filter { !used.contains($0) }
            var next = remaining[0]
            for j in remaining where overlap[last][j] > overlap[last][next] {
                next = j
            }
            order.append(next)
            used.insert(next)
        }
        return chainScore(order, overlap) > chainScore(pickOrder, overlap) ? order : pickOrder
    }

    private static func overlapMatrix(_ photos: [[Line]]) -> [[Int]] {
        photos.indices.map { i in
            photos.indices.map { j in i == j ? 0 : seamOverlap(photos[i], photos[j]).run }
        }
    }

    private static func chainScore(_ order: [Int], _ overlap: [[Int]]) -> Int {
        zip(order, order.dropFirst()).reduce(0) { $0 + overlap[$1.0][$1.1] }
    }

    /// All orderings of `items` (callers keep this to six or fewer: 720).
    private static func permutations(_ items: [Int]) -> [[Int]] {
        guard items.count > 1 else { return [items] }
        var out: [[Int]] = []
        for (i, first) in items.enumerated() {
            var rest = items
            rest.remove(at: i)
            for tail in permutations(rest) {
                out.append([first] + tail)
            }
        }
        return out
    }

    // MARK: - Seam

    struct Seam {
        /// Length of the matched duplicate run.
        var run: Int = 0
        /// Lines after the run on the earlier photo that the later photo
        /// doesn't continue with.
        var skippedTail: Int = 0
        /// Lines before the run on the later photo that the earlier photo
        /// doesn't end with.
        var skippedHead: Int = 0

        var skips: Int { skippedTail + skippedHead }
    }

    static func seamOverlap(tailOf a: [ReceiptItem], headOf b: [ReceiptItem]) -> Seam {
        seamOverlap(a.map(Line.init), b.map(Line.init))
    }

    /// Longest run where the end of `a` reappears at the start of `b`,
    /// allowing up to two unmatched lines on each side of the seam (cut
    /// partials, a line the model skipped). A single matching line counts
    /// only when it touches the seam exactly, and a run that needs skips on
    /// BOTH sides needs at least three lines — weaker matches are too likely
    /// to be the same dish ordered again.
    private static func seamOverlap(_ a: [Line], _ b: [Line]) -> Seam {
        let aCount = a.count, bCount = b.count
        guard aCount > 0, bCount > 0 else { return Seam() }
        let maxSkip = 2
        var best: Seam?
        for skipA in 0...min(maxSkip, aCount - 1) {
            for skipB in 0...min(maxSkip, bCount - 1) {
                let maxRun = min(aCount - skipA, bCount - skipB)
                guard maxRun >= 1 else { continue }
                for run in stride(from: maxRun, through: 1, by: -1) {
                    let start = aCount - skipA - run
                    var matches = true
                    for k in 0..<run where !sameLine(a[start + k], b[skipB + k]) {
                        matches = false
                        break
                    }
                    guard matches else { continue }
                    if run == 1 && skipA + skipB > 0 { break }
                    if skipA > 0 && skipB > 0 && run < 3 { break }
                    let candidate = Seam(run: run, skippedTail: skipA, skippedHead: skipB)
                    if let current = best,
                       run < current.run || (run == current.run && candidate.skips >= current.skips) {
                        break
                    }
                    best = candidate
                    break  // longest run for this (skipA, skipB)
                }
            }
        }
        return best ?? Seam()
    }

    // MARK: - Line matching

    /// A receipt line with its name folded once, so the many comparisons of
    /// a merge don't re-fold strings.
    struct Line {
        let item: ReceiptItem
        let key: String
        let amount: Double

        init(_ item: ReceiptItem) {
            self.item = item
            self.key = String(
                item.name.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                    .filter { $0.isLetter || $0.isNumber }
            )
            self.amount = item.lineTotal
        }
    }

    static func sameLine(_ x: ReceiptItem, _ y: ReceiptItem) -> Bool {
        sameLine(Line(x), Line(y))
    }

    /// The same receipt line read on two photos. Same rule as the tiling
    /// merge (`HybridReceiptParser.fuzzyItemMatch`: diacritic-folded name,
    /// exact or long-prefix match, price within tolerance or missing on a
    /// cut partial), plus: a name contained in the other one when both
    /// prices are present and equal — a long bilingual delivery-app name
    /// ("Krem čorba od bundeve (Крем-суп …)") is often read in full on one
    /// photo and in part on the next.
    private static func sameLine(_ x: Line, _ y: Line) -> Bool {
        guard !x.key.isEmpty, !y.key.isEmpty else { return false }
        let shorter = x.key.count <= y.key.count ? x.key : y.key
        let longer = x.key.count <= y.key.count ? y.key : x.key
        if x.key == y.key || (shorter.count >= 4 && longer.hasPrefix(shorter)) {
            if x.amount == 0 || y.amount == 0 { return true }
            return abs(x.amount - y.amount) <= max(0.05, abs(x.amount) * 0.01)
        }
        guard x.amount != 0, y.amount != 0, abs(x.amount - y.amount) <= 0.005 else { return false }
        return shorter.count >= 8 && longer.contains(shorter)
    }

    // MARK: - Helpers

    private struct TotalCandidate {
        let value: Double
        let printed: Bool
    }

    /// Same window `HybridReceiptParser.totalsMatch` uses: 1 % or 0.50.
    static func tolerance(for total: Double) -> Double {
        max(abs(total) * 0.01, 0.5)
    }

    private static func sum(_ lines: [Line]) -> Double {
        lines.reduce(0) { $0 + $1.amount }
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return s
    }

    private static func rank(_ c: HybridReceiptParser.Confidence) -> Int {
        switch c {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }
}

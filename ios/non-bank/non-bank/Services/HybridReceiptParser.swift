import UIKit

/// Combines the two on-device parsing strategies into a single flow with a
/// confidence signal:
///
///  1. **Foundation Models** (Apple Intelligence) via `ReceiptParserService` —
///     the high-quality path on supported devices.
///  2. **OCR + regex line parser** (`ReceiptOCRService` + `ReceiptLineParser`)
///     — deterministic fallback when Apple Intelligence is unavailable. Works
///     on every device that runs Vision, but extracts only items (no store
///     name / total / date).
///
/// After Foundation Models succeeds we cross-check that the sum of item line
/// totals matches the LLM's grand total within 1% (or 0.50, whichever is
/// larger). A mismatch lowers confidence so the UI can surface the parsed
/// items for review instead of silently saving them.
actor HybridReceiptParser {

    enum Confidence: String, Sendable {
        /// Foundation Models returned items AND `Σitems ≈ grandTotal`.
        case high
        /// Foundation Models returned items but totals diverge — needs
        /// human review.
        case medium
        /// Foundation Models unavailable; used the regex fallback. Item
        /// extraction worked but there's no grand total to cross-check.
        case low
    }

    struct Result: Sendable {
        let parsedReceipt: ParsedReceipt
        let confidence: Confidence
        /// True when `Σitems ≈ grandTotal` — only meaningful for `.high` /
        /// `.medium`. For `.low` (no grand total) defaults to `true`.
        let totalsMatch: Bool
    }

    private let foundationModelsParser: ReceiptParserService
    private let ocr: ReceiptOCRService

    init(
        foundationModelsParser: ReceiptParserService = ReceiptParserService(),
        ocr: ReceiptOCRService = ReceiptOCRService()
    ) {
        self.foundationModelsParser = foundationModelsParser
        self.ocr = ocr
    }

    func parse(image: UIImage) async throws -> Result {
        do {
            let raw = try await foundationModelsParser.parseReceipt(from: image)
            let cleaned = Self.postProcess(raw)
            Self.logFMResult(raw: raw, cleaned: cleaned)
            let match = Self.totalsMatch(in: cleaned)
            return Result(
                parsedReceipt: cleaned,
                confidence: match ? .high : .medium,
                totalsMatch: match
            )
        } catch ReceiptParserError.modelUnavailable {
            return try await fallbackParse(image: image)
        }
    }

    /// Surfaces *what FM emitted vs. what postProcess kept* so we can tell
    /// whether a "no items detected" failure is FM hallucinating empty
    /// output, or our keyword filter eating legitimate lines.
    private static func logFMResult(raw: ParsedReceipt, cleaned: ParsedReceipt) {
        #if DEBUG
        let dropped = raw.items.count - cleaned.items.count
        print("[HybridReceiptParser] FM: \(raw.items.count) raw items → \(cleaned.items.count) after postProcess (\(dropped) dropped)")
        if dropped > 0 {
            let keptNames = Set(cleaned.items.map(\.name))
            for item in raw.items where !keptNames.contains(item.name) {
                let verdict = ReceiptLineFilter.classify(item.name)
                print("  ✗ dropped \"\(item.name)\" (\(item.lineTotal)) — \(verdict)")
            }
        }
        #endif
    }

    // MARK: - Fallback (OCR + regex)

    private func fallbackParse(image: UIImage) async throws -> Result {
        // Discard Vision lines below 0.3 confidence — they're typically
        // hallucinations on dirty receipts (smudges, low-contrast paper)
        // and just feed false positives to the parser downstream.
        let lines = try await ocr.recognizeText(from: image, minimumConfidence: 0.3)
        let rows = await ocr.groupIntoRows(from: lines)
        Self.logFallbackRows(rows)
        // Geometry-aware extraction — pairs name- and price-only rows by
        // their Y-proximity instead of blindly concatenating neighbours.
        let parsedItems = ReceiptColumnDetector.extractItems(from: rows).map(\.item)
        Self.logExtractedItems(parsedItems)
        let receiptItems = parsedItems.map {
            ReceiptItem(
                name: $0.name,
                quantity: $0.quantity,
                price: $0.unitPrice,
                total: $0.lineTotal
            )
        }
        let receipt = ParsedReceipt(
            storeName: nil,
            date: nil,
            items: receiptItems,
            totalAmount: nil,
            currency: nil
        )
        // postProcess is a defence-in-depth: ColumnDetector already filters
        // most non-product rows, but the keyword filter catches anything
        // that slipped through (e.g. an item line that happens to contain
        // a discount keyword).
        let cleaned = Self.postProcess(receipt)
        return Result(parsedReceipt: cleaned, confidence: .low, totalsMatch: true)
    }

    // MARK: - Diagnostics

    /// Emits the per-row classification verdict so when the fallback parser
    /// returns "0 items" we can see whether OCR even recognised anything,
    /// which rows were filtered as noise, and which were misclassified. Only
    /// active in debug builds — production binaries pay nothing for this.
    private static func logFallbackRows(_ rows: [ReceiptOCRService.OCRRow]) {
        #if DEBUG
        guard !rows.isEmpty else {
            print("[HybridReceiptParser] fallback: OCR returned ZERO rows")
            return
        }
        print("[HybridReceiptParser] fallback: \(rows.count) OCR rows")
        for (index, row) in rows.enumerated() {
            let kind = ReceiptColumnDetector.classify(row: row)
            print("  [\(index)] kind=\(kindLabel(kind)) text=\"\(row.text)\"")
        }
        #endif
    }

    private static func logExtractedItems(_ items: [ParsedLineItem]) {
        #if DEBUG
        print("[HybridReceiptParser] fallback: extractor produced \(items.count) items")
        for item in items {
            print("  • \(item.name) qty=\(item.quantity) total=\(item.lineTotal)")
        }
        #endif
    }

    #if DEBUG
    private static func kindLabel(_ kind: ReceiptColumnDetector.RowKind) -> String {
        switch kind {
        case .noise:        return "noise"
        case .anchorTotal:  return "anchorTotal"
        case .item:         return "item"
        case .namePart:     return "namePart"
        case .pricePart:    return "pricePart"
        }
    }
    #endif

    // MARK: - Cross-check

    /// True when the sum of `items[].lineTotal` matches `grandTotal` within
    /// `max(1%, 0.50)`. When the receipt has no `totalAmount` we treat the
    /// check as passing — there's nothing to compare against.
    static func totalsMatch(in parsed: ParsedReceipt) -> Bool {
        guard let grand = parsed.totalAmount, grand > 0 else { return true }
        let sum = parsed.items.reduce(0.0) { $0 + $1.lineTotal }
        return abs(sum - grand) <= tolerance(for: grand)
    }

    private static func tolerance(for grandTotal: Double) -> Double {
        max(grandTotal * 0.01, 0.5)
    }

    // MARK: - Post-processing

    /// Apply Phase-3.5 cleaning passes that work the same on Foundation
    /// Models output and on the regex fallback path:
    ///
    /// 1. **Filter** items whose name matches the multi-language non-product
    ///    blacklist (`Total`, `VAT`, `Card *1234`, `Tip`, `Service charge`,
    ///    etc.). LLM still hallucinates these on long receipts; regex parser
    ///    also picks them up because they look item-shaped.
    ///
    /// 2. **Normalize discounts** — items whose name matches a discount
    ///    keyword are forced negative (`-|lineTotal|`) regardless of which
    ///    sign FM emitted. This is so when a model outputs `Discount: 5.00`
    ///    we still subtract from the sum.
    ///
    /// 3. **Prune** items that push `Σitems` above `grandTotal`. We greedily
    ///    drop the item whose price is closest to the overshoot — this is
    ///    almost always the line that snuck through (a payment line, a
    ///    "service charge", a misread tip). Loops until the sum fits the
    ///    tolerance window or we run out of items.
    static func postProcess(_ parsed: ParsedReceipt) -> ParsedReceipt {
        let filteredItems = parsed.items.compactMap { item -> ReceiptItem? in
            switch ReceiptLineFilter.classify(item.name) {
            case .keep:
                return item
            case .discount:
                return Self.normalizeDiscount(item)
            case .skipNonProduct, .anchorTotal:
                return nil
            }
        }
        let prunedItems = pruneOverstuffedItems(
            filteredItems,
            grandTotal: parsed.totalAmount
        )
        return ParsedReceipt(
            storeName: parsed.storeName,
            date: parsed.date,
            items: prunedItems,
            totalAmount: parsed.totalAmount,
            currency: parsed.currency
        )
    }

    /// Returns the item with its `total` and `price` forced negative so the
    /// downstream prune/sum maths treats it as a deduction. FM models often
    /// emit discounts with a positive sign and a `-` prefix in the name —
    /// we don't trust the sign, only the keyword.
    private static func normalizeDiscount(_ item: ReceiptItem) -> ReceiptItem {
        let absTotal = abs(item.total ?? 0)
        let absPrice = abs(item.price ?? 0)
        // If both are zero (e.g., FM gave only a name) we still keep the
        // item but with zero values — the user can fix it in review.
        return ReceiptItem(
            name: item.name,
            quantity: item.quantity,
            price: absPrice > 0 ? -absPrice : item.price,
            total: absTotal > 0 ? -absTotal : item.total,
            persistedID: item.persistedID,
            transactionID: item.transactionID,
            syncID: item.syncID,
            position: item.position,
            lastModified: item.lastModified
        )
    }

    /// Iterative greedy pruning: while the items sum exceeds the receipt's
    /// grand total by more than `tolerance(for:)`, drop the single item whose
    /// `lineTotal` best explains the overshoot. This catches false positives
    /// missed by the keyword filter (e.g. "Service 10%" when the LLM didn't
    /// label it explicitly).
    ///
    /// Discount items (negative `lineTotal`) are excluded from the victim
    /// pool — removing one would *raise* the sum, the opposite of what the
    /// loop is trying to do.
    static func pruneOverstuffedItems(
        _ items: [ReceiptItem],
        grandTotal: Double?
    ) -> [ReceiptItem] {
        guard let grand = grandTotal, grand > 0 else { return items }
        var remaining = items
        // Hard cap so a malformed receipt can't infinite-loop.
        let maxIterations = remaining.count
        for _ in 0..<maxIterations {
            let sum = remaining.reduce(0.0) { $0 + $1.lineTotal }
            let overshoot = sum - grand
            if overshoot <= tolerance(for: grand) { break }
            // Find the item whose `lineTotal` is closest to the overshoot —
            // that's the most likely false positive. Only positive items
            // are eligible.
            let candidates = remaining.indices.filter { remaining[$0].lineTotal > 0 }
            guard let victimIndex = candidates.min(by: {
                abs(remaining[$0].lineTotal - overshoot)
                    < abs(remaining[$1].lineTotal - overshoot)
            }) else { break }
            // Bail if even the best candidate doesn't actually shrink the
            // gap — pruning would over-correct.
            let victim = remaining[victimIndex]
            let newSum = sum - victim.lineTotal
            if abs(newSum - grand) >= abs(sum - grand) { break }
            remaining.remove(at: victimIndex)
        }
        return remaining
    }
}

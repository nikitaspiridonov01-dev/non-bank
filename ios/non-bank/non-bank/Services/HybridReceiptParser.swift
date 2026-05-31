import UIKit

/// Two-tier receipt parser, cloud-first by default:
///
///  1. **Cloud** (`CloudReceiptParser`) — uploads image to our Cloudflare
///     Worker which routes across 4 vision-LLM providers (Gemini, Groq,
///     Cloudflare Workers AI, OpenRouter). Highest quality, also returns
///     `suggestedCategory` and richer metadata.
///  2. **OCR + regex** (`ReceiptOCRService` + `ReceiptColumnDetector`) —
///     deterministic fallback. Works on every device, no network. Extracts
///     items only — no store name / total / category.
///
/// Cloud is skipped automatically when (a) the user disabled it in Settings,
/// (b) no backend URL is configured, or (c) the call site didn't construct a
/// `CloudParseConfig`. In any of these cases we go straight to OCR — the
/// caller doesn't have to branch.
///
/// On cloud success we cross-check `Σitems ≈ grandTotal` within 1%/0.50€.
/// A mismatch downgrades confidence to `.medium` so the UI surfaces items
/// for review instead of silently saving them.
///
/// Note: an earlier on-device tier using Apple Foundation Models lives in
/// `ReceiptParserService.swift` but is no longer wired into this flow. The
/// file is kept intact so the integration can be reinstated as an offline
/// option later (e.g. for users who turn off the cloud toggle).
actor HybridReceiptParser {

    enum Confidence: String, Sendable {
        /// Cloud succeeded AND `Σitems ≈ grandTotal`.
        case high
        /// Cloud succeeded but totals diverge — needs human review.
        case medium
        /// Cloud unavailable / disabled; used the regex fallback. Item
        /// extraction worked but there's no grand total to cross-check.
        case low
    }

    /// Where the items came from — surfaced in the review sheet so the user
    /// knows whether they're looking at LLM output (worth scrutinising) or
    /// deterministic OCR (already trustworthy at the line-item level).
    enum Source: Sendable, Equatable {
        case cloud(provider: String)
        case ocrFallback
    }

    struct Result: Sendable {
        let parsedReceipt: ParsedReceipt
        let confidence: Confidence
        /// True when `Σitems ≈ grandTotal` — only meaningful for `.high` /
        /// `.medium`. For `.low` (no grand total) defaults to `true`.
        let totalsMatch: Bool
        let source: Source
        /// Count of providers the router walked before succeeding.
        /// `1` for the OCR-fallback path (no router involved); `1+`
        /// from the cloud router. Surfaced to analytics only.
        let attemptedProvidersCount: Int
    }

    /// Built on the main actor by the caller (where `AISettings` and
    /// `CategoryStore` live), then handed to the parse actor as an immutable
    /// `Sendable` payload.
    struct CloudParseConfig: Sendable {
        let backendURL: URL
        let categories: [CategoryHint]
        let localeIdentifier: String?

        struct CategoryHint: Sendable {
            let name: String
            let emoji: String?
        }
    }

    private let cloud: CloudReceiptParser
    private let ocr: ReceiptOCRService

    init(
        cloud: CloudReceiptParser = CloudReceiptParser(),
        ocr: ReceiptOCRService = ReceiptOCRService()
    ) {
        self.cloud = cloud
        self.ocr = ocr
    }

    func parse(
        image: UIImage,
        cloudConfig: CloudParseConfig? = nil
    ) async throws -> Result {
        let started = Date()
        // Tall-receipt tiling (cloud path only): a very tall supermarket
        // tape compressed into a single vision-model pass loses small
        // text and drops lines. Split it into overlapping bands, parse
        // each at full width in parallel, and stitch the results with
        // overlap-aware dedup. Falls through to the normal single-image
        // path when the receipt isn't tall enough OR every band fails.
        if let config = cloudConfig,
           let bands = ImagePreprocessing.tallReceiptBands(image),
           let tiled = await parseTiled(bands: bands, config: config, started: started) {
            return tiled
        }
        // Downscale up front so every parser path (cloud upload,
        // local Vision OCR, future Foundation Models) sees the same
        // memory ceiling. The downscale is idempotent — already-
        // small images pass through untouched — so it costs nothing
        // for screenshots / order-summary captures and saves a
        // ~10× memory hit on raw 12 MP iPhone photos. Cloud path
        // re-encodes to JPEG inside `CloudReceiptParser.prepareImage`
        // but skips its own downscale step because of this hoist.
        let prepared = ImagePreprocessing.downscaled(image)
        if let config = cloudConfig {
            do {
                return try await cloudParse(image: prepared, config: config, started: started)
            } catch {
                #if DEBUG
                print("[HybridReceiptParser] cloud failed (\(error.localizedDescription)) — falling back to local OCR")
                #endif
                await Self.recordCloudError(error.localizedDescription)
                // Don't rethrow — fall through to OCR. The Settings UI / pool
                // hint surfaces the cloud-side error to the user separately.
            }
        }
        return try await fallbackParse(image: prepared, started: started)
    }

    // MARK: - Cloud (Tier 0)

    private func cloudParse(
        image: UIImage,
        config: CloudParseConfig,
        started: Date
    ) async throws -> Result {
        let cloudResult = try await cloud.parse(
            image: image,
            backendURL: config.backendURL,
            categories: config.categories.map { ($0.name, $0.emoji) },
            localeIdentifier: config.localeIdentifier
        )

        let cleaned = Self.postProcess(cloudResult.receipt)
        let match = Self.totalsMatch(in: cleaned)

        await Self.recordPoolStats(
            remaining: cloudResult.poolRemaining,
            low: cloudResult.poolLow
        )
        await Self.recordTelemetry(
            tier: .cloud,
            provider: cloudResult.provider,
            receipt: cleaned,
            startedAt: started
        )

        return Result(
            parsedReceipt: cleaned,
            confidence: match ? .high : .medium,
            totalsMatch: match,
            source: .cloud(provider: cloudResult.provider),
            attemptedProvidersCount: cloudResult.attemptedProvidersCount
        )
    }

    // MARK: - Tall-receipt tiling

    /// Parse a tall receipt that was split into overlapping bands. Each
    /// band is parsed against the cloud in parallel, then the per-band
    /// item lists are stitched back with an overlap-aware dedup so the
    /// seam items aren't double-counted. Returns `nil` when every band
    /// failed — the caller falls back to the single-image path.
    private func parseTiled(
        bands: [UIImage],
        config: CloudParseConfig,
        started: Date
    ) async -> Result? {
        let cloud = self.cloud
        let cats = config.categories.map { ($0.name, $0.emoji) }
        let backendURL = config.backendURL
        let locale = config.localeIdentifier

        var indexed: [(index: Int, result: CloudReceiptParser.Result)] = []
        await withTaskGroup(of: (Int, CloudReceiptParser.Result)?.self) { group in
            for (i, band) in bands.enumerated() {
                group.addTask {
                    let r = try? await cloud.parse(
                        image: band, backendURL: backendURL,
                        categories: cats, localeIdentifier: locale
                    )
                    return r.map { (i, $0) }
                }
            }
            for await out in group {
                if let out { indexed.append((out.0, out.1)) }
            }
        }
        guard !indexed.isEmpty else { return nil }
        indexed.sort { $0.index < $1.index }

        let receipts = indexed.map { Self.postProcess($0.result.receipt) }
        let mergedItems = Self.mergeBandItems(receipts.map { $0.items })

        // The grand-total line is at the BOTTOM of the receipt → the last
        // band. Prefer its total; else the largest non-nil band total;
        // else nil so downstream falls back to the items sum.
        let total: Double? = {
            if let last = receipts.last?.totalAmount, last > 0 { return last }
            return receipts.compactMap { $0.totalAmount }.filter { $0 > 0 }.max()
        }()

        let merged = ParsedReceipt(
            storeName: receipts.compactMap { $0.storeName }.first,
            date: receipts.compactMap { $0.date }.first,
            items: mergedItems,
            totalAmount: total,
            currency: receipts.compactMap { $0.currency }.first,
            suggestedCategory: receipts.compactMap { $0.suggestedCategory }.first,
            language: receipts.compactMap { $0.language }.first
        )
        let match = Self.totalsMatch(in: merged)
        let provider = indexed.first?.result.provider ?? "tiled"
        let attempts = indexed.map { $0.result.attemptedProvidersCount }.max() ?? 1
        await Self.recordTelemetry(tier: .cloud, provider: provider, receipt: merged, startedAt: started)

        return Result(
            parsedReceipt: merged,
            confidence: match ? .high : .medium,
            totalsMatch: match,
            source: .cloud(provider: provider),
            attemptedProvidersCount: attempts
        )
    }

    /// Stitch per-band item lists, dropping the overlap region's
    /// duplicated run at each seam. Bands are top-to-bottom; the overlap
    /// crop makes the LAST items of band K reappear as the FIRST items
    /// of band K+1, so we remove the longest matching boundary run.
    static func mergeBandItems(_ bands: [[ReceiptItem]]) -> [ReceiptItem] {
        guard var merged = bands.first else { return [] }
        for next in bands.dropFirst() {
            let overlap = boundaryOverlap(tailOf: merged, headOf: next)
            merged.append(contentsOf: next.dropFirst(overlap))
        }
        return merged
    }

    /// Largest L such that the last L items of `a` equal the first L
    /// items of `b`. Only a CONTIGUOUS boundary run is matched, so two
    /// identical items that legitimately appear far apart on the receipt
    /// are never collapsed — only the seam duplicates are removed.
    static func boundaryOverlap(tailOf a: [ReceiptItem], headOf b: [ReceiptItem]) -> Int {
        let maxL = min(a.count, b.count)
        guard maxL > 0 else { return 0 }
        for L in stride(from: maxL, through: 1, by: -1) {
            if zip(a.suffix(L), b.prefix(L)).allSatisfy({ bandItemsMatch($0.0, $0.1) }) {
                return L
            }
        }
        return 0
    }

    /// Seam-dedup equality: same name (case/space-insensitive) AND same
    /// line total. Deliberately strict — under-dedup leaves a duplicate
    /// the user can delete in review, whereas over-dedup silently drops
    /// a real item, which is the worse failure.
    static func bandItemsMatch(_ x: ReceiptItem, _ y: ReceiptItem) -> Bool {
        let nx = x.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ny = y.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return nx == ny && abs(x.lineTotal - y.lineTotal) < 0.01
    }

    // MARK: - Fallback (Tier 1: OCR + regex)

    private func fallbackParse(image: UIImage, started: Date) async throws -> Result {
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
            currency: nil,
            suggestedCategory: nil
        )
        // postProcess is a defence-in-depth: ColumnDetector already filters
        // most non-product rows, but the keyword filter catches anything
        // that slipped through (e.g. an item line that happens to contain
        // a discount keyword).
        let cleaned = Self.postProcess(receipt)

        await Self.recordTelemetry(
            tier: .ocrFallback,
            provider: nil,
            receipt: cleaned,
            startedAt: started
        )

        return Result(
            parsedReceipt: cleaned,
            confidence: .low,
            totalsMatch: true,
            source: .ocrFallback,
            // OCR fallback never goes through the router — 1 is a
            // honest "this single local path attempted once" value.
            attemptedProvidersCount: 1
        )
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

    // MARK: - Telemetry & pool-stats hops

    /// Hops to the main actor to write the pool snapshot. We do this in a
    /// helper so callers can `await` once with no other ceremony.
    @MainActor
    private static func recordPoolStats(remaining: Int, low: Bool) {
        AISettings.shared.recordPoolStats(remaining: remaining, low: low)
    }

    @MainActor
    private static func recordCloudError(_ message: String) {
        AISettings.shared.recordCloudError(message)
    }

    @MainActor
    private static func recordTelemetry(
        tier: ParseTelemetry.Tier,
        provider: String?,
        receipt: ParsedReceipt,
        startedAt: Date
    ) {
        let latencyMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let event = ParseTelemetry.Event(
            tier: tier,
            provider: provider,
            itemCount: receipt.items.count,
            hadTotal: (receipt.totalAmount ?? 0) > 0,
            latencyMs: latencyMs
        )
        ParseTelemetry.shared.record(event)
    }

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

    /// Apply Phase-3.5 cleaning passes that work the same on cloud LLM
    /// output and on the regex fallback path:
    ///
    /// 1. **Filter** items whose name matches the multi-language non-product
    ///    blacklist (`Total`, `VAT`, `Card *1234`, `Tip`, `Service charge`,
    ///    etc.). LLMs still hallucinate these on long receipts; regex parser
    ///    also picks them up because they look item-shaped.
    ///
    /// 2. **Normalize discounts** — items whose name matches a discount
    ///    keyword are forced negative (`-|lineTotal|`) regardless of which
    ///    sign the model emitted. So when a model outputs `Discount: 5.00`
    ///    we still subtract from the sum.
    ///
    /// 3. **Prune** items that push `Σitems` above `grandTotal`. We greedily
    ///    drop the item whose price is closest to the overshoot — this is
    ///    almost always the line that snuck through (a payment line, a
    ///    "service charge", a misread tip). Loops until the sum fits the
    ///    tolerance window or we run out of items.
    static func postProcess(_ parsed: ParsedReceipt) -> ParsedReceipt {
        var droppedByFilter: [String] = []
        let filteredItems = parsed.items.compactMap { item -> ReceiptItem? in
            switch ReceiptLineFilter.classify(item.name) {
            case .keep, .fee, .tip:
                // Fee / tip rows are kept (positive sign — they ADD to
                // the total) so the split-by-items calculator can
                // distribute them proportionally. `ReceiptItem.kind`
                // re-derives the classification via the same
                // `ReceiptLineFilter.classify` call, so we don't need to
                // stash the verdict on the row itself. Tax/VAT lines
                // are not in this list — they're now `.skipNonProduct`
                // (store-side metadata, never a buyer-tracked expense).
                return item
            case .discount:
                return Self.normalizeDiscount(item)
            case .skipNonProduct, .anchorTotal:
                droppedByFilter.append(item.name)
                return nil
            }
        }
        // Defense-in-depth: even with backend `sanitizeDiscountSemantics`
        // and the prompt's "single line is never a discount" rule, the LLM
        // very occasionally still emits a one-line subscription receipt
        // with a negative total (e.g. OPENAI *CHATGPT SUBSCR as -20 USD).
        // Flip such cases here so the iOS UI never shows the nonsense
        // state regardless of which provider answered.
        let signCorrected = correctNonsensicalDiscounts(filteredItems)
        let prunedItems = pruneOverstuffedItems(
            signCorrected,
            grandTotal: parsed.totalAmount
        )
        #if DEBUG
        // Diagnostic for the "receipt parses N of M items" class of
        // issues. Surfaces in Xcode console (visible in the Debug
        // build the developer runs locally). Shows where in the
        // pipeline items get dropped so we can distinguish
        // truncation (provider) from over-filter (this file).
        let droppedByPrune = signCorrected.count - prunedItems.count
        let sumBeforePrune = signCorrected.reduce(0.0) { $0 + $1.lineTotal }
        let sumAfterPrune = prunedItems.reduce(0.0) { $0 + $1.lineTotal }
        if !droppedByFilter.isEmpty || droppedByPrune > 0 {
            let prunedNames = Set(signCorrected.map(\.name))
                .subtracting(Set(prunedItems.map(\.name)))
            print(
                """
                [HybridReceiptParser.postProcess]
                  raw_from_backend: \(parsed.items.count)
                  dropped_by_filter: \(droppedByFilter.count) → \(droppedByFilter)
                  after_filter: \(filteredItems.count)
                  dropped_by_prune: \(droppedByPrune) → \(prunedNames)
                  after_prune: \(prunedItems.count)
                  grand_total: \(parsed.totalAmount ?? 0)
                  sum_before_prune: \(sumBeforePrune)
                  sum_after_prune: \(sumAfterPrune)
                """
            )
        }
        #endif
        return ParsedReceipt(
            storeName: parsed.storeName,
            date: parsed.date,
            items: prunedItems,
            totalAmount: parsed.totalAmount,
            currency: parsed.currency,
            suggestedCategory: parsed.suggestedCategory
        )
    }

    /// Mirrors the backend's `sanitizeDiscountSemantics`: enforces the
    /// invariant "a receipt where every line is negative cannot be all
    /// discount". Two cases handled:
    ///
    ///   • single item with negative total → flip to positive
    ///   • all items negative → flip every line
    ///
    /// We don't touch a multi-item receipt that has at least one positive
    /// line: there a negative item is a legitimate deduction (the prompt's
    /// keyword filter already classified it correctly upstream).
    private static func correctNonsensicalDiscounts(_ items: [ReceiptItem]) -> [ReceiptItem] {
        guard !items.isEmpty else { return items }
        if items.count == 1 {
            return items[0].lineTotal < 0 ? [flipSign(items[0])] : items
        }
        let allNegative = items.allSatisfy { $0.lineTotal < 0 }
        if allNegative {
            return items.map(flipSign)
        }
        return items
    }

    /// Returns the item with `total` and `price` flipped to their absolute
    /// values, preserving every persistence field. Used by the discount-
    /// sanity guard above.
    private static func flipSign(_ item: ReceiptItem) -> ReceiptItem {
        ReceiptItem(
            name: item.name,
            quantity: item.quantity,
            price: item.price.map(abs),
            total: item.total.map(abs),
            persistedID: item.persistedID,
            transactionID: item.transactionID,
            syncID: item.syncID,
            position: item.position,
            lastModified: item.lastModified
        )
    }

    /// Returns the item with its `total` and `price` forced negative so the
    /// downstream prune/sum maths treats it as a deduction. LLM models often
    /// emit discounts with a positive sign and a `-` prefix in the name —
    /// we don't trust the sign, only the keyword.
    private static func normalizeDiscount(_ item: ReceiptItem) -> ReceiptItem {
        let absTotal = abs(item.total ?? 0)
        let absPrice = abs(item.price ?? 0)
        // If both are zero (e.g., model gave only a name) we still keep the
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
        // Sanity-check the inputs before pruning. When the items'
        // sum dramatically exceeds the grand_total (more than 3×),
        // the likely root cause is the LLM misreading the receipt's
        // total — NOT that 70%+ of the items are hallucinations.
        //
        // Real-world LLM slip-throughs on receipts are 1-3 items
        // (payment line, "service charge" that the prompt told it
        // to skip, a misread tip), producing modest overshoot.
        // Anything wildly past that signals a wrong total —
        // a 43-item Serbian grocery shop summing to 11500 RSD
        // observed as `grand_total: 1243.86` because Gemini parsed
        // "11.243,86" as "1.243,86" (lost a thousands digit in EU
        // formatting). Pruning here would delete real products to
        // match the wrong total.
        //
        // When the guard trips we keep all items; the user sees the
        // mismatch between item sum and total in the editor and can
        // fix the total manually. That's a UX papercut, not a
        // silently corrupted receipt.
        let initialSum = items.reduce(0.0) { $0 + $1.lineTotal }
        if initialSum > grand * 3 {
            #if DEBUG
            print(
                "[HybridReceiptParser.pruneOverstuffedItems] " +
                "skipping prune: items_sum \(initialSum) " +
                "exceeds 3× grand_total (\(grand)) — total likely " +
                "misread by the LLM"
            )
            #endif
            return items
        }
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

// MARK: - Convenience

extension HybridReceiptParser.CloudParseConfig {
    /// Pulls the URL from `AISettings`, the categories from the supplied
    /// store, and the locale from `Locale.current`. Returns `nil` when cloud
    /// is disabled or unconfigured — callers pass that `nil` straight into
    /// `parse(image:cloudConfig:)` for the local-only path.
    @MainActor
    static func current(categoryStore: CategoryStore) -> HybridReceiptParser.CloudParseConfig? {
        guard let url = AISettings.shared.resolvedBackendURL else { return nil }
        // Send only the reserved category set (General + 18 defaults).
        // The LLM picks from this stable baseline so receipt scans
        // never auto-tag transactions with the user's niche custom
        // categories; the user's "most frequent" default logic still
        // takes over for the manual flow.
        let categories = categoryStore.reservedCategories.map {
            CategoryHint(name: $0.title, emoji: $0.emoji)
        }
        return HybridReceiptParser.CloudParseConfig(
            backendURL: url,
            categories: categories,
            localeIdentifier: Locale.current.identifier
        )
    }
}

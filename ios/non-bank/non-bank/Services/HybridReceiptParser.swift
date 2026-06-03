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

        // MARK: AI-capacity telemetry (analytics only; default so existing
        // constructors stay one-liners and only set what they know).

        /// Router's combined free daily quota across all providers at parse
        /// time (`nil` on the OCR path). For tiled parses, the MIN seen
        /// across bands — the most conservative headroom reading.
        var poolRemaining: Int? = nil
        /// Backend's "pool nearly empty" flag (<20 left). OR-ed across bands.
        var poolLow: Bool = false
        /// Tiled reconciliation passes that ran: 1 = clean first parse,
        /// 2-3 = escalated (upscale, then second provider). Each pass is N
        /// extra AI calls.
        var reconciliationPasses: Int = 1
        /// Set only on the OCR-fallback path: why cloud wasn't used.
        var cloudFallbackReason: CloudFallbackReason? = nil
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
        if let config = cloudConfig {
            let bands = ImagePreprocessing.tallReceiptBands(image)
            #if DEBUG
            if let bands {
                let dims = bands.map { "\(Int($0.size.width))×\(Int($0.size.height))" }.joined(separator: ", ")
                print("[HybridReceiptParser] tall-receipt tiling: \(bands.count) bands [\(dims)] ← source \(Int(image.size.width))×\(Int(image.size.height)) pt")
            } else {
                let ar = image.size.height / max(image.size.width, 1)
                print("[HybridReceiptParser] tiling SKIPPED: source \(Int(image.size.width))×\(Int(image.size.height)) pt, H/W=\(String(format: "%.2f", ar)) ≤ \(ImagePreprocessing.tallReceiptAspectThreshold) threshold")
            }
            #endif
            if let bands, let tiled = await parseTiledCascade(image: image, bands: bands, config: config, started: started) {
                return tiled
            }
            #if DEBUG
            if bands != nil {
                print("[HybridReceiptParser] tiling abandoned (a band failed after retry) → whole-image fallback")
            }
            #endif
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
        // `.cloudOff` is the default reason — it's correct when the cloud
        // path is skipped entirely (no config). A thrown cloud error below
        // overwrites it with the specific (capacity / network / …) reason.
        var fallbackReason: CloudFallbackReason = .cloudOff
        if let config = cloudConfig {
            do {
                return try await cloudParse(image: prepared, config: config, started: started)
            } catch {
                fallbackReason = Self.fallbackReason(for: error)
                #if DEBUG
                print("[HybridReceiptParser] cloud failed (\(error.localizedDescription)) — falling back to local OCR")
                #endif
                await Self.recordCloudError(error.localizedDescription)
                // Don't rethrow — fall through to OCR. The Settings UI / pool
                // hint surfaces the cloud-side error to the user separately.
            }
        }
        return try await fallbackParse(image: prepared, started: started, cloudFallbackReason: fallbackReason)
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
            attemptedProvidersCount: cloudResult.attemptedProvidersCount,
            poolRemaining: cloudResult.poolRemaining,
            poolLow: cloudResult.poolLow
        )
    }

    // MARK: - Tall-receipt tiling

    /// Reconciliation cascade around `parseTiled`, gated by the printed
    /// grand total used as a checksum. A correctly-read receipt has
    /// Σ(items) == total; a gap means a likely misread digit. Escalation
    /// (each step's extra calls are paid ONLY when the previous step's
    /// result still doesn't reconcile, i.e. rarely):
    ///   1. Normal bands, best provider. Reconciles → done.
    ///   2. UPSCALED bands (more model tiles → finer sampling of small
    ///      text), same provider pool. Reconciles → use it.
    ///   3. SECOND OPINION — re-parse excluding the provider that answered
    ///      pass 1, so a different model gets a turn (breaks a single
    ///      model's deterministic digit confusion). Reconciles → use it.
    ///   4. Nothing reconciled → keep pass 1; the review screen's
    ///      `priceTotalMismatch` banner flags the residual gap.
    /// Returns nil only when pass 1 itself fails every band (caller then
    /// takes the whole-image path).
    private func parseTiledCascade(
        image: UIImage,
        bands: [UIImage],
        config: CloudParseConfig,
        started: Date
    ) async -> Result? {
        guard let pass1 = await parseTiled(bands: bands, config: config, started: started) else {
            return nil
        }
        guard Self.hasTotalMismatch(pass1) else { return pass1 }
        #if DEBUG
        print("[HybridReceiptParser] pass1 Σ≠total — escalating (upscale → second opinion)")
        #endif

        // Pass 2 — upscaled bands, same provider pool.
        if let upBands = ImagePreprocessing.tallReceiptBands(image, upscaleFactor: 1.6),
           var pass2 = await parseTiled(
               bands: upBands, config: config, started: started,
               maxUploadDimension: ImagePreprocessing.upscaledBandUploadDimension),
           !Self.hasTotalMismatch(pass2) {
            pass2.reconciliationPasses = 2
            #if DEBUG
            print("[HybridReceiptParser] pass2 (upscaled) reconciled")
            #endif
            return pass2
        }

        // Pass 3 — second opinion from a different model.
        let firstProvider: String? = {
            if case .cloud(let p) = pass1.source { return p }
            return nil
        }()
        if var pass3 = await parseTiled(
               bands: bands, config: config, started: started,
               excludeProvider: firstProvider),
           !Self.hasTotalMismatch(pass3) {
            pass3.reconciliationPasses = 3
            #if DEBUG
            print("[HybridReceiptParser] pass3 (second opinion, excluded=\(firstProvider ?? "—")) reconciled")
            #endif
            return pass3
        }

        #if DEBUG
        print("[HybridReceiptParser] no pass reconciled — keeping pass1, mismatch banner will show")
        #endif
        var unreconciled = pass1
        unreconciled.reconciliationPasses = 3  // all three passes ran
        return unreconciled
    }

    /// True when the receipt carries a positive printed grand total that
    /// Σ(items) misses by more than 0.05. Mirrors the review screen's
    /// `priceTotalMismatch` threshold so the cascade escalates on exactly
    /// the cases the UI would otherwise flag for manual fixing.
    private static func hasTotalMismatch(_ result: Result) -> Bool {
        guard let total = result.parsedReceipt.totalAmount, total > 0 else { return false }
        let sum = result.parsedReceipt.items.reduce(0.0) { $0 + $1.lineTotal }
        return abs(sum - total) > 0.05
    }

    /// Map a thrown cloud-parse error to the analytics fallback reason so
    /// the dashboard can separate capacity failures (rate limit / providers
    /// exhausted) from connectivity / config — the "is AI capacity enough"
    /// question.
    static func fallbackReason(for error: Error) -> CloudFallbackReason {
        guard let e = error as? CloudReceiptParser.Error else { return .cloudError }
        switch e {
        case .deviceRateLimited:        return .rateLimited
        case .allProvidersUnavailable:  return .providersUnavailable
        case .network:                  return .network
        case .notConfigured:            return .cloudOff
        case .imageEncodingFailed, .badStatus, .decodingFailed:
            return .cloudError
        }
    }

    /// Parse a tall receipt that was split into overlapping bands. Bands are
    /// parsed **sequentially**, not concurrently: parallel uploads compete
    /// for bandwidth and blow the per-request 30 s timeout on cellular, and
    /// their App Attest assertions reach the backend with out-of-order
    /// monotonic counters — both silently drop a band's items. One at a time
    /// gives each upload the full pipe and keeps the counter ordered. Each
    /// band gets a single retry (a failure is usually a transient blip).
    ///
    /// Crucially, if any band still can't be parsed after its retry we return
    /// `nil` to **abandon** the tiled path — the caller then re-parses the
    /// whole image. A whole-image parse at slightly lower resolution beats a
    /// tiled result that silently drops the top (or middle) of the receipt,
    /// which is exactly the failure this guards against.
    private func parseTiled(
        bands: [UIImage],
        config: CloudParseConfig,
        started: Date,
        excludeProvider: String? = nil,
        maxUploadDimension: CGFloat? = nil
    ) async -> Result? {
        let cats = config.categories.map { ($0.name, $0.emoji) }
        let backendURL = config.backendURL
        let locale = config.localeIdentifier

        var receipts: [ParsedReceipt] = []
        var providers: [String] = []
        var attemptsMax = 1
        var minPoolRemaining: Int? = nil
        var anyPoolLow = false
        for (i, band) in bands.enumerated() {
            var parsed = try? await cloud.parse(
                image: band, backendURL: backendURL, categories: cats, localeIdentifier: locale,
                excludeProvider: excludeProvider, maxUploadDimension: maxUploadDimension
            )
            if parsed == nil {
                // One retry keeps us on the high-quality tiled path instead of
                // dropping to the whole-image fallback for a single timeout.
                parsed = try? await cloud.parse(
                    image: band, backendURL: backendURL, categories: cats, localeIdentifier: locale
                )
            }
            guard let parsed else {
                #if DEBUG
                print("[HybridReceiptParser.parseTiled] band \(i + 1)/\(bands.count) failed after retry — abandoning tiled path → whole-image fallback")
                #endif
                return nil
            }
            let cleaned = Self.postProcess(parsed.receipt)
            receipts.append(cleaned)
            providers.append(parsed.provider)
            attemptsMax = max(attemptsMax, parsed.attemptedProvidersCount)
            minPoolRemaining = Swift.min(minPoolRemaining ?? parsed.poolRemaining, parsed.poolRemaining)
            anyPoolLow = anyPoolLow || parsed.poolLow
            #if DEBUG
            let totalStr = cleaned.totalAmount.map { String(format: "%.2f", $0) } ?? "nil"
            print("[HybridReceiptParser.parseTiled] band \(i + 1)/\(bands.count): \(cleaned.items.count) items, total=\(totalStr) (provider=\(parsed.provider))")
            #endif
        }
        guard !receipts.isEmpty else { return nil }

        let mergedItems = Self.mergeBandItems(receipts.map { $0.items })
        #if DEBUG
        let perBand = receipts.map { String($0.items.count) }.joined(separator: "+")
        print("[HybridReceiptParser.parseTiled] merged \(perBand) band items → \(mergedItems.count) after seam-dedup")
        #endif

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
        let provider = providers.first ?? "tiled"
        await Self.recordTelemetry(tier: .cloud, provider: provider, receipt: merged, startedAt: started)

        return Result(
            parsedReceipt: merged,
            confidence: match ? .high : .medium,
            totalsMatch: match,
            source: .cloud(provider: provider),
            attemptedProvidersCount: attemptsMax,
            poolRemaining: minPoolRemaining,
            poolLow: anyPoolLow
        )
    }

    /// Stitch per-band item lists, removing each seam's duplicated overlap
    /// region. Bands are top-to-bottom; the overlap crop makes the LAST
    /// items of band K reappear as the FIRST items of band K+1. For each
    /// seam we drop the cut partials off band K's tail and the duplicated
    /// run off band K+1's head (see `seamOverlap`).
    static func mergeBandItems(_ bands: [[ReceiptItem]]) -> [ReceiptItem] {
        guard var merged = bands.first else { return [] }
        for next in bands.dropFirst() {
            let (dropTail, dropHead) = seamOverlap(tailOf: merged, headOf: next)
            if dropTail > 0 { merged.removeLast(min(dropTail, merged.count)) }
            merged.append(contentsOf: next.dropFirst(min(dropHead, next.count)))
        }
        return merged
    }

    /// Locate the overlap between the end of `a` and the start of `b` and
    /// return `(items to drop off a's tail, items to drop off b's head)`.
    /// Robust to the two ways real tiled bands diverge from a clean
    /// suffix==prefix match — each parsed independently by the model:
    ///   1. EDGE-CUT items — the band crop slices an item at the exact
    ///      seam, so a's very last / b's very first item is a partial that
    ///      won't match. A small skew (≤ `maxSkip`) on each side steps
    ///      over them (and the one on a's side is dropped as a partial).
    ///   2. MODEL VARIANCE — the same line read twice yields truncated
    ///      names and wobbling prices, so matching is fuzzy
    ///      (diacritic/punct-insensitive, prefix-tolerant, price within
    ///      tolerance).
    /// Biased AGAINST over-dedup (the costlier error): a lone single-item
    /// match that needed a skew is treated as coincidence and ignored, so
    /// only a contiguous run — or an exact boundary touch — collapses. A
    /// legitimately-repeated item away from the seam is never considered.
    static func seamOverlap(tailOf a: [ReceiptItem], headOf b: [ReceiptItem]) -> (dropTail: Int, dropHead: Int) {
        let window = 12
        let aCount = a.count, bCount = b.count
        guard aCount > 0, bCount > 0 else { return (0, 0) }
        let maxSkip = 3
        var best: (len: Int, skipA: Int, skipB: Int)?
        for skipA in 0...min(maxSkip, aCount - 1) {
            for skipB in 0...min(maxSkip, bCount - 1) {
                let maxL = min(window, aCount - skipA, bCount - skipB)
                guard maxL >= 1 else { continue }
                for L in stride(from: maxL, through: 1, by: -1) {
                    var ok = true
                    for k in 0..<L where !fuzzyItemMatch(a[aCount - skipA - L + k], b[skipB + k]) {
                        ok = false
                        break
                    }
                    if ok {
                        if best == nil || L > best!.len
                            || (L == best!.len && skipA + skipB < best!.skipA + best!.skipB) {
                            best = (L, skipA, skipB)
                        }
                        break  // longest L for this (skipA, skipB)
                    }
                }
            }
        }
        guard let best else { return (0, 0) }
        // A single fuzzy match that required stepping over a cut item is
        // too weak to trust — leave a possible duplicate (the user can
        // delete it) rather than risk dropping a real item.
        if best.len == 1 && (best.skipA + best.skipB) > 0 { return (0, 0) }
        return (best.skipA, best.skipB + best.len)
    }

    /// Seam-dedup fuzzy equality. Name comparison folds diacritics/case and
    /// keeps only alphanumerics, then accepts an exact match OR a solid
    /// shared prefix (one band truncating a long name at its crop edge).
    /// A clearly different price still means a different line — so two
    /// same-named items with diverging totals are kept (this is what stops
    /// genuine repeat purchases from collapsing). A missing price on a cut
    /// partial doesn't veto an otherwise-strong name match.
    static func fuzzyItemMatch(_ x: ReceiptItem, _ y: ReceiptItem) -> Bool {
        let nx = foldedName(x.name), ny = foldedName(y.name)
        guard !nx.isEmpty, !ny.isEmpty else { return false }
        let nameMatch: Bool
        if nx == ny {
            nameMatch = true
        } else {
            let shorter = nx.count <= ny.count ? nx : ny
            let longer = nx.count <= ny.count ? ny : nx
            nameMatch = shorter.count >= 4 && longer.hasPrefix(shorter)
        }
        guard nameMatch else { return false }
        let px = x.lineTotal, py = y.lineTotal
        if px == 0 || py == 0 { return true }
        return abs(px - py) <= max(0.05, abs(px) * 0.01)
    }

    /// Lowercased, diacritic-folded, alphanumerics-only form of a name so
    /// "Mammi Ćufte sa pire kro." and "mammi cufte sa pire krompirom"
    /// compare as a clean prefix and Serbian/diacritic spelling wobble
    /// across bands doesn't break the seam match.
    private static func foldedName(_ s: String) -> String {
        String(
            s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
                .filter { $0.isLetter || $0.isNumber }
        )
    }

    // MARK: - Fallback (Tier 1: OCR + regex)

    private func fallbackParse(
        image: UIImage,
        started: Date,
        cloudFallbackReason: CloudFallbackReason = .cloudOff
    ) async throws -> Result {
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
            attemptedProvidersCount: 1,
            cloudFallbackReason: cloudFallbackReason
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
        // Normalise names BEFORE classification/merge: strip the fiscal
        // code/unit/tax-category suffix some EU/Balkan printers append
        // (see `normalizingFiscalSuffix`). Two failures this prevents:
        //   1. the embedded code reads as a phone number to
        //      `ReceiptLineFilter` and the real item is dropped;
        //   2. one tiled band emits the verbose form while the next emits
        //      the clean name, so the seam-dedup sees different strings
        //      and keeps both → false duplicates.
        let normalizedInput = parsed.items.map(Self.normalizingFiscalSuffix)
        var droppedByFilter: [String] = []
        let filteredItems = normalizedInput.compactMap { item -> ReceiptItem? in
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

    /// Matches a trailing fiscal code/unit/tax-category suffix that some
    /// EU/Balkan fiscal printers append to product names, e.g. the
    /// "/KOM/9004375 (Б)" in "Nutella sladoled/KOM/9004375 (Б)" or the
    /// "/0082531 (E)" in "Paprika Mix, süß/0082531 (E)". Anchored to the
    /// END and requires the FULL shape — a slash-delimited 4+ digit code
    /// immediately followed by a single-letter tax marker in parens — so
    /// ordinary names that merely contain a slash ("5/8 bolt") or a
    /// trailing "(X)" ("Vitamin C (E)") are never touched.
    private static let fiscalSuffixRegex = try? NSRegularExpression(
        pattern: #"\s*/(?:\p{L}{1,5}/)?\d{4,}\s*\(\s*\p{L}\s*\)\s*$"#,
        options: []
    )

    /// Strip the fiscal suffix matched by `fiscalSuffixRegex`, preserving
    /// every other field. Returns the item unchanged when there's no such
    /// suffix or when stripping would blank the name. Runs first in
    /// `postProcess` so the cleaned name is what gets classified, merged,
    /// and shown to the user.
    static func normalizingFiscalSuffix(_ item: ReceiptItem) -> ReceiptItem {
        guard let regex = fiscalSuffixRegex else { return item }
        let name = item.name
        let full = NSRange(name.startIndex..., in: name)
        guard let match = regex.firstMatch(in: name, options: [], range: full),
              let matchRange = Range(match.range, in: name) else { return item }
        let cleaned = String(name[..<matchRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return item }
        return ReceiptItem(
            name: cleaned,
            quantity: item.quantity,
            price: item.price,
            total: item.total,
            assignedParticipantIDs: item.assignedParticipantIDs,
            persistedID: item.persistedID,
            transactionID: item.transactionID,
            syncID: item.syncID,
            position: item.position,
            lastModified: item.lastModified
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

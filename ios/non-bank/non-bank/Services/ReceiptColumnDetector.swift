import Foundation
import CoreGraphics

/// Geometry-aware item extractor. Replaces `ReceiptLineParser`'s linear
/// "concat the next row" heuristic with a pass that:
///
/// 1. Pre-filters rows through `ReceiptLineFilter` to discard tax/payment/
///    change/etc. lines and lock onto the grand-total anchor.
/// 2. Classifies each remaining row as `.item` (name + price on the same
///    visual line), `.namePart` (text-only, awaiting a price below), or
///    `.pricePart` (price-only, attaches to a buffered name).
/// 3. Stitches name- and price-part rows together when their Y-coordinates
///    are within `verticalPairingThreshold` — this is the case OCR splits
///    a two-column receipt into separate rows for the left and right
///    columns and the linear parser kept picking the wrong neighbour.
/// 4. Stops at the first anchor row — anything below is footer (subtotals,
///    payment method, change) and never produces items.
struct ReceiptColumnDetector {

    /// Maximum vertical distance (in Vision normalized coords) between a
    /// `.namePart` and the immediately-following `.pricePart` for them to
    /// be paired into a single item. Vision normalizes Y to `[0, 1]`, so
    /// `0.06` corresponds to roughly 6% of the image height — enough to
    /// catch wrap-around layouts without crossing into unrelated rows.
    private static let verticalPairingThreshold: CGFloat = 0.06

    /// Top-level entry point: produces the same `[ParsedItemGroup]` shape
    /// as `ReceiptLineParser.extractItemGroups` so it's a drop-in
    /// replacement.
    ///
    /// Anchor handling (Round C-2): we no longer break on the *first*
    /// anchor row. Several real-world layouts have an anchor *above* the
    /// items (Wolt order summary card, food-delivery screenshots) or
    /// multiple anchors interleaved with items (multi-guest hotel bills:
    /// `Total guest 1 → items → Total guest 2 → ... → GRAND TOTAL`).
    /// Stopping at the first anchor lost everything below it.
    ///
    /// Instead: we find the **last** anchor in document order and treat
    /// only rows after it as footer. Intermediate anchors (sub-totals)
    /// just clear the `pendingName` buffer so a name can't pair with a
    /// price across an anchor row, but otherwise behave like noise.
    static func extractItems(
        from rows: [ReceiptOCRService.OCRRow]
    ) -> [ParsedItemGroup] {
        // Visual top-to-bottom order. Vision Y goes bottom-up so we sort
        // descending. Tie-break by minX to keep deterministic order.
        let ordered = rows.sorted { lhs, rhs in
            if abs(lhs.boundingBox.midY - rhs.boundingBox.midY) < 0.005 {
                return lhs.boundingBox.minX < rhs.boundingBox.minX
            }
            return lhs.boundingBox.midY > rhs.boundingBox.midY
        }

        // Pre-pass: locate the last anchor. Rows after it are footer
        // (subtotals, payment method, change, fiscal codes) and never
        // produce items.
        var lastAnchorIndex: Int = ordered.count
        for index in (0..<ordered.count).reversed() {
            if case .anchorTotal = classify(row: ordered[index]) {
                lastAnchorIndex = index
                break
            }
        }

        var groups: [ParsedItemGroup] = []
        var pendingName: PendingName? = nil

        for index in 0..<lastAnchorIndex {
            let row = ordered[index]
            switch classify(row: row) {
            case .anchorTotal:
                // Intermediate anchor (`Total guest 1`, `Subtotal`).
                // Treat as noise: don't pair across it.
                pendingName = nil

            case .noise:
                pendingName = nil

            case .item(let parsed):
                groups.append(ParsedItemGroup(item: parsed, rowIDs: [row.id]))
                pendingName = nil

            case .namePart(let text):
                pendingName = PendingName(
                    text: text,
                    rowID: row.id,
                    boundingBox: row.boundingBox
                )

            case .pricePart(let price):
                if let name = pendingName,
                   verticalDistance(name.boundingBox, row.boundingBox) <= verticalPairingThreshold {
                    let item = ParsedLineItem(
                        name: name.text,
                        quantity: 1,
                        unitPrice: price,
                        lineTotal: price
                    )
                    groups.append(ParsedItemGroup(
                        item: item,
                        rowIDs: [name.rowID, row.id]
                    ))
                }
                pendingName = nil
            }
        }

        return groups
    }

    // MARK: - Per-row classification

    enum RowKind {
        case noise
        case anchorTotal
        case item(ParsedLineItem)
        case namePart(String)
        case pricePart(Double)
    }

    static func classify(row: ReceiptOCRService.OCRRow) -> RowKind {
        switch ReceiptLineFilter.classify(row.text) {
        case .anchorTotal:
            return .anchorTotal
        case .skipNonProduct:
            return .noise
        case .discount:
            // Discount row: parse like an item but force the line total
            // negative so it subtracts from the running sum. If parsing
            // fails (no price token at all — e.g., a bare "Discount applied"
            // line), we still emit a zero-value item so the user sees the
            // discount existed and can fill it in manually.
            if let parsed = ReceiptLineParser.parseItemLine(row.text) {
                let negated = abs(parsed.lineTotal) > 0 ? -abs(parsed.lineTotal) : 0
                let item = ParsedLineItem(
                    name: parsed.name,
                    quantity: parsed.quantity,
                    unitPrice: parsed.quantity > 0 ? negated / parsed.quantity : negated,
                    lineTotal: negated
                )
                return .item(item)
            }
            return .noise
        case .keep:
            break
        }

        // Single-line item: the row already has both the name and a price.
        // Reuse the existing regex parser since it handles tax markers,
        // EU/US decimal mixing, embedded quantities, etc.
        if let parsed = ReceiptLineParser.parseItemLine(row.text), parsed.lineTotal > 0 {
            return .item(parsed)
        }

        // Otherwise inspect the row's individual segments. If everything is
        // text we're a name-part awaiting a price; if everything is a
        // price-shaped token we're a price-part for the buffered name.
        let priceLines = row.lines.filter { isPriceShaped($0.text) }
        let textLines = row.lines.filter { !isPriceShaped($0.text) }

        if priceLines.isEmpty, !textLines.isEmpty {
            let cleaned = cleanedName(from: row.text)
            if cleaned.count >= 3 {
                return .namePart(cleaned)
            }
        }

        // Round C-2: when a price-only row contains *multiple* price tokens
        // (`470.00 550.00`), the rightmost is overwhelmingly the line total
        // in standard `unit-price total` and `qty unit-price total` column
        // layouts. The previous code picked `.first` — which happened to be
        // the unit price — making the resulting item under-priced.
        let priceCandidates = priceLines.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        if textLines.isEmpty,
           let lastPriceLine = priceCandidates.last,
           let price = ReceiptLineParser.parsePrice(lastPriceLine.text),
           price > 0 {
            return .pricePart(price)
        }

        return .noise
    }

    // MARK: - Helpers

    private struct PendingName {
        let text: String
        let rowID: UUID
        let boundingBox: CGRect
    }

    private static func verticalDistance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.midY - b.midY)
    }

    /// True when the trimmed text is *only* a number with an optional
    /// currency symbol or 3-letter code on either side. Accepts:
    ///  - 2-decimal:  `12,50`, `$3.50`, `1.100,00`
    ///  - 1-decimal:  `5,5`, `12.0`
    ///  - Integer:    `250`, `1.100` (EU thousands)
    ///  - Negatives:  `-5,00`, `−5,00` (Unicode minus too)
    ///  - Currency:   `€12.50`, `12,50 EUR`, `RSD 550`
    ///
    /// Lines like `2 x 5.00` are intentionally NOT considered price-shaped
    /// because they belong to the body of an item.
    private static func isPriceShaped(_ text: String) -> Bool {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        // Strip 3-letter codes anywhere on either side (case-insensitive),
        // then run the numeric-only regex on what's left. Same allow-list as
        // ReceiptLineParser to keep behaviour consistent.
        trimmed = trimmed.replacingOccurrences(
            of: #"\b(?:eur|usd|gbp|rsd|rub|pln|huf|czk|sek|nok|dkk|chf|jpy|cny|krw|inr|try|aud|cad|nzd)\b\.?"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        ).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Optional currency glyph + optional sign + digits + optional
        // decimal/thousands grouping + optional trailing currency.
        let pattern =
            #"^[$€£¥₩₽₺₹]?\s*[\-−]?\s*\d{1,3}(?:[.,]\d{3})*(?:[.,]\d{1,2})?\s*[$€£¥₩₽₺₹]?$"#
        return trimmed.range(of: pattern, options: .regularExpression) != nil
    }

    private static func cleanedName(from text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

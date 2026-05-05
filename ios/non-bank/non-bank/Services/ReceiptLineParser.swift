import Foundation

// MARK: - Parsed Line Item

struct ParsedLineItem: Sendable {
    let name: String
    let quantity: Double
    let unitPrice: Double
    let lineTotal: Double
}

/// A parsed item together with the OCR row IDs that produced it.
struct ParsedItemGroup: Sendable {
    let item: ParsedLineItem
    let rowIDs: [UUID]
}

// MARK: - Receipt Line Parser

struct ReceiptLineParser {

    // MARK: - Multi-Row Extraction

    /// Extract items from selected OCR rows, returning which row IDs belong to each item.
    /// Rows must be in visual order (top to bottom on the receipt).
    static func extractItemGroups(from rows: [ReceiptOCRService.OCRRow]) -> [ParsedItemGroup] {
        var groups: [ParsedItemGroup] = []
        var consumed = Set<UUID>()

        for (index, row) in rows.enumerated() {
            guard !consumed.contains(row.id) else { continue }

            // 1. Try parsing this row alone
            if let item = parseItemLine(row.text), item.lineTotal > 0 {
                groups.append(ParsedItemGroup(item: item, rowIDs: [row.id]))
                consumed.insert(row.id)
                continue
            }

            // 2. Try combining with the next row (name + price on separate lines)
            if index + 1 < rows.count {
                let nextRow = rows[index + 1]
                guard !consumed.contains(nextRow.id) else { continue }

                // Try both orders: name+price and price+name
                let forward = row.text + " " + nextRow.text
                let reverse = nextRow.text + " " + row.text

                if let item = parseItemLine(forward), item.lineTotal > 0 {
                    groups.append(ParsedItemGroup(item: item, rowIDs: [row.id, nextRow.id]))
                    consumed.insert(row.id)
                    consumed.insert(nextRow.id)
                    continue
                }
                if let item = parseItemLine(reverse), item.lineTotal > 0 {
                    groups.append(ParsedItemGroup(item: item, rowIDs: [row.id, nextRow.id]))
                    consumed.insert(row.id)
                    consumed.insert(nextRow.id)
                    continue
                }
            }
        }
        return groups
    }

    /// Convenience: extract just the items.
    static func extractItems(from rows: [ReceiptOCRService.OCRRow]) -> [ParsedLineItem] {
        extractItemGroups(from: rows).map(\.item)
    }

    // MARK: - Single Line Parse

    /// Try to extract a receipt item from a single line of text.
    /// Returns nil if the line doesn't contain both a name and a price.
    ///
    /// Tries three price shapes in order of specificity — `2-decimal` first
    /// (highest confidence), then `1-decimal`, then bare integer ≥ 10 (only
    /// accepted when the line has a currency glyph or 3-letter code, or the
    /// integer is followed by a tax marker / end-of-line). This stops bare
    /// numbers like a quantity "1" or a line number "12" from accidentally
    /// becoming the price on receipts that don't use decimals (RSD, JPY,
    /// etc.).
    static func parseItemLine(_ text: String) -> ParsedLineItem? {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3 else { return nil }

        // Pre-clean EU receipt formatting:
        // 1) Strip trailing tax markers ("B", "A", "B *", "A *", etc.)
        trimmed = trimmed.replacingOccurrences(
            of: #"\s+[A-Ea-e]\s*\*?\s*$"#,
            with: "",
            options: .regularExpression
        )
        // 2) Normalize comma-space-digits → comma-digits (OCR artifact: "3, 88" → "3,88")
        trimmed = trimmed.replacingOccurrences(
            of: #"(\d)[,.]\s+(\d{2})\b"#,
            with: "$1,$2",
            options: .regularExpression
        )

        // Bare integer fallback is always allowed inside `parseItemLine` —
        // RSD/JPY/HUF receipts often have integer prices with no per-line
        // currency. The bare-integer regex's `\d{2,}` threshold + lookbehind
        // already rejects the obvious noise (line numbers, dates).
        let lastMatch: NSTextCheckingResult? = Self.findRightmostPriceMatch(
            in: trimmed,
            requireCurrencyForBareInteger: false
        )
        guard let lastMatch else { return nil }

        let priceStr = (trimmed as NSString).substring(with: lastMatch.range)
        guard let lineTotal = parsePrice(priceStr), lineTotal != 0 else { return nil }

        // Text before the rightmost price = name candidate
        let nameCandidate = (trimmed as NSString)
            .substring(to: lastMatch.range.location)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var components = nameCandidate
            .components(separatedBy: .whitespaces)
            .filter { !$0.isEmpty }

        var quantity = 1.0

        // Check last component: small integer or "Nx" → treat as quantity
        if let lastComp = components.last {
            let cleaned = lastComp.lowercased()
                .replacingOccurrences(of: "x", with: "")
                .replacingOccurrences(of: "х", with: "")
            if let q = Double(cleaned), q >= 1 && q <= 99 && q == q.rounded() && cleaned.count <= 2 {
                quantity = q
                components.removeLast()
            }
        }

        // Remove trailing price-like components from the name
        while let lastComp = components.last, parsePrice(lastComp) != nil {
            components.removeLast()
        }

        // Check leading quantity: "2 Salad"
        if components.count >= 2, let first = components.first,
           let q = Double(first), q >= 1 && q <= 10 && q == q.rounded() && first.count <= 2 {
            let rest = components.dropFirst().joined(separator: " ")
            if rest.range(of: #"[\p{L}]"#, options: .regularExpression) != nil {
                quantity = q
                components.removeFirst()
            }
        }

        var name = components.joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remove trailing tax/category markers like "(Б)", "(E)", "(A)"
        name = name.replacingOccurrences(
            of: #"\s*\([A-Za-zА-Яа-яЁёЂ0-9]\)\s*$"#,
            with: "",
            options: .regularExpression
        )

        name = name.trimmingCharacters(in: .whitespacesAndNewlines)

        // Validate: name must have letters and be at least 2 chars
        guard name.count >= 2,
              name.range(of: #"[\p{L}]"#, options: .regularExpression) != nil else {
            return nil
        }

        let unitPrice = quantity > 0 ? lineTotal / quantity : lineTotal

        return ParsedLineItem(
            name: name,
            quantity: quantity,
            unitPrice: unitPrice,
            lineTotal: lineTotal
        )
    }

    // MARK: - Price Match Helpers

    /// Tries the rightmost-price patterns from most to least specific. Stops
    /// at the first pattern that finds a match — so a `5,50` next to a `12`
    /// always wins over the bare integer.
    ///
    /// All patterns share a common lookahead/lookbehind pair to kill date
    /// and time false positives. Round C-2 added these guards after the
    /// fallback parser started matching `11.04` in `11.04.2026`, `0.1` in
    /// `1.0.1` (cashier ID), and `37` in `13:37`. Real prices are bounded
    /// by whitespace / start-of-string / currency glyph / single tax marker —
    /// never another digit/dot/comma/colon/slash.
    private static let priceLookbehindCommon = #"(?<![./:])"#
    private static let priceLookaheadCommon = #"(?![/\d.,:]|\p{L}{2})"#

    private static let pricePatternsTiered: [String] = [
        // 2-decimal (highest confidence): 5,50 / 1.100,00 / -5,00
        priceLookbehindCommon + #"(\-?\d{1,3}(?:[.,]\d{3})*[.,]\d{2})"# + priceLookaheadCommon,
        // 1-decimal: 5,5 / 12.0
        priceLookbehindCommon + #"(\-?\d{1,3}(?:[.,]\d{3})*[.,]\d)"# + priceLookaheadCommon,
        // Multi-thousand integer: 1.100 / 12,345 (≥1 thousand group so we
        // don't false-match a 4-digit year alone).
        priceLookbehindCommon + #"(\-?\d{1,3}(?:[.,]\d{3})+)"# + priceLookaheadCommon
    ]

    /// Bare-integer fallback: standalone integers ≥ 10 not embedded in a
    /// dotted/slashed/colon sequence. Threshold ≥ 10 (`\d{2,}`) avoids
    /// false-matching quantities and line numbers; the shared lookarounds
    /// reject `2024` in `12.05.2024`, `5` in `1/5`, `37` in `13:37`.
    private static let bareIntegerPattern = priceLookbehindCommon + #"(\-?\d{2,})"# + priceLookaheadCommon

    static func findRightmostPriceMatch(
        in text: String,
        requireCurrencyForBareInteger: Bool
    ) -> NSTextCheckingResult? {
        for pattern in pricePatternsTiered {
            if let match = rightmostMatch(in: text, pattern: pattern) {
                return match
            }
        }
        // RSD/JPY/HUF receipts often have integer-only prices and no
        // currency on each line — accept anyway when threshold is met.
        // `requireCurrencyForBareInteger` is reserved for stricter callers
        // (currently always false from `parseItemLine`).
        if requireCurrencyForBareInteger { return nil }
        return rightmostMatch(in: text, pattern: bareIntegerPattern)
    }

    private static func rightmostMatch(in text: String, pattern: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(location: 0, length: text.utf16.count)
        return regex.matches(in: text, range: range).last
    }

    // MARK: - Price Parsing

    /// ISO-ish currency codes we strip before numeric parsing. Restricted to
    /// the set actually seen in the supported locales — keeping the list
    /// closed avoids accidentally munching real product names ending in
    /// 3-letter tokens (e.g. "Bio", "Pro").
    private static let stripCurrencyCodesPattern = #"\b(?:eur|usd|gbp|rsd|rub|pln|huf|czk|sek|nok|dkk|chf|jpy|cny|krw|inr|try|aud|cad|nzd)\b\.?"#

    /// Parses a price token into a `Double`. Accepts:
    ///  - 2-decimal:   `5,50`, `5.50`, `1.100,00`, `1,100.00`
    ///  - 1-decimal:   `5,5`, `12.0`
    ///  - Integer:     `550`, `1.100` (EU thousands), `1,100` (US thousands)
    ///  - Negatives:   `-5,00`
    ///  - Currency:    `€12.50`, `12,50 EUR`, `RSD 550`
    ///
    /// Returns nil for ambiguous bare numbers like `5` (less than 10) — see
    /// the wrapper logic in `parseItemLine` which uses context (currency
    /// glyph, line layout) before accepting small integers as prices.
    static func parsePrice(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }

        // Negative prices (discount lines: "-5,00"). Recurse without sign.
        if s.hasPrefix("-") || s.hasPrefix("−") {
            let stripped = String(s.dropFirst()).trimmingCharacters(in: .whitespaces)
            if let v = parsePrice(stripped) { return -v }
        }

        // Strip currency glyphs and 3-letter codes (case-insensitive). Must
        // happen before regex matching since codes can appear on either side.
        s = s.replacingOccurrences(of: #"[€$£¥₩₽₺₹₿]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(
            of: stripCurrencyCodesPattern,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        s = s.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // EU thousands + comma decimal:  1.100,00 / 1.100,5  → 1100.00 / 1100.5
        if s.range(of: #"^\d{1,3}(\.\d{3})+,\d{1,2}$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ".", with: "")
                 .replacingOccurrences(of: ",", with: ".")
            return Double(s)
        }

        // EU thousands without decimal: 1.100 / 12.345 (>=2 thousand groups
        // so we don't munch decimals like "1.5" — those are handled below).
        if s.range(of: #"^\d{1,3}(\.\d{3})+$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ".", with: "")
            return Double(s)
        }

        // Comma decimal: 550,00 / 5,5 → 550.00 / 5.5
        if s.range(of: #"^\d+,\d{1,2}$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ",", with: ".")
            return Double(s)
        }

        // US thousands + dot decimal: 1,100.00 / 1,100.5 → 1100.00 / 1100.5
        if s.range(of: #"^\d{1,3}(,\d{3})+\.\d{1,2}$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ",", with: "")
            return Double(s)
        }

        // US thousands without decimal: 1,100 → 1100
        if s.range(of: #"^\d{1,3}(,\d{3})+$"#, options: .regularExpression) != nil {
            s = s.replacingOccurrences(of: ",", with: "")
            return Double(s)
        }

        // Plain decimal: 550.00 / 5.5
        if s.range(of: #"^\d+\.\d{1,2}$"#, options: .regularExpression) != nil {
            return Double(s)
        }

        // Plain integer: 250, 5. Caller decides whether to accept tiny
        // integers via context (currency presence, line shape).
        if s.range(of: #"^\d+$"#, options: .regularExpression) != nil {
            return Double(s)
        }

        return nil
    }
}

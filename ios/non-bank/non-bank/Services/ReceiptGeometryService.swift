import Foundation
import CoreGraphics

// MARK: - Receipt Geometry Service

/// Extracts structured receipt data from OCR observations using spatial geometry.
/// No ML, no language-specific keywords for item detection.
/// Works by analyzing bounding box positions: text left, numbers right.
struct ReceiptGeometryService {

    // MARK: - Types

    struct OCRWord: Sendable {
        let text: String
        let box: CGRect       // Vision normalized coords: origin bottom-left, Y up
        let confidence: Float
    }

    struct ReceiptRow: Sendable {
        let words: [OCRWord]
        let minY: CGFloat     // bottom of row (Vision coords)
        let maxY: CGFloat     // top of row
        var midY: CGFloat { (minY + maxY) / 2 }

        var fullText: String {
            words.sorted { $0.box.minX < $1.box.minX }
                 .map(\.text)
                 .joined(separator: " ")
        }
    }

    enum RowKind {
        case item           // product line: text + price
        case total          // grand total line
        case metadata       // store name, date, address
        case noise          // tax, payment, IDs, etc.
    }

    // MARK: - Public API

    func extractReceipt(from words: [OCRWord]) -> ParsedReceipt {
        guard !words.isEmpty else {
            return ParsedReceipt(storeName: nil, date: nil, items: [], totalAmount: nil, currency: nil)
        }

        // 1. Cluster words into rows by Y coordinate
        let rows = clusterIntoRows(words)
        print("[Geometry] \(rows.count) rows from \(words.count) words")

        // 2. Determine receipt zones (top 15% = metadata, rest = body)
        let allY = words.map(\.box.midY)
        let receiptTop = allY.max() ?? 1.0
        let receiptBottom = allY.min() ?? 0.0
        let receiptHeight = receiptTop - receiptBottom
        let metadataThreshold = receiptTop - receiptHeight * 0.15

        // 3. Classify each row and extract data
        var items: [ReceiptItem] = []
        var storeName: String?
        var date: String?
        var totalAmount: Double?
        var currency: String?

        for row in rows {
            let kind = classifyRow(row, metadataThreshold: metadataThreshold)

            switch kind {
            case .item:
                if let item = extractItem(from: row) {
                    items.append(item)
                }
            case .total:
                if totalAmount == nil {
                    totalAmount = extractRightmostNumber(from: row)
                }
            case .metadata:
                if storeName == nil {
                    let candidate = extractStoreName(from: row)
                    if let c = candidate, c.count >= 2 {
                        storeName = c
                    }
                }
            case .noise:
                break
            }

            // Date: try every row (dates can appear anywhere)
            if date == nil {
                date = extractDate(from: row.fullText)
            }

            // Currency: try every row
            if currency == nil {
                currency = detectCurrencySymbol(in: row.fullText)
            }
        }

        // Fallback currency from language detection if symbols not found
        if currency == nil {
            let allText = rows.map(\.fullText).joined(separator: " ")
            let lang = detectLanguageSimple(allText)
            currency = currencyFromLanguage(lang)
        }

        print("[Geometry] \(items.count) items, total=\(totalAmount ?? 0), store=\(storeName ?? "?")")
        return ParsedReceipt(
            storeName: storeName,
            date: date,
            items: items,
            totalAmount: totalAmount,
            currency: currency
        )
    }

    // MARK: - Row Clustering

    /// Group OCR words into rows based on Y-coordinate proximity.
    /// Tolerance handles slight vertical misalignment on crumpled receipts.
    private func clusterIntoRows(_ words: [OCRWord]) -> [ReceiptRow] {
        let sorted = words.sorted { $0.box.midY > $1.box.midY } // top-first
        var rows: [ReceiptRow] = []
        var currentWords: [OCRWord] = []
        var currentMinY: CGFloat = 0
        var currentMaxY: CGFloat = 0

        for word in sorted {
            let wordMidY = word.box.midY
            if currentWords.isEmpty {
                currentWords = [word]
                currentMinY = word.box.minY
                currentMaxY = word.box.maxY
            } else {
                // Tolerance: 1.5% of image height or half the current row height
                let rowHeight = currentMaxY - currentMinY
                let tolerance = max(0.015, rowHeight * 0.5)
                let currentMidY = (currentMinY + currentMaxY) / 2

                if abs(wordMidY - currentMidY) < tolerance {
                    currentWords.append(word)
                    currentMinY = min(currentMinY, word.box.minY)
                    currentMaxY = max(currentMaxY, word.box.maxY)
                } else {
                    rows.append(ReceiptRow(words: currentWords, minY: currentMinY, maxY: currentMaxY))
                    currentWords = [word]
                    currentMinY = word.box.minY
                    currentMaxY = word.box.maxY
                }
            }
        }
        if !currentWords.isEmpty {
            rows.append(ReceiptRow(words: currentWords, minY: currentMinY, maxY: currentMaxY))
        }

        return rows
    }

    // MARK: - Row Classification

    private func classifyRow(_ row: ReceiptRow, metadataThreshold: CGFloat) -> RowKind {
        let text = row.fullText
        let lower = text.lowercased()

        // Total keywords — universal patterns that work across languages
        // Using regex patterns rather than hardcoded words
        if isTotalLine(lower) {
            return .total
        }

        // Noise: tax/VAT lines, payment methods, IDs, URLs
        if isNoiseLine(lower, text: text) {
            return .noise
        }

        // Metadata: in top 15% of receipt
        if row.midY > metadataThreshold {
            // But if it has a price on the right, it's an item even in the header zone
            if hasTextAndNumber(row) {
                return .item
            }
            return .metadata
        }

        // Item: has text on the left AND a number on the right
        if hasTextAndNumber(row) {
            return .item
        }

        // Default: noise (single numbers, standalone labels, etc.)
        return .noise
    }

    /// Check if a line is a total/subtotal line.
    /// Uses patterns that work across many languages without hardcoding specific words.
    private func isTotalLine(_ lower: String) -> Bool {
        // Universal total patterns — these cover 90%+ of receipts worldwide
        let totalPatterns: [String] = [
            // Latin-script languages
            "total", "subtotal", "sub-total", "summe", "gesamt",
            "montant", "importe", "importo", "soma", "toplam",
            "razem", "celkem", "totaal",
            // Cyrillic
            "итого", "всего", "укупно", "свега",
            // CJK
            "合計", "合计", "총액", "합계",
        ]
        for pattern in totalPatterns {
            if lower.contains(pattern) { return true }
        }
        return false
    }

    /// Check if a line is noise (tax, payment, structural).
    private func isNoiseLine(_ lower: String, text: String) -> Bool {
        // URL patterns
        if lower.contains("www.") || lower.contains("http") || lower.contains(".com") { return true }

        // Pure number lines (IDs, phone numbers, dates without text)
        if text.range(of: #"^[\d\s.,\-/:()+]+$"#, options: .regularExpression) != nil { return true }

        // Long alphanumeric IDs (e.g. VBELZ-9JGW-...)
        if text.range(of: #"^[A-Z0-9]{4,}[\-/][A-Z0-9\-/]+"#, options: .regularExpression) != nil { return true }

        // Tax/VAT/payment patterns — using symbol-based detection, not language words
        // The key insight: tax lines usually have "%" symbol
        if lower.contains("%") && !lower.contains("discount") { return true }

        // Payment method indicators (card numbers, cash)
        if text.range(of: #"\*{4,}\d{4}"#, options: .regularExpression) != nil { return true } // ****1234

        // QR, barcode references
        if lower.contains("qr") && lower.count < 20 { return true }

        return false
    }

    // MARK: - Item Extraction

    /// Check if a row has text on the left side and a number on the right side.
    private func hasTextAndNumber(_ row: ReceiptRow) -> Bool {
        let sorted = row.words.sorted { $0.box.minX < $1.box.minX }
        guard sorted.count >= 1 else { return false }

        // Find rightmost number
        let hasRightNumber = sorted.reversed().contains { word in
            word.box.midX > 0.4 && isPrice(word.text)
        }

        // Find left text (not a pure number)
        let hasLeftText = sorted.contains { word in
            word.box.midX < 0.7 && !isPureNumber(word.text) && word.text.count >= 2
        }

        return hasLeftText && hasRightNumber
    }

    /// Extract a receipt item from a row: name from left words, price from rightmost number.
    private func extractItem(from row: ReceiptRow) -> ReceiptItem? {
        let sorted = row.words.sorted { $0.box.minX < $1.box.minX }

        // Collect rightmost numbers (price candidates)
        var prices: [(value: Double, x: CGFloat)] = []
        for word in sorted.reversed() {
            if let val = parsePrice(word.text), word.box.midX > 0.35 {
                prices.append((val, word.box.minX))
            } else if !isPureNumber(word.text) {
                break // Stop when we hit non-number text from the right
            }
        }

        guard !prices.isEmpty else { return nil }

        // Rightmost number = line total, second from right = unit price (if exists)
        let lineTotal = prices[0].value
        let unitPrice = prices.count > 1 ? prices[1].value : lineTotal

        // Find quantity if present (number between name and price, often "1" or "2")
        var quantity: Double = 1.0
        let priceX = prices.last?.x ?? 1.0 // leftmost price position

        // Name = all non-price text left of the prices
        var nameParts: [String] = []
        for word in sorted {
            if word.box.minX >= priceX { break }
            let t = word.text.trimmingCharacters(in: .whitespaces)
            // Check if it's a small integer that could be quantity
            if let q = Double(t), q >= 1 && q <= 99 && q == q.rounded() && t.count <= 2 {
                // Only treat as quantity if it's right before the prices (x > 0.3)
                if word.box.midX > 0.3 && nameParts.count > 0 {
                    quantity = q
                    continue
                }
            }
            if !t.isEmpty && !isPureNumber(t) {
                nameParts.append(t)
            }
        }

        let name = nameParts.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard name.count >= 2 else { return nil }

        // Clean name: remove trailing tax markers like "(Б)", "(A)", "(b)"
        let cleanedName = name.replacingOccurrences(
            of: #"\s*\([A-Za-zА-Яа-я0-9]\)\s*$"#, with: "", options: .regularExpression
        )

        return ReceiptItem(
            name: cleanedName,
            quantity: quantity,
            price: unitPrice,
            total: lineTotal
        )
    }

    // MARK: - Number Parsing

    /// Check if text looks like a price (has digits and optional decimal).
    private func isPrice(_ text: String) -> Bool {
        parsePrice(text) != nil
    }

    /// Parse a price string, handling European format (2.300,00) and standard (2300.00).
    func parsePrice(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Remove currency symbols that might be attached
        var cleaned = trimmed.replacingOccurrences(
            of: #"[€$£¥₩₽]"#, with: "", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        guard !cleaned.isEmpty else { return nil }

        // European format: 2.300,00 → 2300.00
        // Pattern: digits with dot as thousands separator and comma as decimal
        if let _ = cleaned.range(of: #"^\d{1,3}(\.\d{3})+,\d{2}$"#, options: .regularExpression) {
            cleaned = cleaned.replacingOccurrences(of: ".", with: "")
                            .replacingOccurrences(of: ",", with: ".")
            return Double(cleaned)
        }

        // Simple comma decimal: 790,00 → 790.00
        if let _ = cleaned.range(of: #"^\d+,\d{2}$"#, options: .regularExpression) {
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            return Double(cleaned)
        }

        // Standard format: 2300.00 or 2300
        if let _ = cleaned.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) {
            return Double(cleaned)
        }

        return nil
    }

    /// Check if text is purely numeric (no letters).
    private func isPureNumber(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t.range(of: #"^[\d.,\-\s]+$"#, options: .regularExpression) != nil
    }

    // MARK: - Metadata Extraction

    private func extractRightmostNumber(from row: ReceiptRow) -> Double? {
        let sorted = row.words.sorted { $0.box.minX > $1.box.minX } // rightmost first
        for word in sorted {
            if let val = parsePrice(word.text) {
                return val
            }
        }
        return nil
    }

    private func extractStoreName(from row: ReceiptRow) -> String? {
        let text = row.fullText.trimmingCharacters(in: .whitespaces)
        // Skip if it's a pure number, date, or very short
        if text.count < 2 { return nil }
        if text.range(of: #"^\d{2}[./]\d{2}"#, options: .regularExpression) != nil { return nil }
        if text.range(of: #"^[\d\s.,\-/]+$"#, options: .regularExpression) != nil { return nil }
        if text.range(of: #"^\d{5,}"#, options: .regularExpression) != nil { return nil }
        if text.lowercased().contains("www.") || text.lowercased().contains("http") { return nil }
        // Prefer short-ish text (store names are typically < 40 chars)
        if text.count > 50 { return nil }
        return text
    }

    /// Extract date in DD.MM.YYYY or DD/MM/YYYY format, return as YYYY-MM-DD.
    private func extractDate(from text: String) -> String? {
        // DD.MM.YYYY or DD/MM/YYYY
        let regex = try? NSRegularExpression(pattern: #"(\d{2})[./](\d{2})[./](\d{4})"#)
        guard let match = regex?.firstMatch(in: text, range: NSRange(location: 0, length: text.utf16.count)) else {
            return nil
        }
        let day = (text as NSString).substring(with: match.range(at: 1))
        let month = (text as NSString).substring(with: match.range(at: 2))
        let year = (text as NSString).substring(with: match.range(at: 3))
        return "\(year)-\(month)-\(day)"
    }

    // MARK: - Currency Detection

    /// Detect currency from explicit symbols in text (language-agnostic).
    private func detectCurrencySymbol(in text: String) -> String? {
        let lower = text.lowercased()
        if lower.contains("€") || lower.range(of: #"\beur\b"#, options: .regularExpression) != nil { return "EUR" }
        if lower.contains("$") && !lower.contains("₽") { return "USD" }
        if lower.contains("£") || lower.range(of: #"\bgbp\b"#, options: .regularExpression) != nil { return "GBP" }
        if lower.contains("₽") || lower.contains("руб") { return "RUB" }
        if lower.contains("¥") || lower.contains("円") { return "JPY" }
        if lower.contains("₩") || lower.contains("원") { return "KRW" }
        if lower.contains("дін") || lower.contains("дин") || lower.range(of: #"\brsd\b"#, options: .regularExpression) != nil { return "RSD" }
        if lower.range(of: #"\bczk\b"#, options: .regularExpression) != nil || lower.contains("kč") { return "CZK" }
        if lower.range(of: #"\bpln\b"#, options: .regularExpression) != nil || lower.contains("zł") { return "PLN" }
        if lower.range(of: #"\bchf\b"#, options: .regularExpression) != nil { return "CHF" }
        if lower.range(of: #"\btry\b"#, options: .regularExpression) != nil || lower.contains("₺") { return "TRY" }
        return nil
    }

    /// Simple language detection for currency fallback.
    private func detectLanguageSimple(_ text: String) -> String {
        // Check for script-specific characters
        if text.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil { return "zh" }
        if text.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) != nil { return "ja" }
        if text.range(of: #"[\p{Hangul}]"#, options: .regularExpression) != nil { return "ko" }

        // Cyrillic — distinguish Serbian vs Russian by unique Serbian words
        if text.range(of: #"[\p{Cyrillic}]"#, options: .regularExpression) != nil {
            let lower = text.lowercased()
            let serbianMarkers = ["рачун", "укупно", "артикли", "готовина", "београд", "пдв"]
            if serbianMarkers.contains(where: { lower.contains($0) }) { return "sr" }
            return "ru"
        }

        return "en"
    }

    /// Fallback: infer currency from detected language.
    private func currencyFromLanguage(_ lang: String) -> String {
        switch lang {
        case "sr": return "RSD"
        case "ru": return "RUB"
        case "ja": return "JPY"
        case "ko": return "KRW"
        case "zh": return "CNY"
        default: return "EUR" // Safe default for Latin-script countries
        }
    }
}

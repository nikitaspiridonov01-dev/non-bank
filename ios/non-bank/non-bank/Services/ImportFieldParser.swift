import Foundation

// MARK: - Date format hint for ambiguous DD/MM vs MM/DD

enum DateFormatHint: String, CaseIterable, Identifiable {
    case dayFirst  = "DD/MM/YYYY"
    case monthFirst = "MM/DD/YYYY"

    var id: String { rawValue }
}

// MARK: - Parsed import row (before becoming a Transaction)

struct ParsedImportRow {
    var title: String
    var amount: Double
    var currency: String
    var category: String
    var date: Date
    var description: String?
    var type: TransactionType
    var emoji: String
    var repeatInterval: RepeatInterval?
    var parentReminderID: Int?
    var splitInfo: SplitInfo?
}

// MARK: - Import Field Parser

/// Stateless parsers for each transaction field.
/// All methods are pure functions — no side effects.
enum ImportFieldParser {

    // MARK: - Amount

    /// Parse amount from raw JSON value.
    /// Supports: 1000, 1 000, 1000.00, 1 000,00, +1000, -1000
    static func parseAmount(_ value: Any?) -> Double? {
        guard let value else { return nil }
        if let n = value as? Double { return n }
        if let n = value as? Int { return Double(n) }
        guard let str = value as? String else { return nil }
        return parseAmountString(str)
    }

    static func parseAmountString(_ str: String) -> Double? {
        var s = str.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }

        // Extract sign
        var sign: Double = 1.0
        if s.hasPrefix("-") { sign = -1.0; s.removeFirst() }
        else if s.hasPrefix("+") { s.removeFirst() }

        // Remove spaces (thousand separators)
        s = s.replacingOccurrences(of: " ", with: "")

        // Determine decimal separator:
        // If both , and . present, the last one is the decimal separator
        let lastComma = s.lastIndex(of: ",")
        let lastDot = s.lastIndex(of: ".")

        if let lc = lastComma, let ld = lastDot {
            if lc > ld {
                // comma is decimal: "1.000,50" → "1000.50"
                s = s.replacingOccurrences(of: ".", with: "")
                    .replacingOccurrences(of: ",", with: ".")
            } else {
                // dot is decimal: "1,000.50" → "1000.50"
                s = s.replacingOccurrences(of: ",", with: "")
            }
        } else if lastComma != nil {
            // Only commas — could be decimal or thousand
            // If exactly one comma with ≤2 digits after → decimal
            let parts = s.split(separator: ",", maxSplits: 1)
            if parts.count == 2 && parts[1].count <= 2 {
                s = s.replacingOccurrences(of: ",", with: ".")
            } else {
                // Thousand separator
                s = s.replacingOccurrences(of: ",", with: "")
            }
        }
        // dots only: standard decimal notation, no change needed

        guard let result = Double(s) else { return nil }
        return sign * result
    }

    // MARK: - Currency

    static func parseCurrency(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let code = str.trimmingCharacters(in: .whitespaces).uppercased()
        return CurrencyInfo.allCodes.contains(code) ? code : nil
    }

    // MARK: - Date

    /// Parse date from raw value. Returns nil if unparseable.
    /// `hint` resolves DD/MM vs MM/DD ambiguity.
    static func parseDate(_ value: Any?, hint: DateFormatHint = .dayFirst) -> Date? {
        guard let value else { return nil }

        // Unix timestamp (number)
        if let n = value as? Double { return Date(timeIntervalSince1970: n > 1e12 ? n / 1000 : n) }
        if let n = value as? Int { return Date(timeIntervalSince1970: Double(n > 1_000_000_000_000 ? n / 1000 : n)) }

        guard let str = (value as? String)?.trimmingCharacters(in: .whitespaces), !str.isEmpty else { return nil }

        // Unix timestamp as string
        if let ts = Double(str), ts > 1e8 {
            return Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
        }

        // ISO 8601 variants
        let isoFormatters: [DateFormatter] = {
            let formats = [
                "yyyy-MM-dd'T'HH:mm:ssZ",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm:ss Z",
                "yyyy-MM-dd HH:mm:ssZ",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd",
            ]
            return formats.map { fmt in
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                df.dateFormat = fmt
                return df
            }
        }()

        for df in isoFormatters {
            if let date = df.date(from: str) { return date }
        }

        // DD.MM.YYYY or DD.MM.YY
        if str.contains(".") {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = "dd.MM.yyyy"
            if let date = df.date(from: str) {
                let year = Calendar.current.component(.year, from: date)
                if year >= 100 { return date }
            }
            df.dateFormat = "dd.MM.yy"
            if let date = df.date(from: str) { return date }
        }

        // Slash-separated dates
        if str.contains("/") {
            let parts = str.split(separator: "/")
            // Year-first: yyyy/MM/dd or yyyy/MM/dd HH:mm(:ss)
            if let firstPart = parts.first, firstPart.count == 4 {
                let df = DateFormatter()
                df.locale = Locale(identifier: "en_US_POSIX")
                for fmt in ["yyyy/MM/dd HH:mm:ss", "yyyy/MM/dd HH:mm", "yyyy/MM/dd"] {
                    df.dateFormat = fmt
                    if let date = df.date(from: str) { return date }
                }
            }
            // Day/month first: DD/MM/YYYY or MM/DD/YYYY — use hint
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = hint == .dayFirst ? "dd/MM/yyyy" : "MM/dd/yyyy"
            if let date = df.date(from: str) {
                let year = Calendar.current.component(.year, from: date)
                if year >= 100 { return date }
            }
            df.dateFormat = hint == .dayFirst ? "dd/MM/yy" : "MM/dd/yy"
            if let date = df.date(from: str) { return date }
        }

        // Month name formats: "April 2, 2026", "Apr 2, 2026", "2 April 2026", etc.
        let nameFormats = [
            "MMMM d, yyyy", "MMMM dd, yyyy",
            "MMM d, yyyy", "MMM dd, yyyy",
            "d MMMM yyyy", "dd MMMM yyyy",
            "d MMM yyyy", "dd MMM yyyy",
        ]
        let ndf = DateFormatter()
        ndf.locale = Locale(identifier: "en_US_POSIX")
        for fmt in nameFormats {
            ndf.dateFormat = fmt
            if let date = ndf.date(from: str) { return date }
        }

        return nil
    }

    /// Check if a date field has ambiguous DD/MM vs MM/DD values.
    static func hasAmbiguousDateFormat(records: [[String: Any]], field: String) -> Bool {
        let sampleSize = min(records.count, 20)
        for i in 0..<sampleSize {
            guard let str = records[i][field] as? String else { continue }
            if str.contains("/") {
                let parts = str.split(separator: "/")
                guard parts.count == 3 else { continue }
                // If first two parts are both ≤ 12, it's ambiguous
                if let a = Int(parts[0]), let b = Int(parts[1]),
                   a >= 1 && a <= 12 && b >= 1 && b <= 12 {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - Type

    /// Normalize type string.
    static func parseType(_ value: Any?) -> TransactionType? {
        guard let str = value as? String else { return nil }
        let normalized = str.trimmingCharacters(in: .whitespaces).lowercased()
        switch normalized {
        case "expense", "expenses", "out", "payout", "pay out", "outbound",
             "minus", "debit", "withdrawal", "spend", "spending", "spendings",
             "charge", "outgoing", "expenditure", "cost", "disbursement",
             "deduction", "outflow":
            return .expenses
        case "income", "incomes", "in", "payin", "pay in", "funding",
             "inbound", "plus", "credit", "deposit", "receive", "incoming",
             "topup", "top_up", "top up", "top-up", "inflow", "load",
             "ingoing":
            return .income
        default:
            return nil
        }
    }

    /// Infer type from amount sign.
    static func typeFromAmount(_ amount: Double) -> TransactionType {
        amount < 0 ? .expenses : .income
    }

    // MARK: - Emoji

    /// Validate that value is exactly one emoji.
    static func parseEmoji(_ value: Any?) -> String? {
        guard let str = value as? String, str.count == 1 else { return nil }
        // Check the scalar is an emoji with presentation
        for scalar in str.unicodeScalars {
            if scalar.properties.isEmoji && (scalar.properties.isEmojiPresentation || scalar.value > 0x238C) {
                return str
            }
        }
        return nil
    }

    // MARK: - Title

    static func parseTitle(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Description

    static func parseDescription(_ value: Any?) -> String? {
        guard let str = value as? String else { return nil }
        let trimmed = str.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Full row parser

    /// Parse a single JSON record into a `ParsedImportRow` using the given mapping.
    /// - Parameters:
    ///   - record: One JSON object from the array
    ///   - mapping: User's field mapping (AppField → JSON field name)
    ///   - defaultCurrency: Fallback currency if not mapped
    ///   - dateHint: DD/MM vs MM/DD hint
    ///   - existingCategories: Current categories for emoji→category lookup
    ///   - hasNegativeAmounts: Whether the dataset contains negative amounts (for type inference)
    /// - Returns: Parsed row, or nil if amount fails to parse
    static func parseRow(
        record: [String: Any],
        mapping: [AppField: String],
        defaultCurrency: String,
        dateHint: DateFormatHint,
        existingCategories: [Category],
        hasNegativeAmounts: Bool
    ) -> ParsedImportRow? {

        // --- Amount (required) ---
        let rawAmount = mapping[.amount].flatMap { record[$0] }
        guard var amount = parseAmount(rawAmount) else { return nil }

        // --- Type ---
        let rawType = mapping[.type].flatMap { record[$0] }
        var txType: TransactionType
        if let parsed = parseType(rawType) {
            txType = parsed
        } else if hasNegativeAmounts {
            txType = typeFromAmount(amount)
        } else {
            txType = .expenses
        }

        // Store absolute amount
        amount = abs(amount)

        // --- Currency ---
        let currency = mapping[.currency].flatMap { parseCurrency(record[$0]) } ?? defaultCurrency

        // --- Date ---
        let rawDate = mapping[.date].flatMap { record[$0] }
        let date = parseDate(rawDate, hint: dateHint) ?? Date()

        // --- Emoji ---
        let rawEmoji = mapping[.emoji].flatMap { record[$0] }
        let parsedEmoji = parseEmoji(rawEmoji)

        // --- Category ---
        let rawCategoryValue = mapping[.category].flatMap { record[$0] }
        let rawCategory: String? = {
            if let str = rawCategoryValue as? String {
                let trimmed = str.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty ? nil : trimmed
            }
            return nil
        }()
        let isCategoryMapped = mapping[.category] != nil
        let category: String
        let emoji: String

        if let rawCategory {
            // Category value present — use it, match existing or create new
            if let match = existingCategories.first(where: { $0.title.lowercased() == rawCategory.lowercased() }) {
                category = match.title
                emoji = match.emoji
            } else {
                category = rawCategory
                emoji = parsedEmoji ?? randomEmoji()
            }
        } else if let parsedEmoji, !isCategoryMapped {
            // Emoji mapped but no category field — try to find category by emoji
            if let match = existingCategories.first(where: { $0.emoji == parsedEmoji }) {
                category = match.title
                emoji = match.emoji
            } else {
                category = "General"
                emoji = parsedEmoji
            }
        } else {
            category = "General"
            emoji = existingCategories.first(where: { $0.title == "General" })?.emoji ?? "📦"
        }

        // --- Title ---
        let rawTitle = mapping[.title].flatMap { record[$0] }
        let title = parseTitle(rawTitle) ?? "My \(category)"

        // --- Description ---
        let rawDesc = mapping[.description].flatMap { record[$0] }
        let description = parseDescription(rawDesc)

        // --- Recurring / Split fields (auto-detected from known keys) ---
        let repeatInterval: RepeatInterval? = decodeFromRecord(record, key: "repeatInterval")
        let parentReminderID = record["parentReminderID"] as? Int
        let splitInfo: SplitInfo? = decodeFromRecord(record, key: "splitInfo")

        return ParsedImportRow(
            title: title,
            amount: amount,
            currency: currency,
            category: category,
            date: date,
            description: description,
            type: txType,
            emoji: emoji,
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: splitInfo
        )
    }

    // MARK: - Batch parse

    /// Parse all records. Returns (successful rows, number of failed rows).
    static func parseAll(
        records: [[String: Any]],
        mapping: [AppField: String],
        defaultCurrency: String,
        dateHint: DateFormatHint,
        existingCategories: [Category]
    ) -> (rows: [ParsedImportRow], failedCount: Int) {

        // Pre-scan: check if dataset has negative amounts (for type inference)
        let hasNegativeAmounts: Bool = {
            guard let amountField = mapping[.amount] else { return false }
            return records.contains { record in
                if let amount = parseAmount(record[amountField]) {
                    return amount < 0
                }
                return false
            }
        }()

        var rows: [ParsedImportRow] = []
        var failed = 0

        for record in records {
            if let row = parseRow(
                record: record, mapping: mapping,
                defaultCurrency: defaultCurrency, dateHint: dateHint,
                existingCategories: existingCategories,
                hasNegativeAmounts: hasNegativeAmounts
            ) {
                rows.append(row)
            } else {
                failed += 1
            }
        }

        return (rows, failed)
    }

    // MARK: - Helpers

    /// Large curated pool of emoji guaranteed to render correctly on iOS.
    private static let curatedEmojiPool: [String] = [
        "🍅","🍆","🥑","🥦","🌶","🌽","🧀","🍎","🍏","🍐","🍑","🍒","🍓","🍇","🍈",
        "🍉","🍊","🍋","🍌","🍍","🥝","🍕","🍔","🌭","🌮","🌯","🍳","🍲","🍜","🍣",
        "🍤","🍱","🍛","🍚","🍙","🍢","🍡","🍠","🍪","🎂","🍰","🍩","🍫","🍬","🍭",
        "🍮","🍯","🍿","🧁","☕","🍵","🧃","🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼",
        "🐨","🐯","🦁","🐮","🐷","🐸","🐵","🐔","🐧","🐦","🦆","🦅","🦉","🦇","🐺",
        "🐗","🐴","🦄","🐝","🐛","🦋","🐌","🐞","🐜","🐢","🐍","🦎","🐙","🦑","🦀",
        "🐡","🐠","🐟","🐬","🐳","🦈","🐅","🐆","🦓","🐘","🐪","🦒","🦘","🦚","🦩",
        "🦜","🐿","🐉","🌺","🌻","🌼","🌷","🌹","🌾","🌿","🍀","🍁","🍂","🍃","🍄",
        "🌵","🌴","🌳","🌲","🌱","💐","🪴","🌸","📱","💻","📺","📷","📚","🔍","🔬",
        "💡","🔧","🔨","🔮","💎","🔑","💼","💰","📦","🎨","🧳","🛍","🧪","🪙","🧲",
        "🎮","🎲","🎯","🎳","🎸","🎺","🎻","🎵","🎤","🎬","🎭","🎪","🎫","🏆","🏀",
        "⚽","🏈","⚾","🎾","🧩","🎁","🎀","🎈","🎉","🎃","🎄","🎋","🎍","🎎","🎏",
        "🚗","🚕","🚌","🚂","🚀","✈️","🚢","⛵","🚲","🏠","🏢","🏰","🏔","🏖","🎠",
        "🎡","🗼","🗿","🌋","🌍","🌉","☀️","🌙","⭐","🌈","⚡","❄️","🌊","🔥","💫",
        "♻️","🏷","💌","🧿","🪐","🧬"
    ]

    /// Generate a random emoji from a curated pool (guaranteed to render on iOS).
    private static func randomEmoji() -> String {
        curatedEmojiPool.randomElement() ?? "📦"
    }

    // MARK: - JSON Decode Helper

    /// Attempts to decode a Codable value from a raw JSON record entry.
    /// Handles the case where JSONSerialization parses nested objects as [String: Any].
    private static func decodeFromRecord<T: Decodable>(_ record: [String: Any], key: String) -> T? {
        guard let rawValue = record[key] else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: rawValue) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Auto-detection

    /// How many sample records to check when detecting field types.
    private static let detectionSampleSize = 10

    /// Run all auto-detection and return a complete mapping (1:1 match + smart fallback).
    static func autoDetectMapping(
        jsonFields: [String],
        records: [[String: Any]],
        existingCategories: [Category]
    ) -> [AppField: String] {
        var result: [AppField: String] = [:]

        // Pass 1: exact 1:1 name match (case-insensitive)
        let fieldsByLower = Dictionary(jsonFields.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        for appField in AppField.allCases {
            if let jsonField = fieldsByLower[appField.rawValue] {
                result[appField] = jsonField
            }
        }

        // Pass 2: smart detection for unmatched fields
        let usedFields = Set(result.values)
        let candidates = jsonFields.filter { !usedFields.contains($0) }

        if result[.amount] == nil, let f = detectField(in: candidates, records: records, test: { parseAmount($0) != nil }) {
            result[.amount] = f
        }
        if result[.currency] == nil, let f = detectField(in: candidates, records: records, excluding: Set(result.values), test: { parseCurrency($0) != nil }) {
            result[.currency] = f
        }
        if result[.category] == nil, !existingCategories.isEmpty {
            let names = Set(existingCategories.map { $0.title.lowercased() })
            let f = detectField(in: candidates, records: records, excluding: Set(result.values)) { val in
                guard let str = val as? String else { return false }
                return names.contains(str.lowercased())
            }
            if let f { result[.category] = f }
        }
        if result[.date] == nil, let f = detectField(in: candidates, records: records, excluding: Set(result.values), test: { parseDate($0) != nil }) {
            result[.date] = f
        }
        if result[.emoji] == nil, let f = detectField(in: candidates, records: records, excluding: Set(result.values), test: { parseEmoji($0) != nil }) {
            result[.emoji] = f
        }

        return result
    }

    /// Generic field detector: returns the first candidate field where > 50% of sample values pass the test.
    private static func detectField(
        in candidates: [String],
        records: [[String: Any]],
        excluding used: Set<String> = [],
        test: (Any) -> Bool
    ) -> String? {
        let sampleSize = min(records.count, detectionSampleSize)
        guard sampleSize > 0 else { return nil }
        for field in candidates where !used.contains(field) {
            var matches = 0
            for i in 0..<sampleSize {
                if let value = records[i][field], test(value) {
                    matches += 1
                }
            }
            if matches > sampleSize / 2 { return field }
        }
        return nil
    }
}

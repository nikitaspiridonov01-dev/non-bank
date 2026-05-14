import Foundation

/// CSV codec for transaction export / import.
///
/// Columns (header row exact, in this order):
///   `date, title, description, amount, currency, type, category, emoji`
///
/// Format choices, all baked to keep the file Excel/Numbers-friendly:
///   - Dates emit ISO-8601 (`yyyy-MM-dd'T'HH:mm:ssZ`). Excel + Numbers
///     parse this as a date; non-bank's import path runs it through the
///     same flexible parser as JSON manual import.
///   - Amounts emit raw decimals with `.` separator — Excel adapts to
///     locale on display, but reading-side we strip any locale grouping
///     anyway.
///   - Sign on `amount` matches the `type` column (`Expenses` /
///     `Income`); we emit unsigned absolute values, the type column is
///     the source of truth.
///   - Strings with `,`, `"`, or newlines are quoted; literal `"`
///     escaped as `""` per RFC 4180.
///
/// Native-envelope fields (`splitInfo`, `syncID`, `repeatInterval`,
/// `payloadChecksum`) deliberately do not appear in CSV — the manual
/// import flow on the receiver wouldn't be able to reconstruct them
/// anyway. CSV is for cross-tool interop; JSON / `.xlsx` envelope-
/// shape files are for full round-trip.
enum CSVCodec {
    static let mimeType = "text/csv"
    static let fileExtension = "csv"

    private static let header = "date,title,description,amount,currency,type,category,emoji"

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Export

    static func encode(_ transactions: [Transaction]) -> String {
        var lines: [String] = [header]
        for tx in transactions {
            let row: [String] = [
                isoFormatter.string(from: tx.date),
                tx.title,
                tx.description ?? "",
                formatAmount(tx.amount),
                tx.currency,
                tx.type.rawValue,
                tx.category,
                tx.emoji
            ]
            lines.append(row.map(quote).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func formatAmount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }

    /// RFC 4180 quoting: wrap in `"` and double up any literal `"` if
    /// the value contains a separator, quote, or newline. Otherwise
    /// leave unquoted so the file looks clean in a text editor.
    private static func quote(_ value: String) -> String {
        if value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    // MARK: - Import

    /// Parse CSV into a flat list of `[field: value]` records the
    /// import wizard's manual-flow already understands. Returns `nil`
    /// when the header is missing or malformed.
    static func decode(_ text: String) -> [[String: Any]]? {
        let rows = splitRows(text)
        guard let headerLine = rows.first, !headerLine.isEmpty else { return nil }
        let columns = parseRow(headerLine).map { $0.lowercased() }
        guard !columns.isEmpty else { return nil }

        var records: [[String: Any]] = []
        for line in rows.dropFirst() where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let values = parseRow(line)
            var record: [String: Any] = [:]
            for (i, col) in columns.enumerated() where i < values.count {
                let raw = values[i]
                if raw.isEmpty { continue }
                record[col] = raw
            }
            if !record.isEmpty {
                records.append(record)
            }
        }
        return records.isEmpty ? nil : records
    }

    /// RFC 4180 quote-aware row splitter. Handles:
    ///   - quoted fields with embedded commas
    ///   - escaped `""` inside quoted fields
    ///   - CRLF and bare LF line endings
    private static func splitRows(_ text: String) -> [String] {
        var rows: [String] = []
        var current = ""
        var inQuotes = false
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\"" {
                current.append(ch)
                inQuotes.toggle()
            } else if (ch == "\n" || ch == "\r") && !inQuotes {
                if !current.isEmpty {
                    rows.append(current)
                    current = ""
                }
                // Consume CRLF as one delimiter.
                if ch == "\r", text.index(after: i) < text.endIndex, text[text.index(after: i)] == "\n" {
                    i = text.index(after: i)
                }
            } else {
                current.append(ch)
            }
            i = text.index(after: i)
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }

    /// Split a single CSV row into fields. Honours quoted fields and
    /// the `""` escape sequence.
    private static func parseRow(_ row: String) -> [String] {
        var fields: [String] = []
        var current = ""
        var inQuotes = false
        var i = row.startIndex
        while i < row.endIndex {
            let ch = row[i]
            if ch == "\"" {
                let next = row.index(after: i)
                if inQuotes, next < row.endIndex, row[next] == "\"" {
                    current.append("\"")
                    i = next
                } else {
                    inQuotes.toggle()
                }
            } else if ch == "," && !inQuotes {
                fields.append(current)
                current = ""
            } else {
                current.append(ch)
            }
            i = row.index(after: i)
        }
        fields.append(current)
        return fields
    }
}

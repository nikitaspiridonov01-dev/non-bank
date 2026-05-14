import Foundation
import Compression

/// Minimal `.xlsx` (Office Open XML) codec for transaction export /
/// import. Hand-rolled so we don't pull in an SPM dependency for a
/// single-sheet, 8-column file.
///
/// Export shape — single worksheet named `Transactions` with the same
/// column order as `CSVCodec`. Cell values are written as inline
/// strings (`<is><t>…</t></is>`) so we don't have to maintain a
/// shared-strings table. Excel/Numbers happily round-trip the file.
///
/// Import shape — reads the first worksheet, extracts the header row,
/// then maps each subsequent row into `[String: Any]` keyed by header
/// column. The result feeds the same manual-import wizard as JSON/CSV.
///
/// ZIP layer:
///   - Write: STORE-only (compression method 0). Bigger files but no
///     deflate stream to maintain. Excel reads STORE archives fine.
///   - Read: handles both STORE (0) and DEFLATE (8). The Compression
///     framework decompresses DEFLATE bytes (raw, no zlib header) —
///     this is what Excel-saved files use.
enum XLSXCodec {
    static let mimeType = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
    static let fileExtension = "xlsx"

    // Header is matched against CSVCodec verbatim so a user can edit
    // an exported CSV in Excel, save as .xlsx, and re-import without
    // remapping columns.
    static let header = ["date", "title", "description", "amount", "currency", "type", "category", "emoji"]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    // MARK: - Encode

    static func encode(_ transactions: [Transaction]) throws -> Data {
        let rows = transactions.map { tx -> [String] in
            [
                isoFormatter.string(from: tx.date),
                tx.title,
                tx.description ?? "",
                formatAmount(tx.amount),
                tx.currency,
                tx.type.rawValue,
                tx.category,
                tx.emoji
            ]
        }
        let sheetXML = buildSheetXML(header: header, rows: rows)
        let entries: [ZipEntry] = [
            ZipEntry(path: "[Content_Types].xml", data: Self.contentTypesXML),
            ZipEntry(path: "_rels/.rels", data: Self.rootRelsXML),
            ZipEntry(path: "xl/workbook.xml", data: Self.workbookXML),
            ZipEntry(path: "xl/_rels/workbook.xml.rels", data: Self.workbookRelsXML),
            ZipEntry(path: "xl/worksheets/sheet1.xml", data: sheetXML.data(using: .utf8) ?? Data())
        ]
        return MinimalZip.write(entries: entries)
    }

    private static func formatAmount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }

    // MARK: - Decode

    static func decode(_ data: Data) -> [[String: Any]]? {
        guard let entries = MinimalZip.read(data: data) else { return nil }
        // Look for the first worksheet. Real-world Excel writes
        // `xl/worksheets/sheet1.xml` (lowercased) — we don't bother
        // following the workbook rels chain, the first xl/worksheets
        // file is good enough.
        guard let sheetEntry = entries.first(where: {
            $0.path.hasPrefix("xl/worksheets/") && $0.path.hasSuffix(".xml")
        }) else { return nil }

        var sharedStrings: [String] = []
        if let ssEntry = entries.first(where: { $0.path == "xl/sharedStrings.xml" }),
           let parsed = parseSharedStrings(data: ssEntry.data) {
            sharedStrings = parsed
        }

        guard let rows = parseSheet(data: sheetEntry.data, sharedStrings: sharedStrings),
              let headerRow = rows.first else { return nil }

        let columns = headerRow.map { $0.lowercased() }
        var records: [[String: Any]] = []
        for row in rows.dropFirst() where !row.allSatisfy({ $0.isEmpty }) {
            var record: [String: Any] = [:]
            for (i, col) in columns.enumerated() where i < row.count {
                let value = row[i]
                if value.isEmpty { continue }
                record[col] = value
            }
            if !record.isEmpty { records.append(record) }
        }
        return records.isEmpty ? nil : records
    }

    // MARK: - XML scaffolding (static stuff that never changes)

    private static let contentTypesXML: Data = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
      <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
    </Types>
    """.data(using: .utf8) ?? Data()

    private static let rootRelsXML: Data = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
    </Relationships>
    """.data(using: .utf8) ?? Data()

    private static let workbookXML: Data = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"
              xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
      <sheets>
        <sheet name="Transactions" sheetId="1" r:id="rId1"/>
      </sheets>
    </workbook>
    """.data(using: .utf8) ?? Data()

    private static let workbookRelsXML: Data = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
    </Relationships>
    """.data(using: .utf8) ?? Data()

    // MARK: - Sheet XML build

    /// Generate the worksheet XML for a header row + N data rows.
    /// Every cell ships as an inline string so we don't have to maintain
    /// a `xl/sharedStrings.xml` part. Excel converts numeric-looking
    /// strings back to numbers automatically when the user clicks the
    /// cell, so this stays portable.
    private static func buildSheetXML(header: [String], rows: [[String]]) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <sheetData>
        """
        xml += rowXML(values: header, rowIndex: 1)
        for (i, row) in rows.enumerated() {
            xml += rowXML(values: row, rowIndex: i + 2)
        }
        xml += "</sheetData></worksheet>"
        return xml
    }

    private static func rowXML(values: [String], rowIndex: Int) -> String {
        var row = "<row r=\"\(rowIndex)\">"
        for (i, value) in values.enumerated() {
            let cellRef = "\(columnLetter(i))\(rowIndex)"
            row += "<c r=\"\(cellRef)\" t=\"inlineStr\"><is><t>\(escapeXML(value))</t></is></c>"
        }
        row += "</row>"
        return row
    }

    /// 0-indexed column number → Excel column letter (`A`, `B`, …, `Z`,
    /// `AA`, `AB` …). The export only needs columns A–H but the helper
    /// is generic so future schema additions don't have to special-case.
    private static func columnLetter(_ index: Int) -> String {
        var n = index
        var s = ""
        repeat {
            let r = n % 26
            s = String(UnicodeScalar(65 + r)!) + s
            n = n / 26 - 1
        } while n >= 0
        return s
    }

    private static func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
         .replacingOccurrences(of: "'", with: "&apos;")
    }

    // MARK: - Sheet XML parse

    /// Extract every row as an array of string cell values. Looks up
    /// shared-string indexes via `sharedStrings`; inline strings come
    /// out of `<is><t>…</t></is>`; numeric / generic cells use `<v>`.
    /// Missing cells in the middle of a row are padded with `""` so
    /// header→column alignment stays right.
    private static func parseSheet(data: Data, sharedStrings: [String]) -> [[String]]? {
        let parser = XMLParser(data: data)
        let delegate = SheetParserDelegate(sharedStrings: sharedStrings)
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.rows
    }

    private static func parseSharedStrings(data: Data) -> [String]? {
        let parser = XMLParser(data: data)
        let delegate = SharedStringsDelegate()
        parser.delegate = delegate
        guard parser.parse() else { return nil }
        return delegate.strings
    }
}

// MARK: - XLSX XML parsers

private final class SheetParserDelegate: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [[String]] = []
    private var currentRow: [String]?
    private var currentColumnIndex: Int = 0
    private var currentCellType: String?
    private var currentCellRef: String?
    private var inValue: Bool = false
    private var inInlineString: Bool = false
    private var inSharedString: Bool = false
    private var currentText: String = ""

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        switch elementName {
        case "row":
            currentRow = []
            currentColumnIndex = 0
        case "c":
            currentCellType = attributeDict["t"]
            currentCellRef = attributeDict["r"]
            // Pad with empty strings if the previous cell skipped some
            // columns (Excel does this when a cell is empty).
            if let ref = currentCellRef,
               let row = currentRow,
               let targetIndex = Self.columnIndex(fromCellRef: ref) {
                while row.count + (currentRow == nil ? 0 : 0) < targetIndex {
                    currentRow?.append("")
                }
            }
        case "v":
            inValue = true
            currentText = ""
        case "is":
            inInlineString = true
        case "t":
            if inInlineString { currentText = "" }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue || inInlineString {
            currentText += string
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        switch elementName {
        case "v":
            inValue = false
            if currentCellType == "s" {
                if let idx = Int(currentText), idx >= 0, idx < sharedStrings.count {
                    currentRow?.append(sharedStrings[idx])
                } else {
                    currentRow?.append("")
                }
            } else {
                currentRow?.append(currentText)
            }
        case "is":
            inInlineString = false
            currentRow?.append(currentText)
        case "c":
            currentCellType = nil
            currentCellRef = nil
        case "row":
            if let row = currentRow { rows.append(row) }
            currentRow = nil
        default:
            break
        }
    }

    /// Map an Excel cell ref like `B3` → 0-based column index `1`.
    private static func columnIndex(fromCellRef ref: String) -> Int? {
        let letters = ref.prefix(while: { $0.isLetter })
        guard !letters.isEmpty else { return nil }
        var n = 0
        for ch in letters {
            guard let scalar = ch.uppercased().unicodeScalars.first else { return nil }
            n = n * 26 + (Int(scalar.value) - 64)
        }
        return n - 1
    }
}

private final class SharedStringsDelegate: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var currentText: String = ""
    private var inText: Bool = false

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "t" {
            inText = true
            currentText = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { currentText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "t" {
            inText = false
        } else if elementName == "si" {
            strings.append(currentText)
            currentText = ""
        }
    }
}

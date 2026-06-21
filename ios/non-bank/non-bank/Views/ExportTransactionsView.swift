import SwiftUI

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"
    case csv = "CSV"
    case xlsx = "Excel"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .json: return "json"
        case .csv: return CSVCodec.fileExtension
        case .xlsx: return XLSXCodec.fileExtension
        }
    }

    /// Native non-bank envelope is the only format that survives full
    /// round-trip (split info, receipt items, etc.). CSV / XLSX are
    /// flat tabular interop formats — they drop split metadata so they
    /// can be opened in Excel / Numbers without a schema mismatch.
    var roundTripsFully: Bool {
        switch self {
        case .json: return true
        case .csv, .xlsx: return false
        }
    }
}

// MARK: - Export Transactions Screen

struct ExportTransactionsView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.dismiss) private var dismiss

    @State private var startDate: Date = Calendar.current.date(byAdding: .month, value: -1, to: Date()) ?? Date()
    @State private var endDate: Date = Date()
    @State private var exportFormat: ExportFormat = .json
    @State private var exportFileURL: IdentifiableURL?

    // MARK: - Computed

    private var filteredTransactions: [Transaction] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: endDate)) ?? endDate
        return transactionStore.transactions.filter { $0.date >= start && $0.date < end }
    }

    private var hasTransactions: Bool {
        !filteredTransactions.isEmpty
    }

    /// Friends referenced by any exported transaction's split info.
    /// We don't dump the whole address book — only the people the
    /// importer would otherwise see as broken UUID references.
    private func friendsForExport(_ transactions: [Transaction]) -> [Friend] {
        var referencedIDs = Set<String>()
        for tx in transactions {
            if let shares = tx.splitInfo?.friends {
                for share in shares { referencedIDs.insert(share.friendID) }
            }
        }
        guard !referencedIDs.isEmpty else { return [] }
        return friendStore.friends.filter { referencedIDs.contains($0.id) }
    }

    /// Receipt items belonging to any exported transaction, keyed by
    /// `transactionSyncID` (not the local autoincrement id, which won't
    /// survive the re-import).
    private func receiptItemsForExport(_ transactions: [Transaction]) -> [ExportedReceiptItem] {
        let syncIDByTransactionID = Dictionary(
            uniqueKeysWithValues: transactions.map { ($0.id, $0.syncID) }
        )
        var result: [ExportedReceiptItem] = []
        for item in receiptItemStore.items {
            guard let txID = item.transactionID,
                  let syncID = syncIDByTransactionID[txID] else { continue }
            result.append(ExportedReceiptItem(from: item, transactionSyncID: syncID))
        }
        return result
    }

    private func buildExportEnvelope() -> NonBankExport {
        let txs = filteredTransactions
        return NonBankExport(
            schemaVersion: NonBankExport.currentSchemaVersion,
            exportedAt: Date(),
            transactions: txs,
            friends: friendsForExport(txs),
            receiptItems: receiptItemsForExport(txs)
        )
    }

    private var estimatedFileSize: String {
        let bytes: Int
        switch exportFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            bytes = (try? encoder.encode(buildExportEnvelope()))?.count ?? 0
        case .csv:
            bytes = CSVCodec.encode(filteredTransactions).utf8.count
        case .xlsx:
            bytes = (try? XLSXCodec.encode(filteredTransactions))?.count ?? 0
        }
        guard bytes > 0 else { return "—" }
        let kb = Double(bytes) / 1024.0
        if kb < 1 {
            return "~\(bytes) B"
        } else if kb < 1024 {
            return String(format: "~%.0f KB", kb)
        } else {
            return String(format: "~%.1f MB", kb / 1024.0)
        }
    }

    // MARK: - File naming

    private var exportFileName: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "dd-MM-yyyy"
        return "\(fmt.string(from: startDate))__\(fmt.string(from: endDate)).\(exportFormat.fileExtension)"
    }

    // MARK: - Format footer copy

    /// Footer text below the format picker. JSON gets the simple
    /// "full backup" line; CSV / Excel get a short warning that
    /// splits and receipt items are dropped — without dragging the
    /// user through implementation details.
    @ViewBuilder
    private var formatFooter: some View {
        switch exportFormat {
        case .json:
            Text("Full backup. Keeps everything, including splits and receipt items.")
                .font(AppFonts.footnote)
                .foregroundColor(AppColors.textTertiary)
        case .csv, .xlsx:
            Text("For opening in Excel, Numbers or Sheets. Splits and receipt items aren't saved — use JSON for a full backup.")
                .font(AppFonts.footnote)
                .foregroundColor(AppColors.warning)
        }
    }

    // MARK: - Body

    var body: some View {
        List {
            // Date range
            Section(header: Text("Date Range").foregroundColor(AppColors.textSecondary)) {
                DatePicker("Start date", selection: $startDate, in: ...Date(), displayedComponents: .date)
                DatePicker("End date", selection: $endDate, in: ...Date(), displayedComponents: .date)
            }
            .listRowBackground(AppColors.backgroundElevated)

            // Format
            Section(
                header: Text("Format").foregroundColor(AppColors.textSecondary),
                footer: formatFooter
            ) {
                Picker("Export format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.menu)
            }
            .listRowBackground(AppColors.backgroundElevated)

            // Result summary
            Section {
                if hasTransactions {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(filteredTransactions.count) transactions found")
                            .font(AppFonts.body)
                        Text("Estimated file size: \(estimatedFileSize)")
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .padding(.vertical, AppSpacing.xs)
                } else {
                    Text("No transactions found for this period. Nothing to export.")
                        .font(AppFonts.emojiSmall)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.vertical, AppSpacing.xs)
                }
            }
            .listRowBackground(AppColors.backgroundElevated)

            // Export button
            Section {
                Button {
                    exportTransactions()
                } label: {
                    HStack {
                        Spacer()
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(AppFonts.bodyEmphasized)
                        Spacer()
                    }
                }
                .disabled(!hasTransactions)
            }
            .listRowBackground(AppColors.backgroundElevated)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Export Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { router.hideTabBar = true }
        // Restore the bar on ANY exit (back, swipe, tab switch) — relying only
        // on SettingsView.onAppear to reset it leaked the bar when the user
        // left by another path.
        .onDisappear { router.hideTabBar = false }
        .sheet(item: $exportFileURL) { item in
            ShareSheet(activityItems: [item.url])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Export logic

    private func exportTransactions() {
        let data: Data?
        switch exportFormat {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            data = try? encoder.encode(buildExportEnvelope())
        case .csv:
            // Strip BOM-less UTF-8 — Excel on Mac is happy without it
            // and Numbers reads it correctly. iOS doesn't add one by
            // default.
            data = CSVCodec.encode(filteredTransactions).data(using: .utf8)
        case .xlsx:
            data = try? XLSXCodec.encode(filteredTransactions)
        }
        guard let payload = data else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(exportFileName)

        do {
            try payload.write(to: fileURL, options: .atomic)
            exportFileURL = IdentifiableURL(url: fileURL)
        } catch {
            // Silently fail — file write to temp should rarely fail
        }
    }
}

// MARK: - Identifiable URL wrapper for .sheet(item:)

struct IdentifiableURL: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - UIKit Share Sheet wrapper

struct ShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

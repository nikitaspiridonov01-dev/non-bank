import SwiftUI

// MARK: - Export Format

enum ExportFormat: String, CaseIterable, Identifiable {
    case json = "JSON"

    var id: String { rawValue }
    var fileExtension: String {
        switch self {
        case .json: return "json"
        }
    }
}

// MARK: - Export Transactions Screen

struct ExportTransactionsView: View {
    @EnvironmentObject var transactionStore: TransactionStore
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

    private var estimatedFileSize: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(filteredTransactions) else { return "—" }
        let kb = Double(data.count) / 1024.0
        if kb < 1 {
            return "~\(data.count) B"
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

    // MARK: - Body

    var body: some View {
        List {
            // Date range
            Section(header: Text("Date Range")) {
                DatePicker("Start date", selection: $startDate, in: ...Date(), displayedComponents: .date)
                DatePicker("End date", selection: $endDate, in: ...Date(), displayedComponents: .date)
            }

            // Format
            Section(header: Text("Format")) {
                Picker("Export format", selection: $exportFormat) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.rawValue).tag(format)
                    }
                }
                .pickerStyle(.menu)
            }

            // Result summary
            Section {
                if hasTransactions {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(filteredTransactions.count) transactions found")
                            .font(AppFonts.body)
                        Text("Estimated file size: \(estimatedFileSize)")
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, AppSpacing.xs)
                } else {
                    Text("No transactions found for this period. Nothing to export.")
                        .font(AppFonts.emojiSmall)
                        .foregroundColor(.secondary)
                        .padding(.vertical, AppSpacing.xs)
                }
            }

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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Export Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { router.hideTabBar = true }
        .sheet(item: $exportFileURL) { item in
            ShareSheet(activityItems: [item.url])
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Export logic

    private func exportTransactions() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        guard let data = try? encoder.encode(filteredTransactions) else { return }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent(exportFileName)

        do {
            try data.write(to: fileURL, options: .atomic)
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

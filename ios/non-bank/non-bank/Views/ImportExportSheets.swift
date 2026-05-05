import SwiftUI
import UniformTypeIdentifiers

// MARK: - Export Sheet (stub)

struct ExportSheetView: View {
    @Binding var isPresented: Bool
    var body: some View {
        VStack(spacing: AppSpacing.xxl) {
            Text("Export Data")
                .font(.title2)
                .padding(.top)
            Text("Здесь будет экспорт данных приложения.")
                .foregroundColor(.secondary)
            Button("Close") {
                isPresented = false
            }
            .padding(.top, AppSpacing.lg)
        }
        .padding()
    }
}

// MARK: - Import Sheet

struct ImportSheetView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @Binding var isPresented: Bool
    @State private var importError: String? = nil
    @State private var isImporterPresented = false
    
    var body: some View {
        VStack(spacing: AppSpacing.xxl) {
            Text("Import Data")
                .font(.title2)
                .padding(.top)
            Text("Импортируйте JSON-файл с транзакциями. Формат см. в документации.")
                .foregroundColor(.secondary)
            Button("Выбрать файл для импорта") {
                isImporterPresented = true
            }
            .padding(.top, AppSpacing.sm)
            if let importError = importError {
                Text(importError)
                    .foregroundColor(.red)
            }
            Button("Close") {
                isPresented = false
            }
            .padding(.top, AppSpacing.lg)
        }
        .padding()
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    // Копируем файл во временную директорию для доступа
                    let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                    if FileManager.default.fileExists(atPath: tmpURL.path) {
                        try FileManager.default.removeItem(at: tmpURL)
                    }
                    try FileManager.default.copyItem(at: url, to: tmpURL)
                    let data = try Data(contentsOf: tmpURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .formatted(Self.dateFormatter)
                    let imported = try decoder.decode([TransactionImportDTO].self, from: data)
                    for dto in imported {
                        if let tx = dto.toTransaction() {
                            transactionStore.add(tx)
                        }
                    }
                    isPresented = false
                } catch {
                    importError = "Ошибка импорта: \(error.localizedDescription)"
                }
            case .failure(let error):
                importError = "Ошибка выбора файла: \(error.localizedDescription)"
            }
        }
    }

    // DTO для импорта (без id, tags опциональны)
    struct TransactionImportDTO: Codable {
        let emoji: String
        let category: String
        let title: String
        let description: String?
        let amount: Double
        let currency: String
        let type: String
        let isIncome: Bool
        let date: String

        // New optional fields for reminders/split import
        let repeatInterval: RepeatInterval?
        let parentReminderID: Int?
        let splitInfo: SplitInfo?

        func toTransaction() -> Transaction? {
            let formatter = ImportSheetView.dateFormatter
            guard let dateObj = formatter.date(from: date) else { return nil }
            let txType = TransactionType(rawValue: type) ?? (isIncome ? .income : .expenses)
            return Transaction(
                id: 0,
                emoji: emoji,
                category: category,
                title: title,
                description: description,
                amount: amount,
                currency: currency,
                date: dateObj,
                type: txType,
                tags: nil,
                repeatInterval: repeatInterval,
                parentReminderID: parentReminderID,
                splitInfo: splitInfo
            )
        }
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

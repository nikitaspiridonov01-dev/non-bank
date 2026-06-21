import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import State

enum ImportState: Equatable {
    case idle
    case loading
    /// Generic JSON file — user goes through the manual mapping wizard.
    case parsed(fields: [String], records: [[String: Any]], preview: String)
    /// Native non-bank envelope — the wizard is skipped entirely and the
    /// user lands straight on the review screen.
    case parsedNative(NonBankExport)
    case error(String)

    static func == (lhs: ImportState, rhs: ImportState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading): return true
        case (.error(let a), .error(let b)): return a == b
        case (.parsed(let f1, let r1, _), .parsed(let f2, let r2, _)):
            return f1 == f2 && r1.count == r2.count
        case (.parsedNative(let a), .parsedNative(let b)):
            return a.transactions.count == b.transactions.count &&
                   a.friends.count == b.friends.count &&
                   a.receiptItems.count == b.receiptItems.count
        default: return false
        }
    }
}

// MARK: - Import Transactions Screen (Phase 1)

struct ImportTransactionsView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    @EnvironmentObject var router: NavigationRouter

    @Binding var isFlowActive: Bool

    @State private var importState: ImportState = .idle
    @State private var showFilePicker = false
    @State private var fileName: String = ""

    var body: some View {
        VStack(spacing: 0) {
            List {
                // File selection
                Section {
                    // Explicit title/icon styling — `Label("...",
                    // systemImage:)` inside a `Button` tints the
                    // whole label with accent, dropping contrast on
                    // the text against the cream row fill. Mirrors
                    // the Settings `Currencies` / `Categories`
                    // pattern: dark text + accent-coloured icon.
                    Button {
                        showFilePicker = true
                    } label: {
                        Label {
                            Text("Choose a file").foregroundColor(AppColors.textPrimary)
                        } icon: {
                            Image(systemName: "doc.badge.plus").foregroundColor(.accentColor)
                        }
                    }
                } footer: {
                    Text("JSON, CSV or Excel (.xlsx).")
                        .font(AppFonts.metaRegular)
                        .foregroundColor(AppColors.textSecondary)
                }
                .listRowBackground(AppColors.backgroundElevated)

                // Status
                switch importState {
                case .idle:
                    EmptyView()

                case .loading:
                    Section {
                        HStack {
                            ProgressView()
                                .padding(.trailing, AppSpacing.sm)
                            Text("Reading file…")
                                .foregroundColor(AppColors.textSecondary)
                        }
                    }
                    .listRowBackground(AppColors.backgroundElevated)

                case .parsed(let fields, let records, _):
                    Section(header: Text("File Info").foregroundColor(AppColors.textSecondary)) {
                        if !fileName.isEmpty {
                            HStack {
                                Text("File")
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                                Text(fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        HStack {
                            Text("Transactions detected")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(records.count)")
                                .fontWeight(.medium)
                        }
                        HStack {
                            Text("Fields found")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(fields.count)")
                                .fontWeight(.medium)
                        }
                    }
                    .listRowBackground(AppColors.backgroundElevated)

                    Section(header: Text("Detected Fields").foregroundColor(AppColors.textSecondary)) {
                        ForEach(fields, id: \.self) { field in
                            Text(field)
                                .font(.system(size: 15, design: .monospaced))
                        }
                    }
                    .listRowBackground(AppColors.backgroundElevated)

                case .parsedNative(let envelope):
                    Section(header: Text("File Info").foregroundColor(AppColors.textSecondary)) {
                        if !fileName.isEmpty {
                            HStack {
                                Text("File")
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                                Text(fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        HStack {
                            Text("Format")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Label("non-bank export", systemImage: "checkmark.seal.fill")
                                .font(AppFonts.metaRegular)
                                .foregroundColor(.accentColor)
                        }
                        HStack {
                            Text("Transactions")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(envelope.transactions.count)")
                                .fontWeight(.medium)
                        }
                        if !envelope.friends.isEmpty {
                            HStack {
                                Text("Friends")
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                                Text("\(envelope.friends.count)")
                                    .fontWeight(.medium)
                            }
                        }
                        if !envelope.receiptItems.isEmpty {
                            HStack {
                                Text("Receipt items")
                                    .foregroundColor(AppColors.textSecondary)
                                Spacer()
                                Text("\(envelope.receiptItems.count)")
                                    .fontWeight(.medium)
                            }
                        }
                    }
                    .listRowBackground(AppColors.backgroundElevated)

                case .error(let message):
                    Section {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Label("Import Error", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(AppColors.danger)
                                .font(AppFonts.body)
                            Text(message)
                                .font(AppFonts.emojiSmall)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        .padding(.vertical, AppSpacing.xs)
                    }
                    .listRowBackground(AppColors.backgroundElevated)
                }
            }
            .listStyle(.insetGrouped)

            // Pinned bottom button
            if case .parsed(let fields, let records, _) = importState {
                VStack(spacing: 0) {
                    Divider()
                    NavigationLink {
                        FieldMappingView(
                            jsonFields: fields,
                            jsonRecords: records,
                            isFlowActive: $isFlowActive
                        )
                        .environmentObject(transactionStore)
                        .environmentObject(categoryStore)
                        .environmentObject(currencyStore)
                    } label: {
                        // Same `accentBold` swap as the other wizard
                        // CTAs — white-on-light-accent only hit ~2.6:1
                        // in dark mode.
                        Text("Continue to Field Mapping")
                            .font(AppFonts.bodyEmphasized)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppColors.accentBold)
                            .foregroundColor(.white)
                            .cornerRadius(AppRadius.medium)
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.vertical, AppSpacing.rowVertical)
                }
                .background(AppColors.backgroundElevated)
            } else if case .parsedNative(let envelope) = importState {
                VStack(spacing: 0) {
                    Divider()
                    NavigationLink {
                        ImportSummaryView(
                            source: .native(envelope: envelope),
                            isFlowActive: $isFlowActive
                        )
                        .environmentObject(transactionStore)
                        .environmentObject(categoryStore)
                        .environmentObject(currencyStore)
                        .environmentObject(friendStore)
                        .environmentObject(receiptItemStore)
                    } label: {
                        // `accentBold` (not `Color.accentColor`) — the
                        // lighter `Color.accentColor` only hits ~2.6:1
                        // against white text and reads as a pale peach
                        // chip in dark mode. `accentBold` is the
                        // deeper variant designed for **filled** CTAs
                        // where the label sits inside; lands ≥3:1 in
                        // both themes. Same swap as the onboarding /
                        // settle-up CTAs.
                        Text("Review Import")
                            .font(AppFonts.bodyEmphasized)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(AppColors.accentBold)
                            .foregroundColor(.white)
                            .cornerRadius(AppRadius.medium)
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.vertical, AppSpacing.rowVertical)
                }
                .background(AppColors.backgroundElevated)
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Import Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { router.hideTabBar = true }
        // Restore the bar on ANY exit, not only when SettingsView re-appears.
        .onDisappear { router.hideTabBar = false }
        .fileImporter(
            isPresented: $showFilePicker,
            // Three accepted entry-points: JSON (native envelope or
            // generic), CSV (interchange with Excel / Numbers / Sheets),
            // and `.xlsx` (Office Open XML). The parser picks the
            // codec based on file extension at decode time so a user
            // who renamed a CSV to .json doesn't accidentally land
            // in the JSON wizard.
            allowedContentTypes: Self.allowedImportContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
    }

    /// UTTypes accepted by the file picker. `xlsx` and `csv` aren't in
    /// the standard `UTType` constants — we resolve them by MIME / file
    /// extension so any iOS version supports them. Wrapped in an
    /// `if let` array build so we fall back gracefully on the rare
    /// device where one fails to register.
    private static var allowedImportContentTypes: [UTType] {
        var types: [UTType] = [.json]
        if let csv = UTType(filenameExtension: "csv") { types.append(csv) }
        if let xlsx = UTType(filenameExtension: "xlsx") { types.append(xlsx) }
        return types
    }

    // MARK: - File handling

    private func handleFileSelection(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                importState = .error("No file selected.")
                return
            }
            fileName = url.lastPathComponent
            importState = .loading
            parseFile(at: url)

        case .failure(let error):
            importState = .error(error.localizedDescription)
        }
    }

    /// Format dispatcher. Sniffs the file extension and routes to the
    /// matching codec; falls back to JSON parsing for unknown
    /// extensions so a user who renamed `.json` to `.txt` still works.
    private func parseFile(at url: URL) {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "csv":  parseCSV(at: url)
        case "xlsx": parseXLSX(at: url)
        default:     parseJSON(at: url)
        }
    }

    private func parseJSON(at url: URL) {
        // Security-scoped resource access for files from Files app / iCloud
        guard url.startAccessingSecurityScopedResource() else {
            importState = .error("Cannot access the selected file. Please try again.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let data = try Data(contentsOf: url)

            // First: try the native non-bank envelope. If the file
            // decodes cleanly into `NonBankExport`, skip the manual
            // wizard and jump straight to the review screen.
            if let envelope = decodeNativeEnvelope(from: data) {
                importState = .parsedNative(envelope)
                return
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                importState = .error("The file must contain a JSON array of objects.\n\nExample:\n[\n  { \"title\": \"...\", \"amount\": 100 },\n  ...\n]")
                return
            }

            guard !json.isEmpty else {
                importState = .error("The JSON array is empty. Nothing to import.")
                return
            }

            // Collect all unique field names across all records
            var fieldSet = Set<String>()
            for record in json {
                fieldSet.formUnion(record.keys)
            }
            let fields = fieldSet.sorted()

            // Validate that at least one field can be used as amount
            let hasAmountCandidate = fields.contains { jsonField in
                let sampleSize = min(json.count, 10)
                guard sampleSize > 0 else { return false }
                var matches = 0
                for i in 0..<sampleSize {
                    if let value = json[i][jsonField], ImportFieldParser.parseAmount(value) != nil {
                        matches += 1
                    }
                }
                return Double(matches) / Double(sampleSize) > 0.3
            }

            guard hasAmountCandidate else {
                importState = .error("None of the fields in your file can be used as a transaction amount.\n\nPlease make sure your file contains numeric values that represent amounts.")
                return
            }

            importState = .parsed(fields: fields, records: json, preview: "")

        } catch {
            importState = .error("Failed to parse JSON: \(error.localizedDescription)")
        }
    }

    /// CSV file → manual import flow. CSV doesn't carry split / sync
    /// metadata, so it always goes through the field-mapping wizard
    /// (same path as a third-party JSON file). The codec's pre-set
    /// header gives the auto-mapping step an obvious starting point.
    private func parseCSV(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            importState = .error("Cannot access the selected file. Please try again.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
                importState = .error("The CSV file isn't readable as text. Try saving it as UTF-8.")
                return
            }
            guard let records = CSVCodec.decode(text), !records.isEmpty else {
                importState = .error("Couldn't parse rows from the CSV. Make sure the first line is a header.")
                return
            }
            promoteRecordsForManualImport(records)
        } catch {
            importState = .error("Failed to read CSV: \(error.localizedDescription)")
        }
    }

    /// `.xlsx` file → manual import flow, same as CSV. Excel-saved
    /// files use DEFLATE-compressed ZIP entries; the codec handles
    /// both STORE and DEFLATE so user-edited Excel exports work.
    private func parseXLSX(at url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            importState = .error("Cannot access the selected file. Please try again.")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let data = try Data(contentsOf: url)
            guard let records = XLSXCodec.decode(data), !records.isEmpty else {
                importState = .error("Couldn't parse rows from the Excel file. Make sure the first sheet has a header row.")
                return
            }
            promoteRecordsForManualImport(records)
        } catch {
            importState = .error("Failed to read Excel file: \(error.localizedDescription)")
        }
    }

    /// Convert decoded CSV / XLSX rows into the wizard's existing
    /// `(fields, records)` state and validate the same amount-column
    /// heuristic the JSON path uses. Pulled out so both flat-table
    /// importers stay in sync with the JSON one.
    private func promoteRecordsForManualImport(_ records: [[String: Any]]) {
        var fieldSet = Set<String>()
        for record in records { fieldSet.formUnion(record.keys) }
        let fields = fieldSet.sorted()

        let hasAmountCandidate = fields.contains { jsonField in
            let sampleSize = min(records.count, 10)
            guard sampleSize > 0 else { return false }
            var matches = 0
            for i in 0..<sampleSize {
                if let value = records[i][jsonField], ImportFieldParser.parseAmount(value) != nil {
                    matches += 1
                }
            }
            return Double(matches) / Double(sampleSize) > 0.3
        }
        guard hasAmountCandidate else {
            importState = .error("None of the columns in your file can be used as a transaction amount.\n\nMake sure your file has a numeric amount column.")
            return
        }
        importState = .parsed(fields: fields, records: records, preview: "")
    }

    /// Try to read the file as a native non-bank export. Returns `nil`
    /// when the top-level isn't a `NonBankExport`-shaped object, when
    /// `schemaVersion` doesn't match what we know how to read, or when
    /// any required field on the transactions array fails to decode.
    /// Falling back to `nil` is the signal for "treat this as a generic
    /// third-party JSON file and use the manual mapping wizard."
    private func decodeNativeEnvelope(from data: Data) -> NonBankExport? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(NonBankExport.self, from: data) else {
            return nil
        }
        guard envelope.schemaVersion == NonBankExport.currentSchemaVersion else {
            return nil
        }
        guard !envelope.transactions.isEmpty else {
            return nil
        }
        return envelope
    }
}

// MARK: - App fields for mapping

enum AppField: String, CaseIterable, Identifiable {
    case title, amount, currency, category, date, description, type, emoji

    var id: String { rawValue }

    var label: String {
        switch self {
        case .title:       return "Title"
        case .amount:      return "Amount"
        case .currency:    return "Currency"
        case .category:    return "Category"
        case .date:        return "Date"
        case .description: return "Description"
        case .type:        return "Expense / Income"
        case .emoji:       return "Emoji"
        }
    }

    var isRequired: Bool {
        self == .amount
    }

    var fallbackDescription: String {
        switch self {
        case .title:       return "Generated automatically"
        case .amount:      return "Required"
        case .currency:    return "Uses the currency selected as default"
        case .category:    return "Uses \"General\" category"
        case .date:        return "Uses import date"
        case .description: return "Empty description"
        case .type:        return "Calculates depending on amount format"
        case .emoji:       return "Uses category emoji"
        }
    }
}

// MARK: - Field Mapping View (Step-by-step)

/// The 8 mapping steps in order.
private let mappingSteps: [AppField] = [
    .amount, .currency, .category, .date, .title, .description, .type, .emoji
]

struct FieldMappingView: View {
    let jsonFields: [String]
    let jsonRecords: [[String: Any]]

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore

    @Binding var isFlowActive: Bool

    @State private var mapping: [AppField: String] = [:]
    @State private var didInitialize = false
    @State private var defaultCurrency: String = "USD"
    @State private var dateFormatHint: DateFormatHint = .dayFirst
    @State private var currentStep = 0
    @State private var showExamplesSheet = false
    @Environment(\.presentationMode) private var presentationMode

    /// Sentinel value for "not mapped"
    private let notMapped = "__not_mapped__"

    private var currentField: AppField { mappingSteps[currentStep] }
    private var totalSteps: Int { mappingSteps.count }
    private var isLastStep: Bool { currentStep == totalSteps - 1 }

    var body: some View {
        VStack(spacing: 0) {
            // Fixed progress bar
            progressBar

            // Step content
            List {
                // Scrollable title + subtitle
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(stepTitle)
                            .font(AppFonts.displayMedium)
                        Text(copyText(for: currentField))
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(AppColors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if [.amount, .currency, .date, .type].contains(currentField) {
                            Button {
                                showExamplesSheet = true
                            } label: {
                                Text("Valid examples")
                                    .font(.system(size: 15, weight: .medium))
                            }
                            .padding(.top, AppSpacing.xxs)
                        }
                    }
                    .padding(.vertical, AppSpacing.xs)
                    // Page-tone header — no row pill behind the
                    // description text, so it reads as a blurb on the
                    // cream page rather than a card stuck to a
                    // mismatched system-grouped fill.
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }

                // Field list — `.foregroundColor(.white)` was the
                // remnant of an earlier dark-only design; on the cream
                // light theme it dropped contrast to nearly zero. Use
                // `textSecondary` so the header reads correctly in
                // both modes.
                Section(header: Text("Available Fields").foregroundColor(AppColors.textSecondary)) {
                    // "Not mapped" option
                    if !currentField.isRequired {
                        Button {
                            mapping.removeValue(forKey: currentField)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text("Not mapped")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(AppColors.textPrimary)
                                    Text(currentField.fallbackDescription)
                                        .font(AppFonts.metaRegular)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Spacer()
                                if mapping[currentField] == nil {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .font(AppFonts.iconLarge)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    // Available JSON fields
                    ForEach(availableFields(for: currentField), id: \.self) { jsonField in
                        Button {
                            mapping[currentField] = jsonField
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text(jsonField)
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(AppColors.textPrimary)
                                    if let sample = sampleValues(for: jsonField) {
                                        Text("e.g. \(sample)")
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(AppColors.textSecondary)
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                    }
                                }
                                Spacer()
                                if mapping[currentField] == jsonField {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                        .font(AppFonts.iconLarge)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listRowBackground(AppColors.backgroundElevated)

                // Default currency picker (step 2 only, when no field selected)
                if currentField == .currency && mapping[.currency] == nil {
                    Section(header: Text("Default Currency").foregroundColor(AppColors.textSecondary)) {
                        Picker("Currency for all transactions", selection: $defaultCurrency) {
                            ForEach(currencyStore.currencyOptions, id: \.self) { code in
                                Text("\(CurrencyInfo.byCode[code]?.emoji ?? "💱") \(code)")
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                    .listRowBackground(AppColors.backgroundElevated)
                }

                // Date format hint (step 4 only, when ambiguous dates detected)
                if currentField == .date && needsDateFormatHint {
                    Section(header: Text("Date Format").foregroundColor(AppColors.textSecondary)) {
                        Picker("Which format does your file use?", selection: $dateFormatHint) {
                            ForEach(DateFormatHint.allCases) { hint in
                                Text(hint.rawValue).tag(hint)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    .listRowBackground(AppColors.backgroundElevated)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)

            // Bottom button
            bottomButton
        }
        .background(AppColors.backgroundPrimary)
        .sheet(isPresented: $showExamplesSheet) {
            ValidExamplesSheet(field: currentField)
        }
        .navigationTitle(stepTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    if currentStep > 0 {
                        withAnimation { currentStep -= 1 }
                    } else {
                        presentationMode.wrappedValue.dismiss()
                    }
                } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "chevron.left")
                            .font(AppFonts.bodyEmphasized)
                        if currentStep > 0 {
                            Text(mappingSteps[currentStep - 1].label == "Expense / Income" ? "Expense or income" : mappingSteps[currentStep - 1].label)
                        }
                    }
                }
            }
        }
        .onAppear {
            if !didInitialize {
                defaultCurrency = currencyStore.selectedCurrency
                applyAutoMapping()
                didInitialize = true
            }
        }
    }

    /// Title shown in the nav bar and header for each step
    private var stepTitle: String {
        switch currentField {
        case .type: return "Expense or income"
        default:    return currentField.label
        }
    }

    // MARK: - Progress Bar (fixed at top)

    private var progressBar: some View {
        VStack(spacing: 6) {
            Text("Step \(currentStep + 1) of \(totalSteps)")
                .font(AppFonts.metaText)
                .foregroundColor(AppColors.textSecondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppColors.backgroundChip)
                        .frame(height: 4)
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: geo.size.width * CGFloat(currentStep + 1) / CGFloat(totalSteps), height: 4)
                        .animation(.easeInOut(duration: 0.25), value: currentStep)
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .background(AppColors.backgroundElevated)
    }

    // MARK: - Bottom Button

    private var bottomButton: some View {
        VStack(spacing: 0) {
            Divider()
            if isLastStep {
                // Final step → go to summary
                NavigationLink {
                    ImportSummaryView(
                        source: .manual(
                            records: jsonRecords,
                            mapping: mapping,
                            defaultCurrency: defaultCurrency,
                            dateFormatHint: dateFormatHint
                        ),
                        isFlowActive: $isFlowActive
                    )
                    .environmentObject(transactionStore)
                    .environmentObject(categoryStore)
                    .environmentObject(currencyStore)
                } label: {
                    // `accentBold` for the enabled-state fill — see
                    // the parallel comment on the native-flow CTA
                    // above. The disabled fill stays on
                    // `controlDisabled` (neutral grey) since text
                    // colour shifts to `iconInactive` in that branch.
                    Text("Review Import")
                        .font(AppFonts.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(continueEnabled ? AppColors.accentBold : AppColors.controlDisabled)
                        .foregroundColor(continueEnabled ? .white : AppColors.iconInactive)
                        .cornerRadius(AppRadius.medium)
                }
                .disabled(!continueEnabled)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.rowVertical)
            } else {
                Button {
                    withAnimation { currentStep += 1 }
                } label: {
                    // Same `accentBold` swap as the Review Import
                    // CTA above — the per-step "Next" button shared
                    // the same low-contrast peach surface.
                    Text(buttonLabel)
                        .font(AppFonts.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(continueEnabled ? AppColors.accentBold : AppColors.controlDisabled)
                        .foregroundColor(continueEnabled ? .white : AppColors.iconInactive)
                        .cornerRadius(AppRadius.medium)
                }
                .disabled(!continueEnabled)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.rowVertical)
            }
        }
        .background(AppColors.backgroundElevated)
    }

    private var buttonLabel: String {
        let isMapped = mapping[currentField] != nil
        if currentField.isRequired || currentField == .currency {
            return "Continue"
        }
        return isMapped ? "Continue" : "Skip"
    }

    private var continueEnabled: Bool {
        let field = currentField
        switch field {
        case .amount:
            return mapping[.amount] != nil
        case .currency:
            // Valid if a field is mapped OR a default currency is selected (always true since picker has default)
            return true
        default:
            // Optional fields — always enabled (skip or continue)
            return true
        }
    }

    // MARK: - Copy texts

    private func copyText(for field: AppField) -> String {
        switch field {
        case .amount:
            return "Choose an attribute from your imported file that will be used as the transaction amount. This is a required attribute to correctly import transaction values.\n\nYou will be able to edit it later for each transaction individually."
        case .currency:
            return "Choose an attribute from your imported file that will be used as the transaction currency. This is required to correctly calculate transaction values.\n\nIf your file does not contain a currency field, you can select a default currency that will be applied to all imported transactions. You will be able to change the currency later for each transaction individually."
        case .category:
            return "Choose an attribute from your imported file that will be used as the transaction category. This helps classify each transaction.\n\nIf no field is selected, imported transactions will be assigned to the General category. You will be able to change the category later for each transaction individually."
        case .date:
            return "Choose an attribute from your imported file that will be used as the transaction date. This allows transactions to be correctly placed on the timeline.\n\nIf no field is selected, imported transactions will use today's date. You will be able to change the date later for each transaction individually."
        case .title:
            return "You can choose an attribute from your imported file that will be used as the transaction title.\n\nIf no field is selected, titles will be generated automatically. You will be able to change the title later for each transaction individually."
        case .description:
            return "You can choose an attribute from your imported file that will be used as the transaction description.\n\nYou will also be able to add or edit descriptions later for each transaction."
        case .type:
            return "You can select an attribute that defines the transaction type \u{2014} expense or income.\n\nIf this field is not mapped and the amount values in your file don't contain a sign (+ or \u{2212}), all transactions will be imported as expenses. You will be able to change the type later for each transaction individually."
        case .emoji:
            return "If your imported file contains emoji, you can map this field. Emoji will be used for the categories of imported transactions.\n\nIf emoji are missing or invalid, they will be generated automatically."
        }
    }

    // MARK: - Sample values

    private func sampleValues(for jsonField: String) -> String? {
        // Gather first two non-nil raw values
        var raw: [String] = []
        for record in jsonRecords.prefix(2) {
            if let value = record[jsonField] {
                raw.append(humanReadable(value))
            }
        }

        // Filter out blank / whitespace-only
        let nonBlank = raw.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonBlank.isEmpty else { return nil }

        // Deduplicate
        let unique = Array(NSOrderedSet(array: nonBlank)) as! [String]
        return unique.joined(separator: ", ")
    }

    private func humanReadable(_ value: Any) -> String {
        if let arr = value as? [Any] {
            let items = arr.map { humanReadable($0) }
            return items.joined(separator: ", ")
        }
        if let str = value as? String { return str }
        if let num = value as? Double { return String(num) }
        if let num = value as? Int { return String(num) }
        if let bool = value as? Bool { return bool ? "true" : "false" }
        return "\(value)"
    }

    // MARK: - Available fields (filter out fields whose values are invalid for this app field)

    private func availableFields(for field: AppField) -> [String] {
        return jsonFields.filter { jsonField in
            fieldPassesValidation(jsonField: jsonField, for: field)
        }
    }

    /// Check if > 30% of sample values for a JSON field can be parsed for the given app field.
    /// Fields like title/description/category/tags accept any string, so they always pass.
    private func fieldPassesValidation(jsonField: String, for appField: AppField) -> Bool {
        switch appField {
        case .title, .description, .category, .type:
            return true // any string is acceptable
        case .amount:
            return fieldMatchRate(jsonField: jsonField) { ImportFieldParser.parseAmount($0) != nil } > 0.3
        case .date:
            return fieldMatchRate(jsonField: jsonField) { ImportFieldParser.parseDate($0) != nil } > 0.3
        case .currency:
            return fieldMatchRate(jsonField: jsonField) { ImportFieldParser.parseCurrency($0) != nil } > 0.3
        case .emoji:
            return fieldMatchRate(jsonField: jsonField) { ImportFieldParser.parseEmoji($0) != nil } > 0.3
        }
    }

    private func fieldMatchRate(jsonField: String, test: (Any) -> Bool) -> Double {
        let sampleSize = min(jsonRecords.count, 10)
        guard sampleSize > 0 else { return 0 }
        var matches = 0
        for i in 0..<sampleSize {
            if let value = jsonRecords[i][jsonField], test(value) {
                matches += 1
            }
        }
        return Double(matches) / Double(sampleSize)
    }

    /// Whether the mapped date field has ambiguous DD/MM vs MM/DD values
    private var needsDateFormatHint: Bool {
        guard let dateField = mapping[.date] else { return false }
        return ImportFieldParser.hasAmbiguousDateFormat(records: jsonRecords, field: dateField)
    }

    // MARK: - Auto-mapping

    private func applyAutoMapping() {
        mapping = ImportFieldParser.autoDetectMapping(
            jsonFields: jsonFields,
            records: jsonRecords,
            existingCategories: categoryStore.categories
        )
        // Unmap fields that have no valid JSON fields available
        for (appField, _) in mapping {
            if availableFields(for: appField).isEmpty {
                mapping.removeValue(forKey: appField)
            }
        }
    }
}

// MARK: - Import Mode

enum ImportMode: String, CaseIterable {
    case add = "Add to existing"
    case replace = "Replace all"
}

// MARK: - Import Source

/// What the review screen is summarising. Manual files go through
/// `ImportFieldParser` (one row at a time, with fallback values for
/// unmapped fields). Native non-bank files arrive already-decoded —
/// transactions keep their split/recurrence/`excludedFromInsights`
/// state, and any attached friends and receipt items ride along.
enum ImportSource {
    case manual(records: [[String: Any]], mapping: [AppField: String], defaultCurrency: String, dateFormatHint: DateFormatHint)
    case native(envelope: NonBankExport)
}

// MARK: - Import Summary & Execution (Phase 5)

struct ImportSummaryView: View {
    let source: ImportSource

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    @EnvironmentObject var router: NavigationRouter

    @Binding var isFlowActive: Bool

    @State private var parsedRows: [ParsedImportRow] = []
    @State private var failedCount: Int = 0
    @State private var didParse = false
    @State private var isImporting = false
    @State private var importMode: ImportMode = .add

    // MARK: - Computed

    /// Transaction count for the summary header, regardless of source.
    private var transactionCount: Int {
        switch source {
        case .manual: return parsedRows.count
        case .native(let envelope): return envelope.transactions.count
        }
    }

    /// Categories not yet present locally that the import will create.
    /// For manual rows we walk the parser output; for native files we
    /// walk the decoded transactions directly (each carries its own
    /// `category` + `emoji`, no fallback needed).
    private var newCategoriesWithEmojis: [(name: String, emoji: String)] {
        let existing = Set(categoryStore.categories.map { $0.title.lowercased() })
        var usedEmojis = Set(categoryStore.categories.map { $0.emoji })
        var seen = Set<String>()
        var result: [(name: String, emoji: String)] = []
        let pairs: [(category: String, emoji: String)] = {
            switch source {
            case .manual:
                return parsedRows.map { ($0.category, $0.emoji) }
            case .native(let envelope):
                return envelope.transactions.map { ($0.category, $0.emoji) }
            }
        }()
        for pair in pairs {
            let key = pair.category.lowercased()
            if !existing.contains(key) && !seen.contains(key) {
                seen.insert(key)
                let emoji = uniqueEmoji(preferring: pair.emoji, excluding: usedEmojis)
                usedEmojis.insert(emoji)
                result.append((name: pair.category, emoji: emoji))
            }
        }
        return result
    }

    /// Friends in the import that aren't in the local store yet (will
    /// be inserted) — only relevant for native files.
    private var newFriendsCount: Int {
        guard case .native(let envelope) = source else { return 0 }
        let existing = Set(friendStore.friends.map { $0.id })
        return envelope.friends.filter { !existing.contains($0.id) }.count
    }

    /// Friends in the import that match a local record (will be
    /// upserted if their `lastModified` is newer).
    private var updatedFriendsCount: Int {
        guard case .native(let envelope) = source else { return 0 }
        let existingByID = Dictionary(
            uniqueKeysWithValues: friendStore.friends.map { ($0.id, $0) }
        )
        return envelope.friends.filter { incoming in
            guard let local = existingByID[incoming.id] else { return false }
            return incoming.lastModified > local.lastModified
        }.count
    }

    private var receiptItemsCount: Int {
        if case .native(let envelope) = source {
            return envelope.receiptItems.count
        }
        return 0
    }

    private var warnings: [String] {
        var w: [String] = []
        if failedCount > 0 {
            w.append("\(failedCount) row\(failedCount == 1 ? "" : "s") could not be parsed and will be skipped.")
        }
        return w
    }

    var body: some View {
        List {
            if !didParse {
                Section {
                    HStack {
                        ProgressView()
                            .padding(.trailing, AppSpacing.sm)
                        Text("Parsing transactions…")
                            .foregroundColor(AppColors.textSecondary)
                    }
                    .listRowBackground(AppColors.backgroundElevated)
                }
            } else {
                // Summary
                Section(header: Text("Summary").foregroundColor(AppColors.textSecondary)) {
                    HStack {
                        Text("Transactions to import")
                            .foregroundColor(AppColors.textSecondary)
                        Spacer()
                        Text("\(transactionCount)")
                            .fontWeight(.medium)
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .listRowBackground(AppColors.backgroundElevated)
                    if !newCategoriesWithEmojis.isEmpty {
                        HStack {
                            Text("New categories to create")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(newCategoriesWithEmojis.count)")
                                .fontWeight(.medium)
                                .foregroundColor(AppColors.textPrimary)
                        }
                        .listRowBackground(AppColors.backgroundElevated)
                    }
                    if newFriendsCount > 0 {
                        HStack {
                            Text("New friends")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(newFriendsCount)")
                                .fontWeight(.medium)
                                .foregroundColor(AppColors.textPrimary)
                        }
                        .listRowBackground(AppColors.backgroundElevated)
                    }
                    if updatedFriendsCount > 0 {
                        HStack {
                            Text("Friends to update")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(updatedFriendsCount)")
                                .fontWeight(.medium)
                                .foregroundColor(AppColors.textPrimary)
                        }
                        .listRowBackground(AppColors.backgroundElevated)
                    }
                    if receiptItemsCount > 0 {
                        HStack {
                            Text("Receipt items")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text("\(receiptItemsCount)")
                                .fontWeight(.medium)
                                .foregroundColor(AppColors.textPrimary)
                        }
                        .listRowBackground(AppColors.backgroundElevated)
                    }
                }

                // New categories detail
                if !newCategoriesWithEmojis.isEmpty {
                    Section(header: Text("New Categories").foregroundColor(AppColors.textSecondary)) {
                        ForEach(newCategoriesWithEmojis, id: \.name) { item in
                            HStack(spacing: 10) {
                                Text(item.emoji)
                                    .font(AppFonts.emojiMedium)
                                Text(item.name)
                                    .font(AppFonts.emojiSmall)
                                    .foregroundColor(AppColors.textPrimary)
                            }
                            .listRowBackground(AppColors.backgroundElevated)
                        }
                    }
                }

                // Warnings
                if !warnings.isEmpty {
                    Section(header: Text("Warnings").foregroundColor(AppColors.textSecondary)) {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(AppColors.warning)
                                .font(AppFonts.emojiSmall)
                                .listRowBackground(AppColors.backgroundElevated)
                        }
                    }
                }

                // Import mode
                if transactionCount > 0 {
                    Section(header: Text("Import Mode").foregroundColor(AppColors.textSecondary)) {
                        Picker("Mode", selection: $importMode) {
                            ForEach(ImportMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .listRowBackground(AppColors.backgroundElevated)
                        if importMode == .replace {
                            // Was `AppColors.warning` (system orange) —
                            // poor contrast on cream and on the
                            // accent-tinted segmented control above.
                            // Dark text reads cleanly; the destructive
                            // semantic is already telegraphed by the
                            // selected segment label ("Replace all").
                            Text("All existing transactions will be deleted before import. Local friends are kept.")
                                .font(AppFonts.metaRegular)
                                .foregroundColor(AppColors.textPrimary)
                                .listRowBackground(AppColors.backgroundElevated)
                        }
                    }
                }

                // Import button or empty message
                if transactionCount == 0 {
                    Section {
                        Text("No valid transactions found.")
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(AppColors.textSecondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.xs)
                            .listRowBackground(AppColors.backgroundElevated)
                    }
                } else {
                    Section {
                        Button {
                            executeImport()
                        } label: {
                            HStack {
                                Spacer()
                                if isImporting {
                                    ProgressView()
                                        .padding(.trailing, AppSpacing.sm)
                                    Text("Importing…")
                                        .font(AppFonts.bodyEmphasized)
                                        .foregroundColor(AppColors.accentBold)
                                } else {
                                    Label("Import \(transactionCount) Transactions", systemImage: "square.and.arrow.down")
                                        .font(AppFonts.bodyEmphasized)
                                        .foregroundColor(AppColors.accentBold)
                                }
                                Spacer()
                            }
                        }
                        .disabled(isImporting)
                        .listRowBackground(AppColors.backgroundElevated)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Review Import")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !didParse {
                runParse()
            }
        }
    }

    // MARK: - Parse

    private func runParse() {
        switch source {
        case .manual(let records, let mapping, let defaultCurrency, let dateFormatHint):
            let result = ImportFieldParser.parseAll(
                records: records,
                mapping: mapping,
                defaultCurrency: defaultCurrency,
                dateHint: dateFormatHint,
                existingCategories: categoryStore.categories
            )
            parsedRows = result.rows
            failedCount = result.failedCount
        case .native:
            // No parsing needed — `Transaction.Codable` already gave us
            // typed values when we decoded the envelope.
            parsedRows = []
            failedCount = 0
        }
        didParse = true
    }

    // MARK: - Execute import

    private func executeImport() {
        isImporting = true

        // 1. Create new categories (using pre-computed unique emojis).
        //    These don't race with transaction inserts and are quick
        //    enough to fire synchronously.
        for item in newCategoriesWithEmojis {
            let newCat = Category(emoji: item.emoji, title: item.name)
            categoryStore.addCategory(newCat)
        }

        // 2. Sequence the wipe (replace mode) and the batch insert
        //    inside a single Task so we can `await` each step. The
        //    previous shape fired `transactionStore.deleteAll()` and
        //    `transactionStore.addBatch(...)` as parallel
        //    fire-and-forget Tasks, which raced on the SQLite queue —
        //    a late-finishing delete (slow because it pre-fetches
        //    every transaction's receipt items) could eat the
        //    freshly-inserted rows and the user would land on Home
        //    with 0 transactions despite the review showing "ready
        //    to import: 20". `showImportComplete` only fires after
        //    every row is persisted so the success screen reflects
        //    the actual DB state.
        Task {
            if importMode == .replace {
                await transactionStore.deleteAllAndWait()
            }
            switch source {
            case .manual:
                await executeManualImport()
                await MainActor.run {
                    isImporting = false
                    router.showImportComplete(count: parsedRows.count)
                }
            case .native(let envelope):
                await executeNativeImport(envelope: envelope)
                // executeNativeImport handles its own isImporting /
                // showImportComplete on the MainActor at the end.
            }
        }
    }

    private func executeManualImport() async {
        // Manual flow imports only the fields the user explicitly
        // mapped in the wizard. Split / recurrence / parent-reminder
        // links are deliberately omitted — those ride the native
        // envelope path only.
        let transactions = parsedRows.map { row in
            Transaction(
                id: 0,
                emoji: row.emoji,
                category: row.category,
                title: row.title,
                description: row.description,
                amount: row.amount,
                currency: row.currency,
                date: row.date,
                type: row.type,
                tags: nil
            )
        }
        // We use `addBatchAndReturnSyncIDMap` (and discard the map)
        // rather than the fire-and-forget `addBatch` so the import
        // pipeline can await persistence. The single-tx `addBatch`
        // wrapper still exists for non-import callers that don't
        // care to wait.
        _ = await transactionStore.addBatchAndReturnSyncIDMap(transactions)
    }

    private func executeNativeImport(envelope: NonBankExport) async {
        // Upsert friends. New ones are inserted; existing ones are
        // updated only when the incoming `lastModified` is newer (so a
        // freshly-renamed contact on this device doesn't get
        // overwritten by a stale export from another device).
        let existingByID = Dictionary(
            uniqueKeysWithValues: friendStore.friends.map { ($0.id, $0) }
        )
        for friend in envelope.friends {
            if let local = existingByID[friend.id] {
                if friend.lastModified > local.lastModified {
                    friendStore.update(friend)
                }
            } else {
                await friendStore.add(friend)
            }
        }

        // Re-stamp every transaction with a fresh local `id` (the
        // exported value is the source device's autoincrement — useless
        // here) but keep its `syncID` so we can wire receipt items up
        // after the insert.
        let toInsert = envelope.transactions.map { tx in
            Transaction(
                id: 0,
                syncID: tx.syncID,
                emoji: tx.emoji,
                category: tx.category,
                title: tx.title,
                description: tx.description,
                amount: tx.amount,
                currency: tx.currency,
                date: tx.date,
                type: tx.type,
                tags: tx.tags,
                lastModified: tx.lastModified,
                repeatInterval: tx.repeatInterval,
                parentReminderID: tx.parentReminderID,
                splitInfo: tx.splitInfo,
                payloadChecksum: tx.payloadChecksum,
                excludedFromInsights: tx.excludedFromInsights
            )
        }
        let syncIDToNewID = await transactionStore.addBatchAndReturnSyncIDMap(toInsert)

        // Group receipt items by their parent transaction's syncID,
        // then save each group with the new local transaction id.
        let itemsByTxSyncID = Dictionary(grouping: envelope.receiptItems) {
            $0.transactionSyncID
        }
        for (txSyncID, exportedItems) in itemsByTxSyncID {
            guard let newTxID = syncIDToNewID[txSyncID] else { continue }
            let items = exportedItems
                .sorted { $0.position < $1.position }
                .map { $0.toReceiptItem() }
            await receiptItemStore.saveItems(items, for: newTxID)
        }

        await MainActor.run {
            isImporting = false
            router.showImportComplete(count: envelope.transactions.count)
        }
    }

    /// Returns a unique emoji: uses `preferred` if it's not taken, otherwise picks from a large curated pool.
    private func uniqueEmoji(preferring preferred: String, excluding used: Set<String>) -> String {
        if !used.contains(preferred) {
            return preferred
        }
        let pool = Self.curatedEmojiPool.shuffled()
        return pool.first(where: { !used.contains($0) }) ?? "📦"
    }

    /// Large curated pool of emoji guaranteed to render correctly on iOS.
    private static let curatedEmojiPool: [String] = [
        // Food & drink
        "🍅","🍆","🥑","🥦","🥒","🌶","🌽","🧀","🍎","🍏","🍐","🍑","🍒","🍓","🍇",
        "🍈","🍉","🍊","🍋","🍌","🍍","🥝","🥭","🍕","🍔","🌭","🌮","🌯","🥚","🍳",
        "🥘","🍲","🍜","🍣","🍤","🍥","🍱","🍛","🍚","🍙","🍘","🍢","🍡","🍠","🍪",
        "🎂","🍰","🍩","🍫","🍬","🍭","🍮","🍯","🍿","🧁","☕","🍵","🧃","🍼","🥤",
        // Animals
        "🐶","🐱","🐭","🐹","🐰","🦊","🐻","🐼","🐨","🐯","🦁","🐮","🐷","🐸","🐵",
        "🐔","🐧","🐦","🐤","🐣","🦆","🦅","🦉","🦇","🐺","🐗","🐴","🦄","🐝","🐛",
        "🦋","🐌","🐚","🐞","🐜","🦗","🦂","🐢","🐍","🦎","🐙","🦑","🦐","🦀","🐡",
        "🐠","🐟","🐬","🐳","🦈","🐊","🐅","🐆","🦓","🦍","🐘","🦛","🐪","🦒","🦘",
        "🦚","🦩","🦜","🐿","🦔","🐾","🐉","🦕","🦖",
        // Nature & plants
        "🌺","🌻","🌼","🌷","🌹","🌾","🌿","☘","🍀","🍁","🍂","🍃","🍄","🌵","🌴",
        "🌳","🌲","🌱","💐","🪴","🪻","🪷","🌸",
        // Objects & tools
        "📱","💻","📺","📷","📰","📚","📖","🔍","🔬","🔭","💡","🔦","🔧","🔨","🔮",
        "💎","🔑","📎","✏️","📐","💼","💰","💳","📦","📨","📫","📩","📅","📋","📌",
        "💿","💾","🎨","🧳","🛍","🧪","🪙","🧲","🗂",
        // Activities & entertainment
        "🎮","🎲","🎯","🎳","🎸","🎺","🎻","🎵","🎤","🎬","🎭","🎪","🎫","🏆","🏀",
        "⚽","🏈","⚾","🎾","🏐","🏓","🏸","🥊","🥋","⛳","⛸","🎿","🛷","🎣","🎽",
        "🧩","🎁","🎀","🎈","🎉","🎊","🎃","🎄","🎋","🎍","🎎","🎏","🎐",
        // Travel & transport
        "🚗","🚕","🚌","🚎","🚂","🚀","✈️","🚢","⛵","🚲","🛵","🛶","🚁","🚄","🚤",
        "🏠","🏢","🏥","🏨","🏪","🏫","🏭","🏰","🏔","🏖","🏕","🎠","🎡","🎢","⛺",
        "🗼","🗽","🗿","🗾","🌋","🌍","🌎","🌏","🌉",
        // Weather & sky
        "☀️","🌙","⭐","🌟","🌈","☁️","⚡","❄️","🌊","💧","🔥","💫","☄️","🫧","🌌",
        // Symbols & misc
        "❤️","💜","💙","💚","💛","🧡","💖","♻️","🏷","💌","🧿","🪐","🧬","🫀","🪬"
    ]
}

// MARK: - Valid Examples Sheet

struct ValidExamplesSheet: View {
    let field: AppField
    @Environment(\.dismiss) private var dismiss
    @State private var typeTab = 0

    var body: some View {
        NavigationView {
            Group {
                if field == .type {
                    VStack(spacing: 0) {
                        Picker("", selection: $typeTab) {
                            Text("Expense values").tag(0)
                            Text("Income values").tag(1)
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.vertical, 10)

                        List {
                            Section {
                                ForEach(typeTab == 0 ? expenseValues : incomeValues, id: \.self) { value in
                                    Text(value)
                                        .font(.system(size: 15, design: .monospaced))
                                }
                            }
                            .listRowBackground(AppColors.backgroundElevated)
                        }
                        .listStyle(.insetGrouped)
                        .scrollContentBackground(.hidden)
                    }
                } else {
                    List {
                        Section(header: Text("Supported Formats").foregroundColor(AppColors.textSecondary)) {
                            ForEach(examples(for: field), id: \.self) { example in
                                Text(example)
                                    .font(.system(size: 15, design: .monospaced))
                            }
                        }
                        .listRowBackground(AppColors.backgroundElevated)
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Valid Examples")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private let expenseValues = [
        "expense", "expenses", "out", "payout", "pay out",
        "outbound", "minus", "debit", "withdrawal", "spend",
        "spending", "spendings", "charge", "outgoing",
        "expenditure", "cost", "disbursement", "deduction", "outflow"
    ]

    private let incomeValues = [
        "income", "incomes", "in", "payin", "pay in",
        "funding", "inbound", "plus", "credit", "deposit",
        "receive", "incoming", "topup", "top_up",
        "top up", "top-up", "inflow", "load", "ingoing"
    ]

    private func examples(for field: AppField) -> [String] {
        switch field {
        case .amount:
            return [
                "100",
                "1000.50",
                "1 000,50",
                "1,000.50",
                "1000,00",
                "-250.00",
                "+1500",
                "1 000"
            ]
        case .currency:
            return [
                "USD",
                "usd"
            ]
        case .category:
            return [
                "Food",
                "Transport",
                "Shopping",
                "Any text value"
            ]
        case .date:
            return [
                "2026-04-07",
                "2026-04-07T14:30:00",
                "2026-04-07 14:30:00",
                "07.04.2026",
                "07/04/2026",
                "04/07/2026",
                "April 7, 2026",
                "7 Apr 2026",
                "1712505600 (unix)"
            ]
        case .title:
            return [
                "Grocery Store",
                "Monthly Salary",
                "Any text value"
            ]
        case .description:
            return [
                "Weekly grocery shopping",
                "Payment for services",
                "Any text value"
            ]
        case .type:
            return []
        case .emoji:
            return [
                "🛒",
                "🍔",
                "🏠",
                "Single emoji character"
            ]
        }
    }
}

// MARK: - Import Success Screen (fullScreenCover)

struct ImportSuccessScreen: View {
    let count: Int
    let onDone: () -> Void

    var body: some View {
        ZStack {
            AppColors.backgroundPrimary
                .ignoresSafeArea()

            VStack(spacing: AppSpacing.lg) {
                Spacer()
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundColor(.green)
                Text("Import Complete")
                    .font(AppFonts.heading)
                Text("\(count) transactions imported successfully.")
                    .font(AppFonts.bodyRegular)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button {
                    onDone()
                } label: {
                    // Same `accentBold` swap as the wizard CTAs —
                    // the success-screen Done button shares the same
                    // white-on-warm fill pattern.
                    Text("Done")
                        .font(AppFonts.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(AppColors.accentBold)
                        .foregroundColor(.white)
                        .cornerRadius(AppRadius.medium)
                }
                .padding(.horizontal, AppSpacing.xxl)
                .padding(.bottom, AppSpacing.xxxl)
            }
        }
        .interactiveDismissDisabled()
    }
}

import SwiftUI
import UniformTypeIdentifiers

// MARK: - Import State

enum ImportState: Equatable {
    case idle
    case loading
    case parsed(fields: [String], records: [[String: Any]], preview: String)
    case error(String)

    static func == (lhs: ImportState, rhs: ImportState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading): return true
        case (.error(let a), .error(let b)): return a == b
        case (.parsed(let f1, let r1, _), .parsed(let f2, let r2, _)):
            return f1 == f2 && r1.count == r2.count
        default: return false
        }
    }
}

// MARK: - Import Transactions Screen (Phase 1)

struct ImportTransactionsView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
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
                    Button {
                        showFilePicker = true
                    } label: {
                        Label("Import JSON File", systemImage: "doc.badge.plus")
                    }
                } footer: {
                    Text("Select a JSON file containing an array of transactions.")
                        .font(AppFonts.metaRegular)
                        .foregroundColor(.secondary)
                }

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
                                .foregroundColor(.secondary)
                        }
                    }

                case .parsed(let fields, let records, _):
                    Section(header: Text("File Info")) {
                        if !fileName.isEmpty {
                            HStack {
                                Text("File")
                                    .foregroundColor(.secondary)
                                Spacer()
                                Text(fileName)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        HStack {
                            Text("Transactions detected")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(records.count)")
                                .fontWeight(.medium)
                        }
                        HStack {
                            Text("Fields found")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(fields.count)")
                                .fontWeight(.medium)
                        }
                    }

                    Section(header: Text("Detected Fields")) {
                        ForEach(fields, id: \.self) { field in
                            Text(field)
                                .font(.system(size: 15, design: .monospaced))
                        }
                    }

                case .error(let message):
                    Section {
                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Label("Import Error", systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(AppFonts.body)
                            Text(message)
                                .font(AppFonts.emojiSmall)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, AppSpacing.xs)
                    }
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
                        Text("Continue to Field Mapping")
                            .font(AppFonts.bodyEmphasized)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(12)
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.vertical, AppSpacing.rowVertical)
                }
                .background(AppColors.backgroundElevated)
            }
        }
        .navigationTitle("Import Transactions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { router.hideTabBar = true }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [UTType.json],
            allowsMultipleSelection: false
        ) { result in
            handleFileSelection(result)
        }
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
            parseJSON(at: url)

        case .failure(let error):
            importState = .error(error.localizedDescription)
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
                            .foregroundColor(.secondary)
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
                    .listRowBackground(AppColors.backgroundElevated)
                    .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                }

                // Field list
                Section(header: Text("Available Fields").foregroundColor(.white)) {
                    // "Not mapped" option
                    if !currentField.isRequired {
                        Button {
                            mapping.removeValue(forKey: currentField)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text("Not mapped")
                                        .font(.system(size: 16, weight: .medium))
                                        .foregroundColor(.primary)
                                    Text(currentField.fallbackDescription)
                                        .font(AppFonts.metaRegular)
                                        .foregroundColor(.secondary)
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
                                        .foregroundColor(.primary)
                                    if let sample = sampleValues(for: jsonField) {
                                        Text("e.g. \(sample)")
                                            .font(.system(size: 13, design: .monospaced))
                                            .foregroundColor(.secondary)
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

                // Default currency picker (step 2 only, when no field selected)
                if currentField == .currency && mapping[.currency] == nil {
                    Section(header: Text("Default Currency")) {
                        Picker("Currency for all transactions", selection: $defaultCurrency) {
                            ForEach(currencyStore.currencyOptions, id: \.self) { code in
                                Text("\(CurrencyInfo.byCode[code]?.emoji ?? "💱") \(code)")
                                    .tag(code)
                            }
                        }
                        .pickerStyle(.menu)
                    }
                }

                // Date format hint (step 4 only, when ambiguous dates detected)
                if currentField == .date && needsDateFormatHint {
                    Section(header: Text("Date Format")) {
                        Picker("Which format does your file use?", selection: $dateFormatHint) {
                            ForEach(DateFormatHint.allCases) { hint in
                                Text(hint.rawValue).tag(hint)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .listStyle(.insetGrouped)

            // Bottom button
            bottomButton
        }
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
                .foregroundColor(.secondary)
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
                        jsonRecords: jsonRecords,
                        mapping: mapping,
                        defaultCurrency: defaultCurrency,
                        dateFormatHint: dateFormatHint,
                        isFlowActive: $isFlowActive
                    )
                    .environmentObject(transactionStore)
                    .environmentObject(categoryStore)
                    .environmentObject(currencyStore)
                } label: {
                    Text("Review Import")
                        .font(AppFonts.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(continueEnabled ? Color.accentColor : Color(.systemGray4))
                        .foregroundColor(continueEnabled ? .white : .secondary)
                        .cornerRadius(12)
                }
                .disabled(!continueEnabled)
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.rowVertical)
            } else {
                Button {
                    withAnimation { currentStep += 1 }
                } label: {
                    Text(buttonLabel)
                        .font(AppFonts.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(continueEnabled ? Color.accentColor : Color(.systemGray4))
                        .foregroundColor(continueEnabled ? .white : .secondary)
                        .cornerRadius(12)
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

// MARK: - Import Summary & Execution (Phase 5)

struct ImportSummaryView: View {
    let jsonRecords: [[String: Any]]
    let mapping: [AppField: String]
    let defaultCurrency: String
    let dateFormatHint: DateFormatHint

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var router: NavigationRouter

    @Binding var isFlowActive: Bool

    @State private var parsedRows: [ParsedImportRow] = []
    @State private var failedCount: Int = 0
    @State private var didParse = false
    @State private var isImporting = false
    @State private var importMode: ImportMode = .add

    // MARK: - Computed

    private var newCategoriesWithEmojis: [(name: String, emoji: String)] {
        let existing = Set(categoryStore.categories.map { $0.title.lowercased() })
        var usedEmojis = Set(categoryStore.categories.map { $0.emoji })
        var seen = Set<String>()
        var result: [(name: String, emoji: String)] = []
        for row in parsedRows {
            let key = row.category.lowercased()
            if !existing.contains(key) && !seen.contains(key) {
                seen.insert(key)
                // Always assign a guaranteed-unique emoji
                let emoji = uniqueEmoji(preferring: row.emoji, excluding: usedEmojis)
                usedEmojis.insert(emoji)
                result.append((name: row.category, emoji: emoji))
            }
        }
        return result
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
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                // Summary
                Section(header: Text("Summary")) {
                    HStack {
                        Text("Transactions to import")
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("\(parsedRows.count)")
                            .fontWeight(.medium)
                    }
                    if !newCategoriesWithEmojis.isEmpty {
                        HStack {
                            Text("New categories to create")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text("\(newCategoriesWithEmojis.count)")
                                .fontWeight(.medium)
                        }
                    }
                }

                // New categories detail
                if !newCategoriesWithEmojis.isEmpty {
                    Section(header: Text("New Categories")) {
                        ForEach(newCategoriesWithEmojis, id: \.name) { item in
                            HStack(spacing: 10) {
                                Text(item.emoji)
                                    .font(AppFonts.emojiMedium)
                                Text(item.name)
                                    .font(AppFonts.emojiSmall)
                            }
                        }
                    }
                }

                // Warnings
                if !warnings.isEmpty {
                    Section(header: Text("Warnings")) {
                        ForEach(warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(AppFonts.emojiSmall)
                        }
                    }
                }

                // Import mode
                if !parsedRows.isEmpty {
                    Section(header: Text("Import Mode")) {
                        Picker("Mode", selection: $importMode) {
                            ForEach(ImportMode.allCases, id: \.self) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        if importMode == .replace {
                            Text("All existing transactions will be deleted before import.")
                                .font(AppFonts.metaRegular)
                                .foregroundColor(.orange)
                        }
                    }
                }

                // Import button or empty message
                if parsedRows.isEmpty {
                    Section {
                        Text("No valid transactions found.")
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, AppSpacing.xs)
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
                                } else {
                                    Label("Import \(parsedRows.count) Transactions", systemImage: "square.and.arrow.down")
                                        .font(AppFonts.bodyEmphasized)
                                }
                                Spacer()
                            }
                        }
                        .disabled(isImporting)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
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
        let result = ImportFieldParser.parseAll(
            records: jsonRecords,
            mapping: mapping,
            defaultCurrency: defaultCurrency,
            dateHint: dateFormatHint,
            existingCategories: categoryStore.categories
        )
        parsedRows = result.rows
        failedCount = result.failedCount
        didParse = true
    }

    // MARK: - Execute import

    private func executeImport() {
        isImporting = true

        // 0. Replace all existing transactions if overwrite mode
        if importMode == .replace {
            transactionStore.deleteAll()
        }

        // 1. Create new categories (using pre-computed unique emojis)
        for item in newCategoriesWithEmojis {
            let newCat = Category(emoji: item.emoji, title: item.name)
            categoryStore.addCategory(newCat)
        }

        // 2. Batch-add all transactions (single DB write + single reload)
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
                tags: nil,
                repeatInterval: row.repeatInterval,
                parentReminderID: row.parentReminderID,
                splitInfo: row.splitInfo
            )
        }
        transactionStore.addBatch(transactions)

        isImporting = false
        router.showImportComplete(count: parsedRows.count)
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
                        }
                        .listStyle(.insetGrouped)
                    }
                } else {
                    List {
                        Section(header: Text("Supported Formats")) {
                            ForEach(examples(for: field), id: \.self) { example in
                                Text(example)
                                    .font(.system(size: 15, design: .monospaced))
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
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
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                Spacer()
                Button {
                    onDone()
                } label: {
                    Text("Done")
                        .font(AppFonts.bodyEmphasized)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(12)
                }
                .padding(.horizontal, AppSpacing.xxl)
                .padding(.bottom, AppSpacing.xxxl)
            }
        }
        .interactiveDismissDisabled()
    }
}

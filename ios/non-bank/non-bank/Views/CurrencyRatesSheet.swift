import SwiftUI

// MARK: - Currency Rates Screen

struct CurrencyRatesSheet: View {
    @EnvironmentObject var currencyStore: CurrencyStore
    @Binding var isPresented: Bool
    @State private var searchText: String = ""

    private var sortedCurrencies: [String] {
        currencyStore.currencyOptions
    }

    private var filteredCurrencies: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return sortedCurrencies }
        return sortedCurrencies.filter { code in
            code.lowercased().contains(query) ||
            (CurrencyInfo.byCode[code]?.name.lowercased().contains(query) ?? false)
        }
    }

    private func rateSubtitle(for code: String) -> String {
        let base = currencyStore.selectedCurrency
        if code == base { return "Base currency" }
        guard let baseRate = currencyStore.usdRates[base], baseRate > 0,
              let codeRate = currencyStore.usdRates[code], codeRate > 0 else { return "-" }
        // cross = how many units of code per 1 unit of base
        let cross = codeRate / baseRate
        if cross >= 1 {
            // 1 Base ≈ X Target (readable: value ≥ 1)
            return String(format: "1 %@ ≈ %.2f %@", base, cross, code)
        } else {
            // Invert: 1 Target ≈ X Base (so value ≥ 1)
            let inverted = baseRate / codeRate
            return String(format: "1 %@ ≈ %.2f %@", code, inverted, base)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(header: Text("Rates")) {
                    ForEach(filteredCurrencies, id: \.self) { code in
                        HStack(spacing: 14) {
                            Text(CurrencyInfo.byCode[code]?.emoji ?? "💱")
                                .font(AppFonts.emojiLarge)
                                .frame(width: 38)
                            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                HStack(spacing: 6) {
                                    Text(code)
                                        .font(AppFonts.bodyEmphasized)
                                    if let name = CurrencyInfo.byCode[code]?.name {
                                        Text(name)
                                            .font(AppFonts.emojiSmall)
                                            .foregroundColor(.secondary)
                                    }
                                }
                                Text(rateSubtitle(for: code))
                                    .font(AppFonts.metaRegular)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, AppSpacing.xxs)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search currencies")
            .navigationTitle("Currencies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

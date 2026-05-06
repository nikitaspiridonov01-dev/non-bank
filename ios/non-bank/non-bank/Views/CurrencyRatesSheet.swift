import SwiftUI

// MARK: - Currency Rates Screen

struct CurrencyRatesSheet: View {
    @EnvironmentObject var currencyStore: CurrencyStore
    @Binding var isPresented: Bool
    @State private var searchText: String = ""

    /// Optional override for what tapping a row does. When `nil`
    /// (default), tapping sets the global base currency — this is
    /// the canonical behavior used from Settings and the
    /// "More currencies" entry in base-currency dropdowns.
    /// When provided, tapping invokes the callback and dismisses
    /// the sheet — used by `CurrencyDropdownButton` callers that
    /// want to capture a one-shot selection (e.g. picking a
    /// transaction's currency from the create flow without
    /// touching the global base).
    var onSelect: ((String) -> Void)? = nil

    /// Snapshot of `currencyStore.currencyOptions` taken once when the
    /// sheet appears. Used as the row order for the entire visit so
    /// switching the base currency mid-session doesn't pop the newly
    /// selected row to the top under the user's finger. Re-opening the
    /// sheet refreshes the snapshot, so the new base lands at the top
    /// next time.
    @State private var stableOrder: [String] = []

    private var filteredCurrencies: [String] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return stableOrder }
        return stableOrder.filter { code in
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
                Section {
                    ForEach(filteredCurrencies, id: \.self) { code in
                        Button {
                            if let onSelect = onSelect {
                                // Caller-driven mode (e.g. picking a
                                // transaction's currency from the create
                                // flow). Dismiss after invoking so the
                                // user lands back on their original
                                // surface with the choice committed.
                                onSelect(code)
                                isPresented = false
                            } else if code != currencyStore.selectedCurrency {
                                // Default: tap = set base. `selectedCurrency`
                                // is `@Published` so every dependent view
                                // (Home header, Debts header, conversion
                                // math) updates from one source of truth.
                                currencyStore.selectedCurrency = code
                            }
                        } label: {
                            currencyRow(code)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .listStyle(.insetGrouped)
            // Three modifiers gang up to close the band between the
            // searchable drawer and the first section: the implicit
            // header's min height (`defaultMinListHeaderHeight`), the
            // section spacing (`listSectionSpacing`), and the scroll
            // view's top content inset (`contentMargins`). Removing
            // any one alone leaves a residual gap.
            .environment(\.defaultMinListHeaderHeight, 0)
            .listSectionSpacing(0)
            .contentMargins(.top, 0, for: .scrollContent)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search currencies")
            .navigationTitle("Currencies")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .onAppear {
                // Freeze the order on first render. Guarded so an
                // accidental second `onAppear` (e.g. NavigationStack
                // pushes/pops) doesn't reshuffle mid-session.
                if stableOrder.isEmpty {
                    stableOrder = currencyStore.currencyOptions
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private func currencyRow(_ code: String) -> some View {
        let isBase = code == currencyStore.selectedCurrency
        HStack(spacing: 14) {
            Text(CurrencyInfo.byCode[code]?.emoji ?? "💱")
                .font(AppFonts.emojiLarge)
                .frame(width: 38)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                HStack(spacing: 6) {
                    Text(code)
                        .font(AppFonts.bodyEmphasized)
                        .foregroundColor(AppColors.textPrimary)
                    if let name = CurrencyInfo.byCode[code]?.name {
                        Text(name)
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                Text(rateSubtitle(for: code))
                    .font(AppFonts.metaRegular)
                    .foregroundColor(AppColors.textTertiary)
            }
            Spacer(minLength: AppSpacing.sm)
            if isBase {
                Image(systemName: "checkmark")
                    .font(AppFonts.bodySmallEmphasized)
                    .foregroundColor(.accentColor)
            }
        }
        .padding(.vertical, AppSpacing.xxs)
        .contentShape(Rectangle())
    }
}

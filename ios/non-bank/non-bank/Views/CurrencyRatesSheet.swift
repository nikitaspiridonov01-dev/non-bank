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
            // Plain `List` (instead of ScrollView + custom layout) so
            // SwiftUI's row-diffing keeps scroll position stable when
            // the user types into the search field. Solid
            // `backgroundElevated` fill (matches `FriendPickerView`) —
            // earlier per-row `.glassEffect` pills produced inconsistent
            // rendering in dark mode where some rows visually merged
            // into a brighter slab while their neighbours did not.
            List {
                if filteredCurrencies.isEmpty {
                    noResultsInline
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets())
                } else {
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
                        // Fill on the content — `listRowBackground`
                        // would render edge-to-edge regardless of
                        // `listRowInsets`, so the pill bled to the
                        // screen edges and adjacent rows merged.
                        .background(AppColors.backgroundElevated, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .listRowInsets(EdgeInsets(
                            top: AppSpacing.xs,
                            leading: AppSpacing.pageHorizontal,
                            bottom: AppSpacing.xs,
                            trailing: AppSpacing.pageHorizontal
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            // No `placement:` argument — on iOS 26 the default places
            // the search field at the bottom integrated with the
            // toolbar glass. Matches `CategoriesSheetView`.
            .searchable(text: $searchText, prompt: "Search currencies")
            .navigationTitle("Currencies")
            // Large title to match `CategoriesSheetView` — both
            // pickers share the same hero header pattern now (Close
            // pill on the left, large title below, action pill on the
            // right). Inline mode left the page feeling shallower than
            // its sibling sheets.
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    // Icon-only `xmark` matches the dismiss pattern
                    // of the other sheets in the app (DebtSummaryView,
                    // FriendCardView via NavigationStack). A bare
                    // "Close" word in a translucent capsule wasn't
                    // reading as an action — the glyph is clearer
                    // and shorter.
                    Button {
                        isPresented = false
                    } label: {
                        Image(systemName: "xmark")
                            .font(AppFonts.bodySmallEmphasized)
                            .foregroundColor(AppColors.textPrimary)
                    }
                    .accessibilityLabel("Close")
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

    private var noResultsInline: some View {
        VStack(spacing: AppSpacing.md) {
            SearchIllustration(tint: .neutral, size: .standard)
            Text("No results")
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
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
                        // `lineLimit(1)` keeps long names (e.g. "Bosnia
                        // and Herzegovina Convertible Mark") from
                        // wrapping to a second line and ballooning the
                        // row height — paired with `minHeight` below to
                        // lock the entire list to a uniform row size.
                        Text(name)
                            .font(AppFonts.emojiSmall)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
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
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.vertical, AppSpacing.md)
        // Floor matches the natural height of the two-line content
        // (code + name on top, rate subtitle below) so every row
        // renders the same height regardless of name length.
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .contentShape(Rectangle())
    }
}

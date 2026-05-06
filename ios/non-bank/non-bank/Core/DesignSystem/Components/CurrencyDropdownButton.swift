import SwiftUI

/// Tappable currency control that decides — based on the user's
/// transaction history — whether to show a small inline dropdown
/// (base + currencies actually used + "More currencies") or jump
/// straight to the full `CurrencyRatesSheet`. Replaces the
/// `Menu { ForEach(currencyStore.currencyOptions) ... }` pattern that
/// was duplicated across `BalanceHeaderView`, `DebtSummaryView`, and
/// `CreateTransactionModal` — those exposed all 160+ catalog
/// currencies in every dropdown, burying the few the user actually
/// transacts in.
///
/// Behaviour matrix:
/// - **No transactions at all (incl. reminders)** — tap goes
///   directly to `CurrencyRatesSheet`. Nothing meaningful to
///   dropdown over.
/// - **Only one currency in transactions, equal to base** — same:
///   straight to the sheet. The current selection is the only
///   plausible option.
/// - **Otherwise** — small dropdown with: base on top, then used
///   currencies (deduped against base, sorted by frequency →
///   recency → alphabetic, the same rule as
///   `CurrencyStore.currencyOptions`), terminated by a
///   "More currencies" entry that pushes to `CurrencyRatesSheet`.
///
/// `onSelect` decides what tapping a currency in the dropdown OR
/// in the More-currencies sheet does. `BalanceHeaderView` /
/// `DebtSummaryView` pass closures that set the global base;
/// `CreateTransactionModal` passes one that sets the transaction
/// draft's currency. Same component, different commits.
struct CurrencyDropdownButton<LabelContent: View>: View {
    /// Currency code currently shown in the parent UI (e.g. the
    /// base currency for header pickers, the draft transaction's
    /// currency in the create flow). The dropdown highlights this
    /// row with a checkmark.
    let selected: String

    /// Invoked with a chosen currency code from either the inline
    /// dropdown rows or the More-currencies sheet. Caller is
    /// responsible for the side-effect — base swap, transaction
    /// currency assignment, etc.
    let onSelect: (String) -> Void

    /// Visual label inside the button. Caller controls the
    /// typography and color so the same component blends into
    /// balance digits, debt headers, and create-flow chips.
    @ViewBuilder let label: () -> LabelContent

    @EnvironmentObject private var currencyStore: CurrencyStore
    @EnvironmentObject private var transactionStore: TransactionStore
    @State private var showRatesSheet = false

    init(
        selected: String,
        onSelect: @escaping (String) -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.selected = selected
        self.onSelect = onSelect
        self.label = label
    }

    /// Currency codes used across `transactionStore.transactions`
    /// (past + reminders), sorted frequency → recency → alphabetic.
    /// We deliberately read from `transactionStore` rather than
    /// `currencyStore.currencyOptions`: that latter computed property
    /// is fed only `homeTransactions` (past), so reminder-only
    /// currencies wouldn't surface here otherwise.
    private var sortedUsedCurrencies: [String] {
        let txs = transactionStore.transactions
        var freq: [String: Int] = [:]
        var lastDate: [String: Date] = [:]
        for tx in txs {
            freq[tx.currency, default: 0] += 1
            if let prev = lastDate[tx.currency] {
                if tx.date > prev { lastDate[tx.currency] = tx.date }
            } else {
                lastDate[tx.currency] = tx.date
            }
        }
        return Array(freq.keys).sorted { a, b in
            let fa = freq[a, default: 0], fb = freq[b, default: 0]
            if fa != fb { return fa > fb }
            let da = lastDate[a] ?? .distantPast, db = lastDate[b] ?? .distantPast
            if da != db { return da > db }
            return a < b
        }
    }

    /// Items to show in the inline dropdown: `[base, ...used\base]`.
    /// Empty when there are no transactions, or when the only used
    /// currency is the base (a one-element list isn't a meaningful
    /// dropdown — the button collapses to a direct sheet open).
    private var dropdownItems: [String] {
        let base = currencyStore.selectedCurrency
        let extras = sortedUsedCurrencies.filter { $0 != base }
        return extras.isEmpty ? [] : ([base] + extras)
    }

    var body: some View {
        Group {
            if dropdownItems.isEmpty {
                Button {
                    showRatesSheet = true
                } label: {
                    label()
                }
                .buttonStyle(.plain)
            } else {
                Menu {
                    ForEach(dropdownItems, id: \.self) { code in
                        Button {
                            onSelect(code)
                        } label: {
                            // Native iOS menu draws a checkmark for
                            // the matching row when a `Picker`-like
                            // shape is used; for `Button` rows, the
                            // checkmark glyph is rendered explicitly
                            // for the active currency.
                            if code == selected {
                                Label("\(code) \(CurrencyInfo.byCode[code]?.emoji ?? "💱")", systemImage: "checkmark")
                            } else {
                                Text("\(code) \(CurrencyInfo.byCode[code]?.emoji ?? "💱")")
                            }
                        }
                    }
                    Divider()
                    Button {
                        showRatesSheet = true
                    } label: {
                        Label("More currencies", systemImage: "ellipsis.circle")
                    }
                } label: {
                    label()
                }
            }
        }
        .sheet(isPresented: $showRatesSheet) {
            // Forward `onSelect` so the More-currencies path commits
            // to the same destination as the inline rows. Without
            // this, opening More from the create flow would reset
            // the global base instead of picking the transaction's
            // currency.
            CurrencyRatesSheet(isPresented: $showRatesSheet, onSelect: onSelect)
                .environmentObject(currencyStore)
        }
    }
}

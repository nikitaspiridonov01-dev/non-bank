import SwiftUI

/// Review screen shown after `HybridReceiptParser` returns structured items.
/// Items are read-only here — to remove or tweak a line the user opens the
/// `ReceiptItemEditorSheet` via the inline "Edit items" button.
struct ReceiptReviewView: View {
    let parseResult: HybridReceiptParser.Result
    let sourceImage: UIImage?
    /// Final-confirm callback. The currency is passed through here (not
    /// inferred from `parseResult` at the call site) so a user-correction
    /// inside the editor — typical when OCR/AI guessed the wrong code or
    /// emitted nothing — actually reaches the transaction draft.
    var onConfirm: (_ items: [ReceiptItem], _ total: Double, _ currency: String) -> Void
    var onCancel: () -> Void
    /// When true (default), wraps the body in its own `NavigationStack`
    /// and dismisses the surrounding sheet on Cancel/Save. Use `false`
    /// to render the content as a push step inside an existing
    /// NavigationStack (e.g. the byItems flow inside
    /// `TransactionModeFlowSheet`) — Cancel/Save then defer all
    /// navigation routing to the parent's callbacks.
    var wrapInNavigationStack: Bool = true

    @Environment(\.dismiss) private var dismiss
    /// Forwarded into the editor sheet so its `CurrencyDropdownButton`
    /// (which reads these from its own environment) keeps working —
    /// `.sheet(item:)` inherits the parent's env, but only when the
    /// objects are actually declared on the parent.
    @EnvironmentObject private var currencyStore: CurrencyStore
    @EnvironmentObject private var transactionStore: TransactionStore
    @State private var items: [ReceiptItem]
    @State private var currency: String
    @State private var showEditor: Bool = false

    init(
        parseResult: HybridReceiptParser.Result,
        sourceImage: UIImage?,
        onConfirm: @escaping (_ items: [ReceiptItem], _ total: Double, _ currency: String) -> Void,
        onCancel: @escaping () -> Void,
        wrapInNavigationStack: Bool = true
    ) {
        self.parseResult = parseResult
        self.sourceImage = sourceImage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        self.wrapInNavigationStack = wrapInNavigationStack
        _items = State(initialValue: parseResult.parsedReceipt.items)
        // Init with whatever the parser produced; an empty string here is
        // intentional and gets backfilled from the user's base currency
        // in `.task` below — `@EnvironmentObject` isn't accessible from
        // an init, so the fallback can't run synchronously.
        _currency = State(initialValue: parseResult.parsedReceipt.currency ?? "")
    }

    private var itemsTotal: Double {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    private var grandTotal: Double? {
        parseResult.parsedReceipt.totalAmount
    }

    /// Σ(items) measured against the parser's detected grand total. A
    /// correctly-read receipt matches to the cent — the register prints
    /// the total AS the sum of the line items — so a gap beyond a few
    /// cents flags a likely misread digit (a price's last decimal 8→0) or
    /// a dropped item. Checked INDEPENDENTLY of `parseResult.confidence`:
    /// a single last-decimal slip stays deep inside the 1 % confidence
    /// tolerance, so the receipt is bucketed `.high` and would otherwise
    /// show no warning at all. Returns the absolute gap when worth
    /// surfacing, else nil.
    private var priceTotalMismatch: Double? {
        guard let grand = grandTotal, grand > 0 else { return nil }
        let diff = abs(itemsTotal - grand)
        return diff > 0.05 ? diff : nil
    }

    var body: some View {
        if wrapInNavigationStack {
            NavigationStack { contentBody }
        } else {
            contentBody
        }
    }

    private var contentBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.xl) {
                receiptHeader
                itemsList
                itemsCountLabel
                totalsSummary
                editItemsButton
                Spacer().frame(height: 40)
            }
            .padding(.top, AppSpacing.lg)
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Receipt items")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    onCancel()
                    // Embedded mode (push step inside an existing
                    // NavigationStack): the parent's `onCancel` owns
                    // the routing decision (close the orchestrator,
                    // pop a step, etc.) — calling `dismiss()` here
                    // would either no-op or close the wrong layer.
                    if wrapInNavigationStack { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    onConfirm(items, itemsTotal, currency)
                    if wrapInNavigationStack { dismiss() }
                }
                .disabled(items.isEmpty)
                .fontWeight(.semibold)
            }
        }
        .sheet(isPresented: $showEditor) {
            ReceiptItemEditorSheet(
                initialItems: items,
                // Anchor to the items sum the user sees in the "Total"
                // row above (not the raw parser-detected `grandTotal`).
                // The user reads the prominent Total as the agreed
                // amount; the editor should treat it the same way so
                // it opens balanced and only flags divergence the user
                // *introduces* by editing.
                receiptTotal: itemsTotal,
                currency: currency,
                onSave: { newItems, _, newCurrency in
                    // Replace local items; itemsTotal is recomputed
                    // from the new array. Currency comes back so a
                    // user-correction inside the editor (typical when
                    // OCR guessed wrong) carries through to the final
                    // commit.
                    items = newItems
                    currency = newCurrency
                },
                onCancel: {}
            )
            .environmentObject(currencyStore)
            .environmentObject(transactionStore)
        }
        .task {
            // Backfill currency from the user's base when the parser
            // produced nothing — better default than hardcoded "USD"
            // because the rest of the app reasons in the user's chosen
            // base. Runs only on first appearance; an explicit user pick
            // in the editor (or anywhere else) takes precedence forever.
            if currency.isEmpty {
                currency = currencyStore.selectedCurrency
            }
        }
    }

    // MARK: - Header

    /// Store name + optional warning banner. The items counter used to live
    /// here as a subtitle but now sits between the list and the Total row
    /// so it reads as a footer for the items section.
    @ViewBuilder
    private var receiptHeader: some View {
        if parseResult.confidence == .high {
            storeNameBlock
        } else {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                storeNameBlock
                confidenceBannerIfNeeded
            }
        }
    }

    /// Just the store name — splits off from the items counter so the
    /// confidence banner can sit *between* them when the parser flagged
    /// something the user should double-check.
    @ViewBuilder
    private var storeNameBlock: some View {
        if let store = parseResult.parsedReceipt.storeName, !store.isEmpty {
            Text(store)
                .font(AppFonts.subhead)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    /// Items counter, rendered separately so it can sit just above the
    /// list (under any banner that fires).
    private var itemsCountLabel: some View {
        Text("\(items.count) \(items.count == 1 ? "item" : "items")")
            .font(.caption)
            .foregroundColor(AppColors.textTertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Confidence banner

    @ViewBuilder
    private var confidenceBannerIfNeeded: some View {
        if let grand = grandTotal, priceTotalMismatch != nil {
            // Most actionable signal: the items don't sum to the printed
            // total. Points the user straight at "a price is misread"
            // even when overall confidence is `.high`.
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: AppColors.warning,
                title: "Prices don't add up",
                subtitle: "Items add up to \(ReceiptItem.formatAmount(itemsTotal)), but the receipt total is \(ReceiptItem.formatAmount(grand)). Check the items for a misread amount."
            )
        } else {
            switch parseResult.confidence {
            case .high:
                EmptyView()
            case .medium, .low:
                // The user doesn't need to know "totals divergence" vs "no
                // AI was used" — both want the same prompt: double-check.
                banner(
                    icon: "exclamationmark.triangle.fill",
                    tint: AppColors.warning,
                    title: "Double-check the receipt",
                    subtitle: "Some details may be off — please review the items below before saving."
                )
            }
        }
    }

    private func banner(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(tint.opacity(0.1))
        )
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Edit items CTA
    //
    // Subtle, centred, no background — same visual rhythm as the
    // "Add new friend" CTA on `FriendPickerView` ("Who to split with").
    // The Save button in the toolbar is the primary action; this is the
    // quiet escape hatch into the editor for users who want to tweak.
    private var editItemsButton: some View {
        Button {
            showEditor = true
        } label: {
            HStack(spacing: AppSpacing.xs) {
                Image(systemName: "slider.horizontal.3")
                    .font(AppFonts.captionEmphasized)
                Text("Edit items")
                    .font(AppFonts.captionEmphasized)
            }
            .foregroundColor(.accentColor)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, AppSpacing.sm)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Items list

    @ViewBuilder
    private var itemsList: some View {
        if items.isEmpty {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(AppColors.textTertiary)
                Text("No items detected")
                    .font(.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: AppSpacing.sm) {
                ForEach(items) { item in
                    itemRow(item)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func itemRow(_ item: ReceiptItem) -> some View {
        let kind = item.kind
        let isDiscount = kind == .discount
        return HStack(alignment: .center, spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: kind)
            Text(item.name)
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            // Right-side stack: bold line total on top, the unit-breakdown
            // ("2 × 850 RSD") on a smaller line directly underneath. This
            // keeps the receipt-row hierarchy money-first — the value the
            // user wants to scan reads on the leading edge of the trailing
            // column, with the qty/price detail tucked subordinate
            // beneath, rather than splitting that detail off under the
            // item's name where it competed for the name's vertical space.
            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                ReceiptItemAmountText(
                    amount: item.lineTotal,
                    currency: currency,
                    isDiscount: isDiscount
                )
                if let qty = item.quantity, qty != 1, let price = item.price {
                    Text("\(ReceiptItem.formatQuantity(qty)) × \(ReceiptItem.formatAmount(price)) \(currency)")
                        .font(.caption)
                        .foregroundColor(AppColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(isDiscount ? AppColors.success.opacity(0.08) : AppColors.backgroundElevated)
        )
    }

    // MARK: - Totals

    /// Single calculated total. We omit the per-row "Items vs Receipt" split
    /// — the divergence (when there is one) is already surfaced by the
    /// `confidenceBannerIfNeeded` block above the list, which is the place
    /// the user expects to see "something's off, please check".
    @ViewBuilder
    private var totalsSummary: some View {
        HStack {
            Text("Total")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            ReceiptItemAmountText(amount: itemsTotal, currency: currency)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

}

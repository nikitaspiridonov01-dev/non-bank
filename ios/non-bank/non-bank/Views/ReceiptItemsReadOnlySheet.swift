import SwiftUI

/// Read-only items breakdown shown when the user taps the `ItemsBadgePill`
/// on an already-saved transaction row. The committed item set lives in
/// `ReceiptItemStore`; we look it up by `transactionID` and render a
/// non-interactive list. Editing is intentionally not exposed here — to
/// modify items the user has to "Edit transaction" → go through the
/// full create-transaction modal.
struct ReceiptItemsReadOnlySheet: View {
    let items: [ReceiptItem]
    let currency: String
    var storeName: String? = nil
    var date: String? = nil
    /// Optional participant the sheet is scoped to. When non-nil
    /// the navigation title surfaces "{name}'s items" — used by the
    /// `ShareDistributionView` per-row tap-through which presents
    /// only the receipt rows assigned to that person. `nil` keeps
    /// the generic "Receipt items" title used by the full-list
    /// entry point.
    var participantName: String? = nil
    /// Sub-app palette of the parent screen — passed through here
    /// because `.sheet` content doesn't inherit `@Environment` values.
    /// Drives the presentation background so the sheet picks up the
    /// same lavender / warm-red / cream tone as the surface that
    /// opened it (no jarring dark slab landing on top of a tinted
    /// page).
    var colorContext: ColorContext = .standard

    @Environment(\.dismiss) private var dismiss

    private var grandTotal: Double {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    /// Per-participant scoping hides the receipt-wide totals row and
    /// the "N items" counter — both read as misleading info there.
    /// The "Total" on a participant-scoped sheet would only sum the
    /// rows assigned to them (proportional fees / discounts aren't
    /// here), so it's a different number from their share on the
    /// review screen; cleaner to drop it and let the user read items
    /// only. The counter is similarly redundant — a per-person view
    /// implies "these are the rows for this person".
    private var isParticipantScoped: Bool {
        participantName != nil
    }

    /// English title for the participant-scoped variant. "You's items"
    /// reads as broken grammar, so the "You" case gets the possessive
    /// pronoun ("Your items"); every other name keeps the regular
    /// possessive-`'s` shape (`Cey's items`).
    private var resolvedTitle: String {
        guard let name = participantName else { return "Receipt items" }
        return name == "You" ? "Your items" : "\(name)'s items"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headerBlock
                    itemsList
                    if !isParticipantScoped {
                        itemsCountLabel
                        totalsBlock
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.top, AppSpacing.lg)
            }
            // Transparent ScrollView so the sheet's translucent
            // `.ultraThinMaterial` shows through — without this the
            // ScrollView's default opaque background masks the glass
            // and the sheet reads as a flat dark tray.
            .scrollContentBackground(.hidden)
            .navigationTitle(resolvedTitle)
            .navigationBarTitleDisplayMode(.inline)
            // `.toolbarBackground(.hidden)` removes the navigation bar's
            // own opaque material — otherwise it stacks an extra opaque
            // strip on top of the glass and the title area looks darker
            // than the rest of the sheet.
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Full-screen only — the half-detent variant gave inconsistent
        // contrast across detent heights (the in-sheet glass items
        // picked up parent content bleeding through `.medium`) and
        // the user prefers a single, predictable presentation.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // No explicit `presentationCornerRadius` — iOS-26's system
        // default is more rounded (~36-38pt) and matches the corners
        // of `WhoPaidPickerView` and the other detent sheets in the
        // app. Hardcoding 16 made this tray visibly squarer than its
        // siblings and broke the family.
        // Sub-app gradient ONLY — no `.ultraThinMaterial` overlay
        // anymore. The material tier let parent content bleed through
        // at the medium detent, which made the in-sheet `.glassEffect`
        // item rows pick up an unpredictable mix (sheet tint + parent
        // dark) and lose contrast against their own page. With a
        // solid gradient bg, items always tint against the SAME warm-
        // red / lavender / cream surface regardless of detent height,
        // and the full-screen rendering — which the user already
        // confirmed reads fine — stays identical at half height.
        .presentationBackground {
            contextBackground
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var contextBackground: some View {
        switch colorContext {
        case .reminders: ReminderDetailPageBackground()
        case .split:     SplitDetailPageBackground()
        case .standard:  AppColors.backgroundPrimary
        }
    }

    @ViewBuilder
    private var headerBlock: some View {
        if storeName != nil || date != nil {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                if let storeName, !storeName.isEmpty {
                    Text(storeName)
                        .font(AppFonts.subhead)
                        .foregroundColor(AppColors.textPrimary)
                }
                if let date, !date.isEmpty {
                    Text(date)
                        .font(.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    @ViewBuilder
    private var itemsCountLabel: some View {
        if !items.isEmpty {
            Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                .font(.caption)
                .foregroundColor(AppColors.textTertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    @ViewBuilder
    private var itemsList: some View {
        if items.isEmpty {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(AppColors.textTertiary)
                Text("No items recorded")
                    .font(.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: AppSpacing.sm) {
                ForEach(items) { item in
                    row(item)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func row(_ item: ReceiptItem) -> some View {
        let kind = item.kind
        let isDiscount = kind == .discount
        return HStack(spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: kind)
            Text(item.name)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            // Trailing column: line total on top, qty × unit price
            // beneath. Mirrors the `ReceiptReviewView` row so a user
            // who saw "2 × 850 RSD" under the amount during the post-
            // scan review keeps that exact reading position open later.
            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                ReceiptItemAmountText(
                    amount: item.lineTotal,
                    currency: currency,
                    isDiscount: isDiscount
                )
                if let qty = item.quantity, qty > 1, let price = item.price {
                    Text("\(ReceiptItem.formatQuantity(qty)) × \(ReceiptItem.formatAmount(price)) \(currency)")
                        .font(.caption)
                        .foregroundColor(AppColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        // iOS-26 Liquid Glass — same modifier the transaction card
        // uses for its Notes block and timeline rows. Adapts to the
        // sub-app tint sitting under it (warm-red / lavender / cream)
        // instead of the flat `backgroundElevated` slab that read as
        // a dark block dropped onto a lavender page.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private var totalsBlock: some View {
        totalsRow(
            label: "Total",
            value: grandTotal,
            color: AppColors.textPrimary,
            emphasized: true
        )
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.md)
        // Same Liquid Glass family as the item rows above so the
        // totals card reads as one of the cards rather than a
        // contrasting solid block.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    private func totalsRow(label: String, value: Double, color: Color, emphasized: Bool = false) -> some View {
        HStack {
            Text(label)
                .font(emphasized ? AppFonts.bodyEmphasized : AppFonts.body)
                .foregroundColor(emphasized ? AppColors.textPrimary : AppColors.textSecondary)
            Spacer()
            // Discounts subtotal already carries a "-" via `isDiscount`; the
            // grand-total row passes the absolute amount so it doesn't render
            // a stray minus when the subtotal-minus-discounts net is zero.
            ReceiptItemAmountText(
                amount: value,
                currency: currency,
                isDiscount: value < 0
            )
        }
    }

}

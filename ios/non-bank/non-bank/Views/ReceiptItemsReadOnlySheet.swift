import SwiftUI
import UIKit

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
    /// Split participants keyed by assignment id (`Friend.id` /
    /// `ReceiptItem.selfParticipantID`). When non-empty, each `.item` row
    /// assigned to ≥1 of them shows a "who shares this" avatar pile and
    /// becomes tappable to a per-item distribution sheet. Empty (default)
    /// keeps the original non-interactive list, so existing callers are
    /// unaffected.
    var participants: [String: ItemAssignmentParticipant] = [:]

    @Environment(\.dismiss) private var dismiss
    /// The item whose per-person distribution sheet is currently open.
    @State private var selectedItemForClaimants: ReceiptItem? = nil

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
        // Per-item "who shares this" distribution sheet. Sheet-on-sheet:
        // presented from this already-.large sheet, with its own detents.
        .sheet(item: $selectedItemForClaimants) { item in
            PerItemClaimantsSheet(
                item: item,
                currency: currency,
                claimants: claimantEntries(for: item),
                colorContext: colorContext
            )
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
            // Apple-required grouping so sibling row glass stays
            // mutually consistent (each row keeps its own `.glassEffect`).
            GlassEffectContainer {
                VStack(spacing: AppSpacing.sm) {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func row(_ item: ReceiptItem) -> some View {
        let kind = item.kind
        let isDiscount = kind == .discount
        let sharers = avatarParticipants(for: item)
        return HStack(spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: kind)
            Text(item.name)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            // Trailing column: the "who shares this" avatar pile sits ABOVE
            // the price (matching the item-assignment screen), then the line
            // total, then qty × unit price. The pile only appears on
            // assignable item rows of a byItems split with ≥1 active
            // assignee; tapping such a row opens the per-item distribution
            // sheet. Unassigned / non-item rows show no pile and stay inert.
            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                if !sharers.isEmpty {
                    OverlappingAvatarStack(
                        participants: sharers,
                        avatarSize: 20,
                        strokeColor: AppColors.backgroundElevated,
                        maxVisible: 3,
                        overflowCount: max(0, sharers.count - 3)
                    )
                }
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
        // Uniform sub-app card fill UNDER the glass (same rounded-rect
        // shape) so every row samples a constant backdrop — a taller
        // 2-line row no longer reads lighter than a short one. The glass
        // sits on top of this controlled fill rather than the live page
        // gradient.
        .background(
            colorContext.cardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
        )
        // iOS-26 Liquid Glass — same modifier the transaction card
        // uses for its Notes block and timeline rows.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            // Only assignable rows with claimants are interactive.
            guard !sharers.isEmpty else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedItemForClaimants = item
        }
    }

    /// Active claimants of `item` (assignees ∩ roster) with each one's
    /// equal slice, in assignment order. Empty for non-item rows, rows
    /// with no active assignees, or when no roster was supplied.
    private func claimantEntries(for item: ReceiptItem) -> [SplitClaimant] {
        SplitClaimantBuilder.claimants(of: item, roster: participants)
    }

    private func avatarParticipants(for item: ReceiptItem) -> [OverlappingAvatarStack.Participant] {
        SplitClaimantBuilder.avatars(claimantEntries(for: item))
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
        // Uniform under-fill (same shape) so the totals card samples the
        // same constant backdrop as the item rows above.
        .background(
            colorContext.cardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
        )
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

// MARK: - Per-item distribution

/// One claimant of a receipt line + their equal slice of its price.
/// A struct (not a tuple) so it's `Identifiable` for `ForEach`.
struct SplitClaimant: Identifiable {
    let participant: ItemAssignmentParticipant
    let slice: Double
    var id: String { participant.id }
}

/// Builds the display claimant list + avatar descriptors for an item from
/// a participant roster, intersecting assignments with the roster the same
/// way `SplitItemBreakdown` does. Shared by the full-receipt sheet
/// (Screen A) and the per-person breakdown sheet (Screen B) so both render
/// identical avatars and slices.
enum SplitClaimantBuilder {
    static func claimants(
        of item: ReceiptItem,
        roster: [String: ItemAssignmentParticipant]
    ) -> [SplitClaimant] {
        guard !roster.isEmpty else { return [] }
        let set = Set(roster.keys)
        return SplitItemBreakdown.claimants(of: item, participants: set).compactMap { c in
            guard let p = roster[c.participantID] else { return nil }
            return SplitClaimant(participant: p, slice: c.slice)
        }
    }

    static func avatars(_ claimants: [SplitClaimant]) -> [OverlappingAvatarStack.Participant] {
        claimants.map { c in
            OverlappingAvatarStack.Participant(
                id: c.participant.isMe ? UserIDService.currentID() : c.participant.id,
                isConnected: c.participant.isConnected
            )
        }
    }
}

/// Read-only "who shares this item" sheet, opened by tapping an item row
/// on a `byItems` split. Shows each claimant + their equal slice of the
/// item's price. Price division only — proportional fees/discounts are
/// surfaced on the per-person breakdown, not here, because they can't be
/// honestly attributed to a single line.
struct PerItemClaimantsSheet: View {
    let item: ReceiptItem
    let currency: String
    let claimants: [SplitClaimant]
    var colorContext: ColorContext = .standard

    @Environment(\.dismiss) private var dismiss

    private var subtitle: String {
        let n = claimants.count
        return "Split between \(n) \(n == 1 ? "person" : "people")"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.name)
                            .font(.system(size: 28, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(subtitle)
                            .font(AppFonts.bodySmallRegular)
                            .foregroundColor(AppColors.textTertiary)
                    }

                    // Grouped so sibling claimant-row glass stays
                    // mutually consistent, each over a uniform under-fill.
                    GlassEffectContainer {
                        VStack(spacing: AppSpacing.sm) {
                            ForEach(claimants) { entry in
                                HStack(spacing: AppSpacing.md) {
                                    PixelCatView(
                                        id: entry.participant.isMe ? UserIDService.currentID() : entry.participant.id,
                                        size: 36,
                                        blackAndWhite: !entry.participant.isConnected
                                    )
                                    .clipShape(Circle())

                                    Text(entry.participant.isMe ? "You" : entry.participant.name)
                                        .font(AppFonts.labelPrimary)
                                        .foregroundColor(AppColors.textPrimary)
                                        .lineLimit(1)

                                    Spacer(minLength: 8)

                                    ReceiptItemAmountText(
                                        amount: entry.slice,
                                        currency: currency,
                                        isDiscount: false
                                    )
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, AppSpacing.rowVertical)
                                .background(
                                    colorContext.cardFill,
                                    in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                                )
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                            }
                        }
                    }

                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.lg)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
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
}

import SwiftUI

/// Read-only breakdown of how a purchase is split between participants.
/// Pushed from the orange "N people" section of the chart in `SplitBreakdownView`.
/// Each row shows a horizontal bar sized to the participant's share of the
/// total, plus the percentage and amount.
struct ShareDistributionView: View {
    let split: SplitInfo
    let currency: String
    /// Used to look up the transaction's `ReceiptItem`s so we can show
    /// a per-participant "N items" affordance under each row. Items
    /// live in `ReceiptItemStore` (keyed by transaction id), separate
    /// from `splitInfo`. On the recipient side, items now ride along
    /// via the encrypted share-items channel (Phase 10) and the
    /// receiver mapper persists them locally before the detail view
    /// renders — so the lookup returns the same per-row affordance
    /// the sender sees. If the channel didn't deliver (legacy sender,
    /// expired snapshot, decrypt failure) the store is empty here and
    /// the affordance hides naturally.
    let transactionID: Int

    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    /// Items committed to this transaction. Empty on the recipient
    /// side of a shared transaction (the receipt isn't shared) — that's
    /// what suppresses the per-row "N items" button there without any
    /// extra check.
    private var receiptItems: [ReceiptItem] {
        receiptItemStore.items(forTransactionID: transactionID)
    }

    /// True when the transaction was split byItems AND we have the
    /// item assignments locally. Either condition false → don't offer
    /// the per-row item-list affordance.
    private var hasItemBreakdown: Bool {
        guard split.splitMode == .byItems else { return false }
        return receiptItems.contains { !$0.assignedParticipantIDs.isEmpty }
    }

    private struct ShareRow: Identifiable {
        let name: String
        let avatarID: String
        let isMe: Bool
        let isConnected: Bool
        let amount: Double
        /// Participant ID used for matching against
        /// `ReceiptItem.assignedParticipantIDs` — `"__me__"` for the
        /// user, `Friend.id` for friends. Distinct from `avatarID`
        /// (which points at `UserIDService.currentID()` for the user
        /// so the cat avatar matches the rest of the app).
        let participantID: String

        var id: String { participantID }
    }

    /// Drives the per-participant "N items" sheet. Set on row-button
    /// tap; cleared on dismiss. `nil` = no sheet shown.
    @State private var itemsSheetTarget: ShareRow? = nil

    private var sharers: [ShareRow] {
        var result: [ShareRow] = []
        if split.myShare > 0.005 {
            result.append(ShareRow(
                name: "You",
                avatarID: UserIDService.currentID(),
                isMe: true,
                isConnected: true,
                amount: split.myShare,
                participantID: ReceiptItem.selfParticipantID
            ))
        }
        for friend in split.friends where friend.share > 0.005 {
            let stored = friendStore.friend(byID: friend.friendID)
            result.append(ShareRow(
                name: stored?.name ?? "Friend",
                avatarID: friend.friendID,
                isMe: false,
                isConnected: stored?.isConnected ?? false,
                amount: friend.share,
                participantID: friend.friendID
            ))
        }
        return result
    }

    /// Receipt items assigned to a given participant. Only `.item`
    /// kind ends up in `assignedParticipantIDs` (fees, taxes,
    /// discounts are distributed proportionally by
    /// `SplitShareCalculator`, not assigned), so this filter cleanly
    /// produces the user-pickable rows.
    private func items(for participantID: String) -> [ReceiptItem] {
        receiptItems.filter { $0.assignedParticipantIDs.contains(participantID) }
    }

    /// Roster keyed by assignment id (`Friend.id` / `selfParticipantID`)
    /// for the per-item "shared by" avatars + tap-through inside the
    /// per-person breakdown sheet. `you` is always present; a friend the
    /// split references but who's since been removed is skipped.
    private var participantRoster: [String: ItemAssignmentParticipant] {
        var roster: [String: ItemAssignmentParticipant] = [
            ReceiptItem.selfParticipantID: ItemAssignmentParticipant(
                id: ReceiptItem.selfParticipantID, name: "You", isMe: true, isConnected: true
            )
        ]
        for friend in split.friends {
            if let stored = friendStore.friend(byID: friend.friendID) {
                roster[stored.id] = ItemAssignmentParticipant(
                    id: stored.id, name: stored.name, isMe: false, isConnected: stored.isConnected
                )
            }
        }
        return roster
    }

    private var total: Double {
        max(sharers.reduce(0) { $0 + $1.amount }, 0.0001)
    }

    /// Mirrors the badge logic on the edit screen (50/50 for 2, Evenly otherwise).
    private var splitModeLabel: String {
        guard let mode = split.splitMode else { return "Evenly" }
        if mode == .evenly {
            return sharers.count == 2 ? "50/50" : "Evenly"
        }
        return mode.displayLabel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                list
                Spacer().frame(height: 40)
            }
            .padding(.top, AppSpacing.lg)
        }
        // Same Split-context gradient background as PaidUpfrontView —
        // keeps the lavender / pink aurora through every push of the
        // debt drilldown.
        .background(SplitPageBackground())
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $itemsSheetTarget) { target in
            // Per-person breakdown: each item shown at this person's SLICE
            // (price ÷ co-assignees), plus their proportional cut of each
            // fee/tip/discount as its own row, and the authoritative Total
            // from SplitInfo.share. Computed from the same stored items via
            // SplitItemBreakdown so the numbers reconcile to the split.
            let allIDs = Set([ReceiptItem.selfParticipantID] + split.friends.map { $0.friendID })
            let byID = SplitItemBreakdown.compute(items: receiptItems, participants: allIDs)
            ParticipantBreakdownSheet(
                participantName: target.name,
                isMe: target.isMe,
                breakdown: byID[target.participantID]
                    ?? SplitItemBreakdown.ParticipantBreakdown(items: [], charges: [], total: target.amount),
                totalShare: target.amount,
                currency: currency,
                roster: participantRoster
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: 6) {
                // Split-themed pill ("50/50", "custom", etc.). Liquid
                // Glass capsule rather than a flat `splitChipFill` so
                // the badge lifts off the lavender aurora the same
                // way the rows below do — frosted family across the
                // whole screen.
                Text(splitModeLabel)
                    .font(AppFonts.labelSmall)
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 3)
                    .glassEffect(.regular, in: Capsule())
                Text("between \(sharers.count) \(sharers.count == 1 ? "person" : "people")")
                    .font(AppFonts.heading)
                    .foregroundColor(AppColors.textPrimary)
            }
            Text("Each person's share of the purchase.")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if sharers.isEmpty {
            Text("No participants")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            // Apple-required grouping so sibling row glass stays
            // mutually consistent (each row keeps its own `.glassEffect`).
            GlassEffectContainer {
                VStack(spacing: AppSpacing.md) {
                    ForEach(Array(sharers.enumerated()), id: \.offset) { _, sharer in
                        row(sharer)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func row(_ sharer: ShareRow) -> some View {
        let fraction = sharer.amount / total
        let percent = Int((fraction * 100).rounded())
        let participantItems = items(for: sharer.participantID)
        let showsItemsButton = hasItemBreakdown && !participantItems.isEmpty

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.md) {
                PixelCatView(id: sharer.avatarID, size: 32, blackAndWhite: !sharer.isConnected)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(sharer.name)
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)

                    if showsItemsButton {
                        itemsChip(count: participantItems.count)
                    }
                }

                Spacer(minLength: 8)

                Text("\(percent)%")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
                    .monospacedDigit()

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(NumberFormatting.integerPart(sharer.amount))
                        .font(AppFonts.rowAmountInteger)
                        .foregroundColor(AppColors.textPrimary)
                    Text(NumberFormatting.decimalPartIfAny(sharer.amount))
                        .font(AppFonts.rowAmountCurrency)
                        .foregroundColor(AppColors.textSecondary)
                    Text(currency)
                        .font(AppFonts.rowAmountCurrency)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.leading, 3)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            bar(fraction: fraction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        // Uniform Split card fill UNDER the glass (same rounded-rect
        // shape) so every row samples a constant backdrop — a row with
        // the extra "N items" chip line no longer reads lighter than a
        // single-line row. Glass sits on top of this controlled fill.
        .background(
            AppColors.splitCardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous)
        )
        // `.glassEffect(.regular, in:)` — iOS 26 Liquid Glass that
        // matches the toolbar Close / Edit pills and the friend
        // rows in the debt summary so all Split list rows read as
        // one frosted family.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
        // The WHOLE card is the tap target (not just the small "N items"
        // chip) when there's an item breakdown to open. Rows without one
        // (recipient side of a shared tx) stay inert — the guard no-ops and
        // the button a11y trait is omitted so VoiceOver doesn't promise a
        // tap that does nothing.
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.large, style: .continuous))
        .onTapGesture {
            guard showsItemsButton else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            itemsSheetTarget = sharer
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(showsItemsButton ? .isButton : [])
    }

    /// "N items >" affordance sitting under the participant's name. Now a
    /// plain (non-interactive) chip — the parent row owns the tap — kept as
    /// a visual cue that the row opens the per-person item list. Only
    /// renders when this transaction was split byItems AND we have the
    /// receipt locally (both fail on the recipient side of a shared
    /// transaction, which is what suppresses it there as the user expects).
    private func itemsChip(count: Int) -> some View {
        HStack(spacing: 3) {
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(AppFonts.metaRegular)
            Image(systemName: "chevron.right")
                .font(AppFonts.iconSmall)
        }
        .foregroundColor(AppColors.textTertiary)
    }

    /// Grayscale track + fill bar. Non-colored per spec — shape alone conveys
    /// the proportion, so no need to introduce a color legend here.
    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track also picks up the Split chip fill so the
                // bar doesn't borrow warm cream against the lavender card.
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.splitChipFill)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.splitAccent)
                    .frame(width: max(geo.size.width * fraction, 3))
            }
        }
        .frame(height: 8)
    }
}

// MARK: - Per-person breakdown sheet

/// One participant's share, itemised: each assigned item at this person's
/// SLICE (price ÷ co-assignees), each fee/tip/discount as its own row
/// showing their proportional cut, and the authoritative Total from
/// `SplitInfo.share`. Items shared by >1 person carry a "shared by" avatar
/// pile and tap through to `PerItemClaimantsSheet`. Display-only.
private struct ParticipantBreakdownSheet: View {
    let participantName: String
    let isMe: Bool
    let breakdown: SplitItemBreakdown.ParticipantBreakdown
    /// Source-of-truth total (the persisted `SplitInfo` share) — shown
    /// verbatim so the footer can't drift from the split by a rounding cent.
    let totalShare: Double
    let currency: String
    let roster: [String: ItemAssignmentParticipant]

    @Environment(\.dismiss) private var dismiss
    @State private var selectedItemForClaimants: ReceiptItem? = nil

    private var title: String { isMe ? "Your items" : "\(participantName)'s items" }

    private var shareLabel: String { isMe ? "your share" : "\(participantName)'s share" }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: AppSpacing.sm) {
                    // Apple-required grouping so all sibling row glass
                    // (items, charges, total) stays mutually consistent;
                    // each row keeps its own `.glassEffect` over a uniform
                    // under-fill.
                    GlassEffectContainer {
                        VStack(spacing: AppSpacing.sm) {
                            ForEach(breakdown.items) { slice in
                                itemRow(slice)
                            }
                            ForEach(breakdown.charges) { cut in
                                chargeRow(cut)
                            }
                            totalRow
                                .padding(.top, AppSpacing.xs)
                        }
                    }
                    Spacer().frame(height: 40)
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.top, AppSpacing.lg)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationBackground {
            SplitDetailPageBackground().ignoresSafeArea()
        }
        .sheet(item: $selectedItemForClaimants) { item in
            PerItemClaimantsSheet(
                item: item,
                currency: currency,
                claimants: SplitClaimantBuilder.claimants(of: item, roster: roster),
                colorContext: .split
            )
        }
    }

    private func itemRow(_ slice: SplitItemBreakdown.ItemSlice) -> some View {
        let claimants = SplitClaimantBuilder.claimants(of: slice.item, roster: roster)
        let shared = claimants.count > 1
        let avatars = shared ? SplitClaimantBuilder.avatars(claimants) : []
        return HStack(spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: .item)
            Text(slice.item.name)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            if !avatars.isEmpty {
                OverlappingAvatarStack(
                    participants: avatars,
                    avatarSize: 20,
                    strokeColor: AppColors.backgroundElevated,
                    maxVisible: 3,
                    overflowCount: max(0, avatars.count - 3)
                )
            }
            ReceiptItemAmountText(amount: slice.slice, currency: currency, isDiscount: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        // Uniform under-fill (same shape) so a wrapped 2-line item name
        // doesn't make the glass read lighter than a single-line row.
        .background(
            AppColors.splitCardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            // Only items shared by >1 person open a per-item detail.
            guard shared else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectedItemForClaimants = slice.item
        }
    }

    private func chargeRow(_ cut: SplitItemBreakdown.ChargeCut) -> some View {
        HStack(spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: cut.kind)
            Text(chargeLabel(cut.kind))
                .font(AppFonts.body)
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            ReceiptItemAmountText(
                amount: cut.amount,
                currency: currency,
                isDiscount: cut.kind == .discount
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        // Uniform under-fill (same shape) — constant backdrop per row.
        .background(
            AppColors.splitCardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private func chargeLabel(_ kind: ReceiptItem.Kind) -> String {
        switch kind {
        case .fee:      return "Service fee (\(shareLabel))"
        case .tip:      return "Tip (\(shareLabel))"
        case .discount: return "Discount (\(shareLabel))"
        case .item:     return ""
        }
    }

    private var totalRow: some View {
        HStack {
            Text("Total")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            ReceiptItemAmountText(amount: totalShare, currency: currency, isDiscount: totalShare < 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.md)
        // Uniform under-fill (same shape) — constant backdrop per row.
        .background(
            AppColors.splitCardFill,
            in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
        )
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }
}

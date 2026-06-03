import SwiftUI
import UIKit

// MARK: - Participant model

/// Lightweight participant descriptor passed into the assignment flow.
/// Mirrors `WhoPaidParticipant` but kept distinct so the two callers
/// can evolve their own fields (e.g. avatar coloring rule) without
/// dragging the other along. The `id` is either a `Friend.id` or
/// `ReceiptItem.selfParticipantID` for the user.
struct ItemAssignmentParticipant: Identifiable, Equatable {
    let id: String
    let name: String
    /// Marks the user-themselves slot — drives "You" labels.
    let isMe: Bool
    /// Whether this friend has accepted a shared transaction with the
    /// user (mirrors `Friend.isConnected`). Drives the coloured-vs-B&W
    /// avatar treatment so connected friends keep their colour here,
    /// matching the rest of the app. Always true for `isMe`.
    let isConnected: Bool
}

// MARK: - Flow orchestrator

/// Splitwise-style per-participant walk-through for the `byItems`
/// split mode. Each step asks one participant which receipt items they
/// took; after the last participant a review screen shows the resulting
/// per-person amounts.
///
/// Selection state is held locally in `selectionsByParticipant` and
/// only committed back to the caller's items array via `onConfirm` at
/// the very end — reaching the Save button means the user has walked
/// every participant and reviewed the math, so we don't write
/// half-finished assignments back if they bail out mid-flow.
///
/// Items shown to participants are filtered to `.item` kind only —
/// fees / taxes / tips / discounts are distributed proportionally by
/// `SplitShareCalculator` and don't appear in the per-person checklist.
struct ItemAssignmentFlow: View {
    @Environment(\.dismiss) private var dismiss

    let items: [ReceiptItem]
    let participants: [ItemAssignmentParticipant]
    let currency: String
    /// Called on Save with the new `assignedParticipantIDs` for each
    /// item, keyed by the item's `syncID` (stable across in-memory
    /// reorders / re-loads, unlike the SwiftUI-iteration `id: UUID`).
    let onConfirm: ([String: [String]]) -> Void

    /// Items that are actually selectable in the per-person view —
    /// fees/tax/tip/discount are auto-distributed by the calculator,
    /// so they don't belong in the checklist.
    private var assignableItems: [ReceiptItem] {
        items.filter { $0.kind == .item }
    }

    /// Per-participant selection sets. Keyed by participant ID;
    /// values are the in-memory `ReceiptItem.id` (UUID) sets selected
    /// in that participant's step. Initialised from each item's
    /// existing `assignedParticipantIDs` so re-entering the flow
    /// (edit mode, or re-open via the chip indicator) starts where
    /// the previous walk left off.
    @State private var selectionsByParticipant: [String: Set<UUID>]
    @State private var stepIndex: Int = 0

    init(
        items: [ReceiptItem],
        participants: [ItemAssignmentParticipant],
        currency: String,
        onConfirm: @escaping ([String: [String]]) -> Void
    ) {
        self.items = items
        self.participants = participants
        self.currency = currency
        self.onConfirm = onConfirm

        var selections: [String: Set<UUID>] = [:]
        for p in participants {
            var set = Set<UUID>()
            for item in items where item.kind == .item {
                if item.assignedParticipantIDs.contains(p.id) {
                    set.insert(item.id)
                }
            }
            selections[p.id] = set
        }
        _selectionsByParticipant = State(initialValue: selections)
    }

    var body: some View {
        NavigationStack {
            content
                .background(AppColors.backgroundPrimary.ignoresSafeArea())
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
    }

    // MARK: - Step routing

    @ViewBuilder
    private var content: some View {
        if stepIndex < participants.count {
            ItemAssignmentStep(
                participant: participants[stepIndex],
                stepNumber: stepIndex + 1,
                totalSteps: participants.count,
                items: assignableItems,
                currency: currency,
                selection: bindingForCurrentParticipant,
                onContinue: advance
            )
        } else {
            ItemAssignmentReview(
                items: items,
                participants: participants,
                selections: selectionsByParticipant,
                currency: currency,
                onSave: commit
            )
        }
    }

    /// Two-way binding into the current participant's selection set.
    /// Wrapping the dictionary lookup here keeps `ItemAssignmentStep`
    /// agnostic of how multi-step state is stored — it just sees a
    /// `Binding<Set<UUID>>` like any single-screen selection.
    private var bindingForCurrentParticipant: Binding<Set<UUID>> {
        let id = participants[stepIndex].id
        return Binding(
            get: { selectionsByParticipant[id] ?? [] },
            set: { selectionsByParticipant[id] = $0 }
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if stepIndex == 0 {
                Button("Cancel") { dismiss() }
            } else {
                Button(action: { stepIndex -= 1 }) {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Back")
            }
        }
        ToolbarItem(placement: .principal) {
            Text(stepIndex < participants.count ? "Assign items" : "Review")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
        }
    }

    // MARK: - Actions

    private func advance() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        stepIndex += 1
    }

    private func commit() {
        // Reconstruct each item's assignedParticipantIDs from the
        // per-participant selection sets — this is the only point
        // where local state is converted back into the caller's
        // sync-ID-keyed format.
        var result: [String: [String]] = [:]
        for item in assignableItems {
            var assignees: [String] = []
            for p in participants {
                if selectionsByParticipant[p.id]?.contains(item.id) == true {
                    assignees.append(p.id)
                }
            }
            result[item.syncID] = assignees
        }
        onConfirm(result)
        dismiss()
    }
}

// MARK: - Single-participant step

/// One screen in the assignment walk-through: shows the active
/// participant's avatar / name, the item checklist, and a single
/// bottom CTA whose label flips between "Skip this person" (zero
/// selected → that participant gets no items, and is filtered out of
/// the final `SplitInfo.friends` per the TZ) and "Continue" (>= 1
/// selected → push to the next participant). One CTA, never two —
/// flow design is "always one button forward".
struct ItemAssignmentStep: View {
    let participant: ItemAssignmentParticipant
    let stepNumber: Int
    let totalSteps: Int
    let items: [ReceiptItem]
    let currency: String
    @Binding var selection: Set<UUID>
    /// Whether this is the final participant in the byItems walk.
    /// Drives the "every item must be assigned" guard — earlier
    /// steps can leave items orphaned because a later participant
    /// might still pick them up.
    var isLastStep: Bool = false
    /// Items not selected by any participant across the whole walk.
    /// Non-empty only when `isLastStep` is true and at least one
    /// item is still on the floor; populated by the orchestrator
    /// because individual `ItemAssignmentStep`s only see their own
    /// selection binding.
    var globallyOrphanedItemIDs: Set<UUID> = []
    /// For each item, the OTHER participants who've already claimed
    /// it (current participant excluded). Drives the small avatar
    /// stack next to each row and the tap-through detail sheet.
    /// Populated by the orchestrator from `byItemsSelections`.
    var otherClaimants: [UUID: [ItemAssignmentParticipant]] = [:]
    let onContinue: () -> Void

    /// Receipt item the user tapped the avatar stack on — drives the
    /// claimants detail sheet. `nil` when no sheet is shown.
    @State private var claimantsSheetItem: ReceiptItem? = nil

    private var selectedCount: Int { selection.count }
    private var allSelected: Bool {
        !items.isEmpty && selection.count == items.count
    }

    /// True when we're on the final participant and at least one
    /// item is still unassigned across the whole walk. Both blocks
    /// the Continue/Skip button and surfaces the warning banner
    /// near the bottom; the user has to either tap the orange-ringed
    /// orphans here to claim them or swipe back to a prior step.
    private var hasUnresolvedOrphans: Bool {
        isLastStep && !globallyOrphanedItemIDs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.bottom, AppSpacing.xxxl)
                    // Small but clearly readable gap between the
                    // count/Select-all chrome and the list rows —
                    // earlier 4pt put the row practically against
                    // the first item, which read as one merged
                    // block. 12pt is ~3x the inter-row spacing, so
                    // the row still feels like a header above the
                    // list rather than a floating section.
                    selectAllRow
                        .padding(.bottom, AppSpacing.md)
                    itemList
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.bottom, AppSpacing.xxl)
            }

            // No surrounding `backgroundPrimary` panel — the button is
            // the only chrome at the bottom. Earlier the wrapper
            // painted a full-width strip in light mode, which read as
            // an unwanted second card behind the button.
            continueButton
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.md)
        }
        // Step indicator lives in the nav bar's principal slot —
        // small, dimmed (matches the body copy hierarchy of
        // `metaRegular` / `textTertiary`) and out of the way of the
        // body content. Frees the avatar + question from sharing
        // vertical space with a chrome-y "Step 3 of 4" line.
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Step \(stepNumber) of \(totalSteps)")
                    .font(AppFonts.metaRegular)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
        .sheet(item: $claimantsSheetItem) { item in
            ItemClaimantsSheet(
                item: item,
                claimants: otherClaimants[item.id] ?? []
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Sub-views

    private var header: some View {
        VStack(spacing: AppSpacing.sm) {
            PixelCatView(
                id: participant.isMe ? UserIDService.currentID() : participant.id,
                size: 64,
                blackAndWhite: !participant.isConnected
            )
            .clipShape(Circle())

            Text("Which items did \(participant.isMe ? "you" : participant.name) take?")
                .font(AppFonts.heading)
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text("Tap all items they're part of, including shared ones.")
                .font(AppFonts.bodySmallRegular)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var selectAllRow: some View {
        HStack {
            Text("\(selectedCount) of \(items.count) selected")
                .font(AppFonts.metaRegular)
                .foregroundColor(AppColors.textSecondary)
            Spacer()
            Button {
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                if allSelected {
                    selection.removeAll()
                } else {
                    selection = Set(items.map(\.id))
                }
            } label: {
                Text(allSelected ? "Deselect all" : "Select all")
                    .font(AppFonts.metaText)
                    .foregroundColor(.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var itemList: some View {
        if items.isEmpty {
            Text("No items to assign.")
                .font(AppFonts.body)
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 40)
        } else {
            VStack(spacing: AppSpacing.xs) {
                ForEach(items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: ReceiptItem) -> some View {
        let isSelected = selection.contains(item.id)
        // Orphan ring only appears for unselected items on the last
        // step that aren't claimed by any other participant either —
        // i.e. tapping the row "rescues" them. Selecting the row
        // resolves the orphan state (it's now assigned to this
        // participant) and the ring goes away.
        let isOrphan = !isSelected && globallyOrphanedItemIDs.contains(item.id)
        let strokeColor: Color = {
            if isSelected { return .clear }
            if isOrphan { return AppColors.warning }
            return AppColors.textQuaternary.opacity(0.3)
        }()
        let strokeWidth: CGFloat = isOrphan ? 1.5 : 1

        let claimants = otherClaimants[item.id] ?? []

        // Row is wrapped in an HStack + `.onTapGesture` (not an outer
        // Button) so a nested Button — the avatar-stack — can carve
        // out its own hit area without fighting an enclosing Button's
        // gesture. SwiftUI gives the inner Button priority on its own
        // bounds; taps elsewhere on the row fall through to the
        // outer tap gesture and toggle selection.
        return HStack(spacing: AppSpacing.md) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundColor(
                    isSelected
                        ? .accentColor
                        : (isOrphan ? AppColors.warning : AppColors.textTertiary)
                )

            Text(item.name)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)

            Spacer(minLength: 8)

            // Trailing column: mini avatar pile of OTHER participants
            // already claiming this row on top, then the amount.
            // Previously the pile sat inline between the name and
            // the amount and crowded long item names; stacking it
            // above the amount keeps the row's primary read
            // (name → amount) uninterrupted while still exposing
            // "who else picked this" inside the bounds of the right
            // column. Tap on the pile still opens the claimants
            // detail sheet.
            VStack(alignment: .trailing, spacing: 4) {
                if !claimants.isEmpty {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        claimantsSheetItem = item
                    } label: {
                        OverlappingAvatarStack(
                            participants: claimants.map { p in
                                OverlappingAvatarStack.Participant(
                                    id: p.isMe ? UserIDService.currentID() : p.id,
                                    isConnected: p.isConnected
                                )
                            },
                            avatarSize: 18,
                            strokeColor: isSelected
                                ? AppColors.backgroundElevated
                                : AppColors.backgroundPrimary,
                            strokeWidth: 1.5,
                            maxVisible: 3
                        )
                    }
                    .buttonStyle(.plain)
                }

                ReceiptItemAmountText(
                    amount: item.lineTotal,
                    currency: currency
                )
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(isSelected ? AppColors.backgroundElevated : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .stroke(strokeColor, lineWidth: strokeWidth)
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
        .onTapGesture {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            if isSelected {
                selection.remove(item.id)
            } else {
                selection.insert(item.id)
            }
        }
    }

    private var continueButton: some View {
        // Disabled + dimmed when items are still floating — orange
        // row strokes tell the user exactly which items need
        // attention, so a separate explanatory banner is unnecessary
        // chrome. The user either taps the highlighted rows here or
        // swipes back to assign them upstream.
        Button {
            onContinue()
        } label: {
            Text(selectedCount == 0 ? "Skip this person" : "Continue")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(
                    hasUnresolvedOrphans
                        ? AppColors.textTertiary
                        : AppColors.textPrimary
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
                .background(AppColors.backgroundElevated)
                .cornerRadius(AppRadius.xlarge)
        }
        .buttonStyle(.plain)
        .disabled(hasUnresolvedOrphans)
    }
}

// MARK: - Claimants sheet

/// Half-sheet that reveals who else has already picked a given receipt
/// row. Reached by tapping the small avatar pile on an item row in
/// `ItemAssignmentStep`. Read-only — the user dismisses by swiping
/// down; assignment changes happen back on the assignment list itself.
private struct ItemClaimantsSheet: View {
    let item: ReceiptItem
    let claimants: [ItemAssignmentParticipant]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                // Lead with the item name — it's what the user
                // tapped on and the variable info on this sheet. The
                // "Also assigned to" descriptor demotes to a subtitle
                // since the rest of the sheet (the avatar list below)
                // already conveys the "this row has other claimants"
                // semantics. "Also" reads better than "Already" — the
                // current participant is in the middle of claiming the
                // item too, so the others aren't "before" them, they're
                // simply "additional".
                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Also assigned to")
                        .font(AppFonts.bodySmallRegular)
                        .foregroundColor(AppColors.textTertiary)
                }

                VStack(spacing: AppSpacing.xs) {
                    ForEach(claimants) { person in
                        HStack(spacing: AppSpacing.md) {
                            PixelCatView(
                                id: person.isMe ? UserIDService.currentID() : person.id,
                                size: 36,
                                blackAndWhite: !person.isConnected
                            )
                            .clipShape(Circle())

                            Text(person.isMe ? "You" : person.name)
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, AppSpacing.rowVertical)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.large)
                                .fill(AppColors.backgroundElevated)
                        )
                    }
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            // Same 48pt top breathing room used by the other
            // orchestrator-style sheets (FriendPickerContent header,
            // ModePickerStep, ItemAssignmentReview) — keeps the title
            // far enough below the drag indicator that they don't
            // visually collide.
            .padding(.top, 48)
            .padding(.bottom, AppSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.backgroundPrimary)
    }
}

// MARK: - Review screen

/// Final step in the walk-through — shows what each participant ends
/// up paying once `SplitShareCalculator` distributes proportional
/// charges. The user gets one last chance to step back and tweak
/// before tapping Save.
struct ItemAssignmentReview: View {
    let items: [ReceiptItem]
    let participants: [ItemAssignmentParticipant]
    let selections: [String: Set<UUID>]
    let currency: String
    let onSave: () -> Void

    /// Set when the user taps "See breakdown" — drives the proportional-
    /// charges detail sheet. `nil` = sheet hidden.
    @State private var showProportionalBreakdown: Bool = false

    /// Materialise the selections back into items + run the calculator.
    /// Done up-front (not as @State) so SwiftUI re-derives on any
    /// upstream change without explicit invalidation.
    private var computedShares: [String: Double] {
        return SplitShareCalculator.compute(
            items: itemsWithAssignments,
            participants: Set(participants.map(\.id))
        )
    }

    /// Items projected with the current per-participant selections —
    /// shared between the share calculator above and the proportional
    /// breakdown sheet below so both reason about the same assignment
    /// snapshot.
    private var itemsWithAssignments: [ReceiptItem] {
        items.map { item in
            guard item.kind == .item else { return item }
            let assignees = participants
                .filter { selections[$0.id]?.contains(item.id) == true }
                .map(\.id)
            var copy = item
            copy.assignedParticipantIDs = assignees
            return copy
        }
    }

    /// Receipt rows that get distributed proportionally instead of
    /// assigned to individuals — fees, taxes, tips, and discounts.
    /// When empty, the subtitle + "See breakdown" affordance both
    /// disappear from the header: every line on this receipt is
    /// directly assigned, so there's nothing proportional to explain.
    private var proportionalItems: [ReceiptItem] {
        items.filter { $0.kind != .item }
    }

    private var grandTotal: Double {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headerSummary
                    perPersonList
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                // Match the 48pt top breathing room used by
                // `FriendPickerContent`'s header rows so the back
                // button → title gap is consistent across every
                // step of the orchestrator (Who pays, Who to split
                // with, Settle-up payer/recipient, etc).
                .padding(.top, 48)
                .padding(.bottom, AppSpacing.xxl)
            }

            saveButton
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.md)
        }
        .sheet(isPresented: $showProportionalBreakdown) {
            ProportionalChargesSheet(
                items: itemsWithAssignments,
                currency: currency
            )
        }
    }

    // MARK: - Sub-views

    private var headerSummary: some View {
        // Title + subtitle vocabulary mirrors the rest of the
        // orchestrator's flow screens (FriendPickerContent's header
        // on Who-pays / Who-to-split-with / etc.): 32pt bold title
        // for the same step-anchor weight, `textTertiary` subtitle
        // for the same dimmed-supporting role.
        //
        // The subtitle + inline "See breakdown" link render only
        // when there's something proportional to explain — receipts
        // with only regular items are fully described by the direct
        // assignments below, so the boilerplate "additional adjustments
        // are distributed proportionally" line would be misleading
        // there (it implies the link would surface something the user
        // can't actually see).
        VStack(alignment: .leading, spacing: 6) {
            Text("Review the split")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            if !proportionalItems.isEmpty {
                // The "See breakdown" link is concatenated INTO the
                // subtitle paragraph (rather than landing on its own
                // row underneath) so the affordance reads as the
                // natural end of the sentence — "...each person's
                // items. See breakdown ›". Swift's `Text + Text`
                // concatenation lets the chevron and the link both
                // sit inline; the surrounding Button hands the whole
                // block as one tap target.
                Button {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    showProportionalBreakdown = true
                } label: {
                    (Text("Additional adjustments are distributed proportionally to each person's items. ")
                        .foregroundColor(AppColors.textTertiary)
                     + Text("See breakdown")
                        .foregroundColor(.accentColor)
                        .fontWeight(.medium))
                        .font(AppFonts.bodySmallRegular)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var perPersonList: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(participants) { participant in
                personRow(participant)
            }
        }
    }

    private func personRow(_ participant: ItemAssignmentParticipant) -> some View {
        let amount = computedShares[participant.id] ?? 0
        let itemCount = selections[participant.id]?.count ?? 0
        let percent = grandTotal > 0.001 ? Int((amount / grandTotal * 100).rounded()) : 0

        return HStack(spacing: AppSpacing.md) {
            PixelCatView(
                id: participant.isMe ? UserIDService.currentID() : participant.id,
                size: 36,
                blackAndWhite: !participant.isConnected
            )
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(participant.isMe ? "You" : participant.name)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                Text("\(itemCount) \(itemCount == 1 ? "item" : "items") · \(percent)%")
                    .font(AppFonts.metaRegular)
                    .foregroundColor(AppColors.textTertiary)
            }

            Spacer(minLength: 8)

            ReceiptItemAmountText(amount: amount, currency: currency)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
    }

    private var saveButton: some View {
        Button {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onSave()
        } label: {
            Text("Confirm")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, AppSpacing.lg)
                .background(AppColors.backgroundElevated)
                .cornerRadius(AppRadius.xlarge)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Proportional charges sheet

/// Lightweight breakdown shown when the user taps "See breakdown" on
/// the Review step. Lists every fee / tax / tip / discount as one
/// row (kind icon + name + line total) so the user can see at a glance
/// what's being auto-distributed alongside their direct item picks.
/// The per-participant cut for each row used to live here too, but it
/// felt heavy for a glance-tier sheet — the calculator's pass-2
/// formula is simple enough that the user reads "proportional to my
/// items share" off the subtitle and doesn't need to verify each
/// person's exact split row-by-row.
///
/// Visually modelled on the other in-flow sheets (`ItemClaimantsSheet`):
/// no NavigationBar / Done toolbar, drag-to-dismiss via the indicator,
/// 48pt top breathing room, bold title + tertiary subtitle inside the
/// content.
private struct ProportionalChargesSheet: View {
    let items: [ReceiptItem]
    let currency: String

    private var proportionalItems: [ReceiptItem] {
        items.filter { $0.kind != .item }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                chargesList
                Spacer().frame(height: 40)
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            // Same 48pt top breathing room used by the other
            // orchestrator-style sheets (`ItemClaimantsSheet`,
            // `FriendPickerContent`'s header, `ModePickerStep`).
            .padding(.top, 48)
            .padding(.bottom, AppSpacing.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppColors.backgroundPrimary)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Additional adjustments")
                .font(.system(size: 28, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text("Distributed proportionally to each person's items.")
                .font(AppFonts.bodySmallRegular)
                .foregroundColor(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var chargesList: some View {
        VStack(spacing: AppSpacing.xs) {
            ForEach(proportionalItems) { item in
                chargeRow(item)
            }
        }
    }

    private func chargeRow(_ item: ReceiptItem) -> some View {
        HStack(spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: item.kind)
            Text(item.name)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            ReceiptItemAmountText(
                amount: item.lineTotal,
                currency: currency,
                isDiscount: item.lineTotal < 0
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
    }
}

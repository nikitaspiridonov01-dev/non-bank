import SwiftUI

// MARK: - Who Are You Picker

/// Shown when an incoming share-transaction has more than one PHANTOM
/// candidate on the sharer's side and we can't infer which one is the
/// receiver. The user taps a row to identify themselves; the
/// coordinator commits the imported transaction with that participant
/// flipped to "you".
///
/// ## Recipient-identity safety
/// The picker only ever lists the participants in `candidateIndices` —
/// the phantom (`cn != true`) participants computed by
/// `ShareIntentClassifier`. A connected friend (`cn == true`) is NEVER
/// shown, because the receiver can't legitimately be one (they'd have
/// matched by their real userID and skipped the picker). This prevents
/// the receiver from mis-picking an already-paired person, which would
/// corrupt the sharer's synced data. Rows map back to the ORIGINAL
/// `payload.f[]` index before `onPick` fires.
///
/// ## What each row shows (so the receiver picks the right person)
/// - **byItems** (`payload.sm == "byItems"`): compact receipt-item rows
///   (kind icon + name + price) for the items assigned to that
///   participant, reusing the canonical `ReceiptItemKindIcon` /
///   `ReceiptItemAmountText` components so they match the Receipt-items
///   surfaces. Items are pulled from the encrypted share-items channel
///   (pre-fetched via `fetchItems`). If items can't be fetched, we fall
///   back to the share amount.
/// - **non-byItems**: the participant's share amount + currency — i.e.
///   how the split is divided.
///
/// Also reused as the update-confirmation step: when the receiver
/// already has a transaction with the same `syncID` and accepts the
/// update prompt, this view comes up with `isForUpdate: true`. On that
/// path `candidateIndices` is empty, which we treat as "show all
/// participants" — the receiver owns a local copy already, so a mis-pick
/// there can't corrupt the sharer's data the way a fresh create can.
struct WhoAreYouPickerView: View {
    let payload: SharedTransactionPayload
    let isForUpdate: Bool
    /// Indices into `payload.f[]` of the participants the receiver may
    /// legitimately be (the phantoms). EMPTY = "no filter, show all" —
    /// used on the update re-show path (see `confirmedUpdate`).
    let candidateIndices: [Int]
    /// Pre-fetches the decrypted share-items (already in flight from the
    /// coordinator). `nil` → no items available, rows fall back to the
    /// share amount. Only awaited for `byItems` splits.
    var fetchItems: () async -> [ReceiptItem]?
    /// Called with the picked participant index (mapped back to the
    /// ORIGINAL `payload.f[]` index). The coordinator handles the
    /// actual store mutations.
    var onPick: (Int) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// Receipt items grouped by the participant ID they're assigned to,
    /// in the SHARER's id-space (sentinel `__me__` = sharer, friend ids
    /// as the sharer knows them). Loaded once on appear for byItems
    /// splits. `nil` until loaded / when no items are available.
    @State private var itemsByParticipantID: [String: [ReceiptItem]]?

    /// Is this a receipt (byItems) split? Drives whether we show item
    /// names vs. the share amount.
    private var isByItems: Bool {
        payload.sm == SplitMode.byItems.rawValue
    }

    /// The rows to render, as ORIGINAL `payload.f[]` indices. When
    /// `candidateIndices` is non-empty we show exactly those (the
    /// phantom candidates); when empty (update re-show) we show all.
    private var rowIndices: [Int] {
        candidateIndices.isEmpty ? Array(payload.f.indices) : candidateIndices
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headerCard

                    Text("Who are you in this transaction?")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, AppSpacing.xl)
                        .padding(.top, AppSpacing.sm)

                    Text(subtitleText)
                        .font(AppFonts.metaRegular)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.horizontal, AppSpacing.xl)

                    VStack(spacing: AppSpacing.sm) {
                        ForEach(rowIndices, id: \.self) { index in
                            if payload.f.indices.contains(index) {
                                Button {
                                    onPick(index)
                                    dismiss()
                                } label: {
                                    participantRow(payload.f[index])
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.top, AppSpacing.xs)

                    Spacer().frame(height: 32)
                }
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle(isForUpdate ? "Update transaction" : "Imported split")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
            // Pre-fetch + group the encrypted receipt items for byItems
            // splits so each row can show the items assigned to that
            // person BEFORE the receiver taps. Non-byItems splits skip
            // the fetch entirely (rows show the share amount instead).
            .task {
                guard isByItems else { return }
                let items = await fetchItems()
                guard let items, !items.isEmpty else { return }
                itemsByParticipantID = Dictionary(
                    grouping: items.flatMap { item in
                        item.assignedParticipantIDs.map { ($0, item) }
                    },
                    by: { $0.0 }
                ).mapValues { $0.map(\.1) }
            }
        }
    }

    /// Helper copy under the question. Spells out the "tap your name"
    /// guidance and, for byItems, hints that the items help identify.
    private var subtitleText: String {
        if isByItems {
            return "Tap your name. The items below show what each person ordered."
        }
        return "Tap your name. The other people stay as they were."
    }

    // MARK: - Header

    @ViewBuilder
    private var headerCard: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: 10) {
                Text(payload.ce)
                    .font(AppFonts.emojiLarge)
                Text(payload.t)
                    .font(AppFonts.subhead)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(AppFonts.captionSmallStrong)
                    .foregroundColor(AppColors.textSecondary)
                Text("From a friend")
                    .font(AppFonts.metaRegular)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
                Text(formatAmount(payload.ta))
                    .font(.system(size: 18, weight: .bold))
                Text(payload.c)
                    .font(AppFonts.metaRegular)
                    .foregroundColor(AppColors.textSecondary)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, AppSpacing.lg)
    }

    // MARK: - Participant row

    @ViewBuilder
    private func participantRow(_ participant: SharedTransactionPayload.Participant) -> some View {
        HStack(spacing: AppSpacing.md) {
            PixelCatView(id: participant.id, size: 40, blackAndWhite: false)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(participant.n)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                // What to identify by: the items this person ordered
                // (byItems, when we have them) or their share amount.
                composition(for: participant)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(AppFonts.footnote)
                .foregroundColor(AppColors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
    }

    /// The "how this person's split is composed" line under their name.
    /// For byItems with fetched items → compact receipt-item rows (kind
    /// icon + name + price), reusing the canonical components so they
    /// match the Receipt-items / Breakdown surfaces. Otherwise (or if
    /// items unavailable) → their share amount.
    @ViewBuilder
    private func composition(for participant: SharedTransactionPayload.Participant) -> some View {
        if isByItems, let items = assignedItems(for: participant), !items.isEmpty {
            // Plain rows — the candidate row (`participantRow`) is already
            // a card, so these carry no nested glass / background. No
            // avatar pile either: each picker row is scoped to ONE person,
            // so "who shares this" would be redundant here.
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                ForEach(items) { item in
                    HStack(spacing: AppSpacing.xs) {
                        ReceiptItemKindIcon(kind: item.kind, size: 11)
                        Text(item.name)
                            .font(.caption)
                            .foregroundColor(AppColors.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 6)
                        ReceiptItemAmountText(
                            amount: item.lineTotal,
                            currency: payload.c,
                            isDiscount: item.kind == .discount
                        )
                    }
                }
            }
        } else {
            // Fallback: share amount (the default "how the split is
            // divided" view, and the graceful degrade when items can't
            // be fetched for a byItems split).
            HStack(spacing: AppSpacing.xs) {
                Text("Share:")
                    .font(.caption)
                    .foregroundColor(AppColors.textTertiary)
                Text(formatAmount(participant.sh))
                    .font(.caption.monospacedDigit())
                    .foregroundColor(AppColors.textSecondary)
                Text(payload.c)
                    .font(.caption)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }

    /// Receipt items assigned to `participant` from the share-items
    /// channel. Items are keyed in the SHARER's id-space, so we look them
    /// up by the participant's payload id directly (the sentinel `__me__`
    /// belongs to the sharer and never to a candidate, so no flip is
    /// needed here). Blank-named items are filtered out so they don't
    /// render an empty row. `nil` when no items were fetched.
    private func assignedItems(for participant: SharedTransactionPayload.Participant) -> [ReceiptItem]? {
        guard let grouped = itemsByParticipantID else { return nil }
        return grouped[participant.id]?
            .filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    // MARK: - Formatting

    private func formatAmount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }
}

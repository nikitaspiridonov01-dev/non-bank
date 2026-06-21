import SwiftUI

// MARK: - Who Are You Picker

/// Shown when an incoming share-transaction has more than one PHANTOM
/// candidate on the sharer's side and we can't infer which one is the
/// receiver. The user taps a row to open that person's detail, then
/// Confirm identifies themselves; the coordinator commits the imported
/// transaction with that participant flipped to "you".
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
/// ## What each row shows
/// Avatar (GRAYSCALE — these candidates are unconfirmed, the gray cat is
/// the "not paired yet" cue), the participant's name, the item count for
/// a receipt (byItems) split, and that person's total. Tapping a row
/// pushes a per-person detail (their items + total) where Confirm
/// finalizes "I am this person" and saves. The sharer — whose device IS
/// confirmed — appears in the header with a COLORED avatar + their name.
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

    /// Is this a receipt (byItems) split? Drives whether we show an item
    /// count and the per-item detail.
    private var isByItems: Bool {
        payload.sm == SplitMode.byItems.rawValue
    }

    /// The rows to render, as ORIGINAL `payload.f[]` indices. When
    /// `candidateIndices` is non-empty we show exactly those (the
    /// phantom candidates); when empty (update re-show) we show all.
    private var rowIndices: [Int] {
        candidateIndices.isEmpty ? Array(payload.f.indices) : candidateIndices
    }

    /// Sharer's display name, falling back to "Friend" when unset —
    /// mirrors `ReceivedTransactionMapper`'s fallback.
    private var sharerName: String {
        (payload.sn?.isEmpty == false) ? payload.sn! : "Friend"
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

                    VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                        Text(subtitleText)
                            .font(AppFonts.metaRegular)
                            .foregroundColor(AppColors.textSecondary)
                        // Make it explicit that the labels in the list were
                        // chosen by whoever shared the split — they're not
                        // self-assigned, so a stranger's name is expected.
                        Text("These names were set by \(sharerName).")
                            .font(AppFonts.metaRegular)
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .padding(.horizontal, AppSpacing.xl)

                    VStack(spacing: AppSpacing.sm) {
                        ForEach(rowIndices, id: \.self) { index in
                            if payload.f.indices.contains(index) {
                                NavigationLink(value: index) {
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
            // Lazy destination so the detail reads the items that finished
            // loading AFTER the rows were first laid out.
            .navigationDestination(for: Int.self) { index in
                if payload.f.indices.contains(index) {
                    detailView(for: index)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
            }
            // Pre-fetch + group the encrypted receipt items for byItems
            // splits so the row counts and the per-person detail are ready.
            // Non-byItems splits skip the fetch entirely.
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

    /// Helper copy under the question.
    private var subtitleText: String {
        if isByItems {
            return "Tap your name to see what that person ordered, then confirm."
        }
        return "Tap your name to confirm. The other people stay as they were."
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
            HStack(spacing: 8) {
                // The sharer's device is confirmed, so their avatar stays in
                // COLOR and we show their name instead of a generic
                // "From a friend".
                PixelCatView(id: payload.s, size: 22, blackAndWhite: false)
                    .clipShape(Circle())
                Text(sharerName)
                    .font(AppFonts.metaRegular)
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                amountLabel(payload.ta, size: 18, weight: .bold)
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

    /// Amount + currency sharing a text baseline. They used to sit directly
    /// in a center-aligned HStack with very different font sizes, so the
    /// small currency code floated at the vertical centre of the big bold
    /// amount instead of resting on its baseline.
    @ViewBuilder
    private func amountLabel(_ value: Double, size: CGFloat, weight: Font.Weight) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(formatAmount(value))
                .font(.system(size: size, weight: weight))
            Text(payload.c)
                .font(AppFonts.metaRegular)
                .foregroundColor(AppColors.textSecondary)
        }
    }

    // MARK: - Participant row

    @ViewBuilder
    private func participantRow(_ participant: SharedTransactionPayload.Participant) -> some View {
        HStack(spacing: AppSpacing.md) {
            // Grayscale: these candidates are unconfirmed (the receiver hasn't
            // paired them). A confirmed friend (cn == true) would keep colour,
            // but the picker never lists confirmed friends anyway.
            PixelCatView(id: participant.id, size: 40, blackAndWhite: participant.cn != true)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(participant.n)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)
                if let count = receiptItemCount(for: participant) {
                    Text("\(count) item\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(AppColors.textTertiary)
                }
            }
            Spacer(minLength: 8)
            amountLabel(participant.sh, size: 15, weight: .semibold)
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

    // MARK: - Detail

    @ViewBuilder
    private func detailView(for index: Int) -> some View {
        let participant = payload.f[index]
        ImportParticipantDetailView(
            participantName: participant.n,
            participantID: participant.id,
            isConfirmed: participant.cn == true,
            items: assignedItems(for: participant) ?? [],
            total: participant.sh,
            currency: payload.c,
            onConfirm: {
                // Finalize "I am this participant" + save the import. The
                // coordinator's state change tears the sheet down, but we also
                // dismiss the picker explicitly so it closes instantly.
                onPick(index)
                dismiss()
            }
        )
    }

    // MARK: - Items lookup

    /// Item count to show on a row, or nil to hide it (non-receipt split, or
    /// no items fetched yet).
    private func receiptItemCount(for participant: SharedTransactionPayload.Participant) -> Int? {
        guard isByItems, let items = assignedItems(for: participant), !items.isEmpty else { return nil }
        return items.count
    }

    /// Receipt items assigned to `participant` from the share-items channel.
    /// Items are keyed in the SHARER's id-space, so we look them up by the
    /// participant's payload id directly. Blank-named items are filtered out.
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

// MARK: - Import Participant Detail

/// Pushed when the receiver taps a candidate on `WhoAreYouPickerView`.
/// Shows that person's receipt items + total (mirrors the split-flow
/// "{name}'s items" screen) and, in the toolbar, **Cancel** (back to the
/// list, nothing committed) + **Confirm** (finalize "I am this person" and
/// save the import).
private struct ImportParticipantDetailView: View {
    let participantName: String
    let participantID: String
    let isConfirmed: Bool
    let items: [ReceiptItem]
    let total: Double
    let currency: String
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(spacing: AppSpacing.lg) {
                VStack(spacing: AppSpacing.sm) {
                    PixelCatView(id: participantID, size: 64, blackAndWhite: !isConfirmed)
                        .clipShape(Circle())
                    Text(participantName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    Text("Confirm this is you to import the split.")
                        .font(AppFonts.metaRegular)
                        .foregroundColor(AppColors.textTertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.top, AppSpacing.lg)
                .padding(.horizontal, AppSpacing.xl)

                if !items.isEmpty {
                    VStack(spacing: AppSpacing.xs) {
                        ForEach(items) { item in
                            HStack(spacing: AppSpacing.sm) {
                                ReceiptItemKindIcon(kind: item.kind, size: 13)
                                Text(item.name)
                                    .font(.subheadline)
                                    .foregroundColor(AppColors.textPrimary)
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                ReceiptItemAmountText(
                                    amount: item.lineTotal,
                                    currency: currency,
                                    isDiscount: item.kind == .discount
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
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                }

                // Authoritative per-person total (the share the sharer set).
                HStack(alignment: .firstTextBaseline) {
                    Text("Total")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(AppColors.textPrimary)
                    Spacer()
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(formatAmount(total))
                            .font(.system(size: 18, weight: .bold))
                        Text(currency)
                            .font(AppFonts.metaRegular)
                            .foregroundColor(AppColors.textSecondary)
                    }
                }
                .padding(.horizontal, AppSpacing.pageHorizontal + 14)

                Spacer().frame(height: 24)
            }
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle(participantName)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm") { onConfirm() }
                    .fontWeight(.semibold)
            }
        }
    }

    private func formatAmount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }
}

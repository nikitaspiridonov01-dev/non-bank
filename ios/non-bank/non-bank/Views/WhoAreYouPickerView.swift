import SwiftUI

// MARK: - Who Are You Picker

/// Shown when an incoming share-transaction has more than one
/// participant on the sharer's side and we can't infer which one is the
/// receiver. The user taps a row to identify themselves; the
/// coordinator commits the imported transaction with that participant
/// flipped to "you".
///
/// Also reused as the update-confirmation step: when the receiver
/// already has a transaction with the same `syncID` and accepts the
/// update prompt, this view comes up with `isForUpdate: true` so the
/// title makes the destructive nature obvious.
struct WhoAreYouPickerView: View {
    let payload: SharedTransactionPayload
    let isForUpdate: Bool
    /// Called with the picked participant index. The coordinator handles
    /// the actual store mutations.
    var onPick: (Int) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.lg) {
                    headerCard

                    Text("Who are you in this transaction?")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(.horizontal, AppSpacing.xl)
                        .padding(.top, AppSpacing.sm)

                    Text("Tap your name. The other people stay as they were.")
                        .font(AppFonts.metaRegular)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, AppSpacing.xl)

                    VStack(spacing: AppSpacing.sm) {
                        ForEach(Array(payload.f.enumerated()), id: \.offset) { index, participant in
                            Button {
                                onPick(index)
                                dismiss()
                            } label: {
                                participantRow(participant)
                            }
                            .buttonStyle(.plain)
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
        }
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
                    .foregroundColor(.secondary)
                Text("From a friend")
                    .font(AppFonts.metaRegular)
                    .foregroundColor(.secondary)
                Spacer()
                Text(formatAmount(payload.ta))
                    .font(.system(size: 18, weight: .bold))
                Text(payload.c)
                    .font(AppFonts.metaRegular)
                    .foregroundColor(.secondary)
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

    // MARK: - Formatting

    private func formatAmount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }
}

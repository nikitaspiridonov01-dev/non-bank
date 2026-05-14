import SwiftUI

/// Bottom-sheet picker showing the three live split modes (`evenly`,
/// `byItems`, `byAmount`). Used both as the first-time mode selector
/// (after `who to split with`) and as the change-mode entry from the
/// chip in the create modal.
///
/// Picking `byItems` without a scanned receipt is allowed — the caller
/// is expected to chain into the scan flow on `onSelect`. The row shows
/// a small subtitle hint in that state so the consequence is visible
/// before the tap.
struct SplitModePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMode: SplitMode?
    var friendCount: Int = 1
    /// True when the create flow already has a scanned receipt with more
    /// than one product line. When false, picking `.byItems` triggers
    /// the scan flow rather than going straight to assignment — the row
    /// subtitle reflects this so the user knows what happens.
    var hasUsableReceipt: Bool = false
    var onSelect: (() -> Void)? = nil

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ForEach(SplitMode.allCases) { mode in
                    modeButton(mode: mode)
                }
                Spacer()
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.sm)
            .navigationTitle("Split Mode")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func displayLabel(for mode: SplitMode) -> String {
        if mode == .evenly {
            return friendCount == 1 ? "50/50" : "Evenly"
        }
        return mode.displayLabel
    }

    private func helpText(for mode: SplitMode) -> String {
        if mode == .evenly {
            return "Split evenly between people"
        }
        if mode == .byItems && !hasUsableReceipt {
            return "Scan a receipt to assign items"
        }
        return mode.helpText
    }

    private func modeButton(mode: SplitMode) -> some View {
        Button {
            selectedMode = mode
            onSelect?()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                SplitModeIcon(mode: mode, size: 36)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(displayLabel(for: mode))
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                    Text(helpText(for: mode))
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                }

                Spacer()

                if selectedMode == mode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppFonts.iconLarge)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, AppSpacing.rowVertical)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

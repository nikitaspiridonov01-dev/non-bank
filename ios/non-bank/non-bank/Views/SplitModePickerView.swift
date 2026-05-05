import SwiftUI

struct SplitModePickerView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var selectedMode: SplitMode?
    var friendCount: Int = 1
    var youIncluded: Bool = true
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

    private func isModeEnabled(_ mode: SplitMode) -> Bool {
        mode == .fiftyFifty
    }

    private func displayLabel(for mode: SplitMode) -> String {
        if mode == .fiftyFifty {
            return friendCount == 1 ? "50/50" : "Evenly"
        }
        return mode.displayLabel
    }

    private func helpText(for mode: SplitMode) -> String {
        if mode == .fiftyFifty {
            return "Split evenly between people"
        }
        return mode.helpText
    }

    private func modeButton(mode: SplitMode) -> some View {
        let enabled = isModeEnabled(mode)
        return Button {
            selectedMode = mode
            onSelect?()
            dismiss()
        } label: {
            HStack(spacing: 14) {
                SplitModeIcon(mode: mode, size: 36)
                    .opacity(enabled ? 1 : 0.4)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    HStack(spacing: 6) {
                        Text(displayLabel(for: mode))
                            .font(AppFonts.labelPrimary)
                            .foregroundColor(enabled ? AppColors.textPrimary : AppColors.textDisabled)
                        if !enabled {
                            Text("Soon")
                                .font(AppFonts.badgeLabel)
                                .foregroundColor(AppColors.textDisabled)
                                .padding(.horizontal, 6)
                                .padding(.vertical, AppSpacing.xxs)
                                .background(AppColors.backgroundElevated)
                                .clipShape(Capsule())
                        }
                    }
                    Text(helpText(for: mode))
                        .font(AppFonts.rowDescription)
                        .foregroundColor(enabled ? AppColors.textTertiary : AppColors.textDisabled)
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
        .disabled(!enabled)
    }
}

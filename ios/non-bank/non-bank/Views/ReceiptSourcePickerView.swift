import SwiftUI

/// "Scan a receipt" source picker — replaces the legacy
/// `.confirmationDialog` system alert. Visually consistent with the
/// other orchestrator step screens (`ModePickerStep`,
/// `WhoPaidPickerView`): 32pt bold title, two icon + label + help-text
/// rows the user taps to advance.
///
/// Two consumers:
/// - The byItems-without-receipt path inside `TransactionModeFlowSheet`
///   pushes this as a step in its NavigationStack
///   (`wrapInNavigationStack: false`). Cancel routing is handled by the
///   orchestrator's outer toolbar.
/// - The toolbar scan button on `CreateTransactionModal` (amount = 0)
///   presents it as a sheet (`wrapInNavigationStack: true`). The
///   internal NavigationStack supplies the Cancel toolbar item.
struct ReceiptSourcePickerView: View {
    /// When true, wraps the body in its own `NavigationStack` and
    /// surfaces a Cancel toolbar item that closes via the sheet's
    /// dismiss action. Use `false` to push this view inside an
    /// existing NavigationStack (e.g. the orchestrator).
    let wrapInNavigationStack: Bool
    let onPickCamera: () -> Void
    let onPickLibrary: () -> Void
    /// Called when the user taps Cancel in standalone sheet mode.
    /// Ignored when `wrapInNavigationStack` is false — embedded mode
    /// relies on the parent's toolbar for cancellation routing.
    var onCancel: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if wrapInNavigationStack {
            NavigationStack {
                content
                    .navigationTitle("")
                    .toolbarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                onCancel()
                                dismiss()
                            }
                        }
                    }
            }
        } else {
            content
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, AppSpacing.xxl)
                VStack(spacing: AppSpacing.xs) {
                    sourceRow(
                        icon: "camera.fill",
                        title: "Take photo",
                        helper: "Snap a paper receipt with your camera",
                        action: onPickCamera
                    )
                    sourceRow(
                        icon: "photo.on.rectangle",
                        title: "Choose from library",
                        helper: "Pick a photo or screenshot from your library",
                        action: onPickLibrary
                    )
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            // Same 48pt back-button → title gap the other orchestrator
            // steps use (matches `ModePickerStep.body`).
            .padding(.top, 48)
        }
        .background(AppColors.backgroundPrimary)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scan a receipt")
                .font(.system(size: 32, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            Text("Receipts, screenshots of purchases or bank transactions — we'll read the items, totals, and discounts.")
                .font(AppFonts.bodySmallRegular)
                .foregroundColor(AppColors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceRow(
        icon: String,
        title: String,
        helper: String,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(AppColors.backgroundElevated)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(title)
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                    Text(helper)
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                }
                Spacer()
            }
            .padding(.vertical, AppSpacing.rowVertical)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

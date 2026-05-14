import SwiftUI

/// Pill showing "N items" — surfaces transactions that came from a scanned
/// receipt and lets the user drill into the line-item breakdown.
///
/// Three visual variants for different surfaces:
/// - `.rowBadge`: small caption-sized capsule for transaction list rows
/// - `.standard`: slightly larger but still secondary — for review headers
/// - `.categoryMatched`: same height/weight as the category pill in
///   `CreateTransactionModal`, used inline next to it
///
/// Hidden completely when `count == 0` so manually-entered transactions
/// stay visually clean.
struct ItemsBadgePill: View {
    enum Style {
        case rowBadge
        case standard
        case categoryMatched
    }

    let count: Int
    var style: Style = .standard
    var action: (() -> Void)? = nil

    var body: some View {
        if count > 0 {
            Group {
                if let action {
                    Button(action: action) { content }
                        .buttonStyle(.plain)
                } else {
                    content
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .rowBadge:
            rowBadgeContent
        case .standard:
            standardContent
        case .categoryMatched:
            categoryMatchedContent
        }
    }

    private var rowBadgeContent: some View {
        HStack(spacing: 4) {
            Image(systemName: "list.bullet")
                .font(.system(size: 9, weight: .semibold))
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.caption2.weight(.semibold))
        }
        .foregroundColor(AppColors.accentBold)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(AppColors.accent.opacity(0.15)))
    }

    private var standardContent: some View {
        HStack(spacing: 4) {
            Image(systemName: "list.bullet")
                .font(.system(size: 11, weight: .semibold))
            Text("\(count) \(count == 1 ? "item" : "items")")
                .font(.caption.weight(.semibold))
        }
        .foregroundColor(AppColors.accentBold)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(AppColors.accent.opacity(0.15)))
    }

    /// Matches the height + corner radius of the category pill in
    /// `CreateTransactionModal` (`vertical: AppSpacing.sm`, `cornerRadius:
    /// AppRadius.fab`, font weight `.medium`). Neutral colour palette
    /// (textPrimary on backgroundElevated) matches the sibling category
    /// chip exactly — same rhythm, same restraint, no accent fighting
    /// for attention with the amount keypad above.
    private var categoryMatchedContent: some View {
        HStack(spacing: 6) {
            Image(systemName: "list.bullet")
                .font(.system(size: 14, weight: .medium))
            Text("\(count)")
                .font(.system(size: 20, weight: .medium))
        }
        .foregroundColor(AppColors.textPrimary)
        .padding(.vertical, AppSpacing.sm)
        .padding(.horizontal, 14)
        .background(AppColors.backgroundElevated)
        .cornerRadius(AppRadius.fab)
    }
}

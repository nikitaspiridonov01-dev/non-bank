import SwiftUI

/// Loading placeholder shaped like a transaction row. Used in place of
/// the live list while `TransactionStore.hasLoadedOnce == false` so the
/// cold-launch path doesn't flash the empty state at the user while
/// SQLite is still fetching.
///
/// Layout mirrors `TransactionRowView`: a left emoji block, a stacked
/// title + subtitle on the left, and an amount block on the right. The
/// pulsing animation is the same `opacity 0.4 ↔ 1.0` rhythm used by
/// the splash crystal so cold-start animations across the app feel
/// like one piece.
struct SkeletonRow: View {
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Emoji slot
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.backgroundChip)
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.backgroundChip)
                    .frame(width: 140, height: 14)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.backgroundChip)
                    .frame(width: 84, height: 10)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.backgroundChip)
                    .frame(width: 80, height: 16)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.backgroundChip)
                    .frame(width: 50, height: 10)
            }
        }
        .padding(.vertical, AppSizes.rowVerticalPadding)
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .opacity(pulse ? 1.0 : 0.4)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Stacked placeholder list. Convenience around `SkeletonRow` so view
/// code doesn't repeat the date-section + N-row scaffolding.
struct SkeletonTransactionList: View {
    /// How many placeholder rows to render. Defaults to 5 — enough to
    /// fill the visible area on a Pro Max without scrolling, but
    /// without lingering placeholders below the fold once real data
    /// arrives.
    var rowCount: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            // Mock section header
            HStack {
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.backgroundChip)
                    .frame(width: 120, height: 10)
                    .opacity(0.5)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.xxl)
            .padding(.bottom, AppSpacing.sm)

            ForEach(0..<rowCount, id: \.self) { _ in
                SkeletonRow()
            }
        }
    }
}

import SwiftUI

/// Compact badge showing the user's split-debt status.
///
/// - "Settled" when no net debt exists.
/// - "You owe 5 238 923 USD 🐱🐱🐱" when the user owes money.
/// - "You lent 5 238 923 USD 🐱🐱🐱" when others owe the user.
///
/// Tappable — `onTap` is a placeholder for the future debt analytics screen.
struct DebtBadgeView: View {
    let summary: DebtSummary
    let currency: String
    let friends: [Friend]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            switch summary.status {
            case .settled:
                settledBadge
            case .youOwe(let amount):
                debtBadge(label: "You borrow", amount: amount)
            case .youLent(let amount):
                debtBadge(label: "You lent", amount: amount)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Settled

    private var settledBadge: some View {
        // Lavender pill — DebtBadge is the entry point into the Split
        // sub-app on Home, so it advertises that affiliation by
        // adopting the Split palette's chip fill instead of the
        // generic warm-cream `secondarySystemBackground`.
        Text("Settled")
            .font(AppFonts.metaText)
            .foregroundColor(AppColors.textTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .fill(AppColors.splitChipFill)
            )
    }

    // MARK: - You owe / You lent

    private func debtBadge(label: String, amount: Double) -> some View {
        HStack(alignment: .center, spacing: 3) {
            Text("\(label) ")
                .font(AppFonts.captionSmall)
                .foregroundColor(AppColors.textSecondary)
            +
            Text(formattedAmount(amount))
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
            +
            Text(" \(currency)")
                .font(AppFonts.captionSmall)
                .foregroundColor(AppColors.textSecondary)

            // Up to 3 overlapping pixel-cat avatars
            if !summary.topFriendIDs.isEmpty {
                avatarStack
            }
        }
        .padding(.horizontal, AppSpacing.sm)
        .padding(.vertical, 5)
        .background(
            // Same lavender pill as `settledBadge` — DebtBadge always
            // signals "Split sub-app entry" regardless of state.
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.splitChipFill)
        )
    }

    // MARK: - Overlapping Avatars

    private var avatarStack: some View {
        let ids = summary.topFriendIDs
        let avatarSize: CGFloat = 20
        let overlap: CGFloat = 10

        return HStack(spacing: -overlap) {
            ForEach(Array(ids.enumerated()), id: \.offset) { idx, friendID in
                // Colored when the friend is a real user (their ID
                // matches a real userID). Manual contacts stay B&W.
                // Same rule everywhere we render an avatar.
                let isConnected = friends.first(where: { $0.id == friendID })?.isConnected ?? false
                PixelCatView(id: friendID, size: avatarSize, blackAndWhite: !isConnected)
                    .clipShape(Circle())
                    .overlay(
                        Circle()
                            .stroke(AppColors.splitChipFill, lineWidth: 1.5)
                    )
                    .zIndex(Double(ids.count - idx))
            }
        }
    }

    // MARK: - Formatting

    private func formattedAmount(_ value: Double) -> String {
        if abs(value) < 1.0 {
            // Show with 2 decimals for sub-1 amounts (e.g. "0.50")
            return String(format: "%.2f", abs(value))
        }
        return NumberFormatting.integerPart(value)
    }
}

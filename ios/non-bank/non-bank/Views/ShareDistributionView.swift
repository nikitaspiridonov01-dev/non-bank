import SwiftUI

/// Read-only breakdown of how a purchase is split between participants.
/// Pushed from the orange "N people" section of the chart in `SplitBreakdownView`.
/// Each row shows a horizontal bar sized to the participant's share of the
/// total, plus the percentage and amount.
struct ShareDistributionView: View {
    let split: SplitInfo
    let currency: String

    @EnvironmentObject var friendStore: FriendStore

    private struct ShareRow {
        let name: String
        let avatarID: String
        let isMe: Bool
        let amount: Double
    }

    private var sharers: [ShareRow] {
        var result: [ShareRow] = []
        if split.myShare > 0.005 {
            result.append(ShareRow(
                name: "You",
                avatarID: UserIDService.currentID(),
                isMe: true,
                amount: split.myShare
            ))
        }
        for friend in split.friends where friend.share > 0.005 {
            let name = friendStore.friend(byID: friend.friendID)?.name ?? "Friend"
            result.append(ShareRow(
                name: name,
                avatarID: friend.friendID,
                isMe: false,
                amount: friend.share
            ))
        }
        return result
    }

    private var total: Double {
        max(sharers.reduce(0) { $0 + $1.amount }, 0.0001)
    }

    /// Mirrors the badge logic on the edit screen (50/50 for 2, Evenly otherwise).
    private var splitModeLabel: String {
        guard let mode = split.splitMode else { return "Evenly" }
        if mode == .fiftyFifty {
            return sharers.count == 2 ? "50/50" : "Evenly"
        }
        return mode.displayLabel
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.lg) {
                header
                list
                Spacer().frame(height: 40)
            }
            .padding(.top, AppSpacing.lg)
        }
        // Same Split-context background as PaidUpfrontView — keeps
        // the lavender / pink atmosphere through every push of the
        // debt drilldown.
        .background(AppColors.splitBackgroundTint)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: 6) {
                // Split-themed pill ("50/50", "custom", etc.) — was
                // warm `backgroundChip` cream which clashed with the
                // lavender page tint.
                Text(splitModeLabel)
                    .font(AppFonts.labelSmall)
                    .foregroundColor(AppColors.textPrimary)
                    .padding(.horizontal, AppSpacing.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(AppColors.splitChipFill))
                Text("between \(sharers.count) \(sharers.count == 1 ? "person" : "people")")
                    .font(AppFonts.heading)
                    .foregroundColor(AppColors.textPrimary)
            }
            Text("Each person's share of the purchase.")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if sharers.isEmpty {
            Text("No participants")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(spacing: AppSpacing.md) {
                ForEach(Array(sharers.enumerated()), id: \.offset) { _, sharer in
                    row(sharer)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func row(_ sharer: ShareRow) -> some View {
        let fraction = sharer.amount / total
        let percent = Int((fraction * 100).rounded())

        return VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.md) {
                PixelCatView(id: sharer.avatarID, size: 32, blackAndWhite: !sharer.isMe)
                    .clipShape(Circle())

                Text(sharer.name)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text("\(percent)%")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
                    .monospacedDigit()

                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text(NumberFormatting.integerPart(sharer.amount))
                        .font(AppFonts.rowAmountInteger)
                        .foregroundColor(AppColors.textPrimary)
                    Text(NumberFormatting.decimalPartIfAny(sharer.amount))
                        .font(AppFonts.rowAmountCurrency)
                        .foregroundColor(AppColors.textSecondary)
                    Text(currency)
                        .font(AppFonts.rowAmountCurrency)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.leading, 3)
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            bar(fraction: fraction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        // Split-themed card fill — replaces warm `backgroundElevated`
        // which clashed with the lavender Split atmosphere.
        .background(AppColors.splitCardFill)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
    }

    /// Grayscale track + fill bar. Non-colored per spec — shape alone conveys
    /// the proportion, so no need to introduce a color legend here.
    private func bar(fraction: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Track also picks up the Split chip fill so the
                // bar doesn't borrow warm cream against the lavender card.
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.splitChipFill)
                RoundedRectangle(cornerRadius: 4)
                    .fill(AppColors.splitAccent)
                    .frame(width: max(geo.size.width * fraction, 3))
            }
        }
        .frame(height: 8)
    }
}

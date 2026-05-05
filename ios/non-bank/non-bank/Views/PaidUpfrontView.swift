import SwiftUI

/// Read-only list of participants who paid upfront for a split transaction.
/// Pushed from the purple "Purchase paid upfront" section of the chart in
/// `SplitBreakdownView`. Visually modeled after the friend multi-select screen
/// used during transaction creation, but without the numpad, checkboxes or
/// other interactive elements.
struct PaidUpfrontView: View {
    let split: SplitInfo
    let currency: String

    @EnvironmentObject var friendStore: FriendStore

    private struct Payer {
        let name: String
        let avatarID: String
        let isMe: Bool
        let amount: Double
    }

    private var payers: [Payer] {
        var result: [Payer] = []
        if split.paidByMe > 0.005 {
            result.append(Payer(
                name: "You",
                avatarID: UserIDService.currentID(),
                isMe: true,
                amount: split.paidByMe
            ))
        }
        for friend in split.friends where friend.paidAmount > 0.005 {
            let name = friendStore.friend(byID: friend.friendID)?.name ?? "Friend"
            result.append(Payer(
                name: name,
                avatarID: friend.friendID,
                isMe: false,
                amount: friend.paidAmount
            ))
        }
        return result
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
        .background(AppColors.backgroundPrimary)
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(NumberFormatting.integerPart(split.totalAmount))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                Text(NumberFormatting.decimalPartIfAny(split.totalAmount))
                    .font(.system(size: 22, weight: .medium))
                    .foregroundColor(AppColors.textSecondary)
                Text(currency)
                    .font(AppFonts.bodyLarge)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.leading, 3)
            }

            Text("\(payers.count) \(payers.count == 1 ? "person" : "people") paid upfront for the purchase.")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - List

    @ViewBuilder
    private var list: some View {
        if payers.isEmpty {
            Text("No one paid upfront")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
        } else {
            VStack(spacing: AppSpacing.sm) {
                ForEach(Array(payers.enumerated()), id: \.offset) { _, payer in
                    row(payer)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func row(_ payer: Payer) -> some View {
        HStack(spacing: 14) {
            PixelCatView(id: payer.avatarID, size: 44, blackAndWhite: !payer.isMe)

            Text(payer.name)
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: 8)

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(NumberFormatting.integerPart(payer.amount))
                    .font(AppFonts.rowAmountInteger)
                    .foregroundColor(AppColors.textPrimary)
                Text(NumberFormatting.decimalPartIfAny(payer.amount))
                    .font(AppFonts.rowAmountCurrency)
                    .foregroundColor(AppColors.textSecondary)
                Text(currency)
                    .font(AppFonts.rowAmountCurrency)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.leading, 3)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(AppColors.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
    }
}

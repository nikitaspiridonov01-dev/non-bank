import SwiftUI

/// Extended split breakdown shown in the transaction detail card when opened
/// from the debt/friend screens:
///  1) tappable two-tone formula chart (navigates to upfront-payers and shares)
///  2) simplified settlement summary
///
/// Hidden on the home screen — only rendered when `source.showsSplitBreakdown`.
struct SplitBreakdownView: View {
    let transaction: Transaction
    let split: SplitInfo
    let friendStore: FriendStore

    private var sharerCount: Int {
        (split.myShare > 0.005 ? 1 : 0)
            + split.friends.filter { $0.share > 0.005 }.count
    }

    private var settlement: PerTransactionSettlement {
        SplitDebtService.perTransactionSettlement(for: transaction)
    }

    /// Whether the user participates (paid or shares something) in this split.
    /// When false the settlement block is hidden — the user has nothing to
    /// settle up on their side.
    private var userIsInvolved: Bool {
        SplitDebtService.userPosition(in: transaction) != .notInvolved
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.xl) {
            formulaBlock
            if userIsInvolved {
                settlementBlock
            }
        }
    }

    // MARK: - Formula

    /// Colors are kept in sync with the ● markers in the legend below so it
    /// reads as one continuous formula (chart on top, legend under it).
    /// **Both sections live in the Split (purple) palette** — the
    /// people row used to be warm orange (`AppColors.accent`) which
    /// clashed with the lavender Split atmosphere. Now: top is soft
    /// lavender (`splitAccent`), bottom is a deeper violet so the two
    /// sections still read as distinct slices of the same family.
    private var purchaseSectionColor: Color {
        AppColors.splitAccent
    }

    private var peopleSectionColor: Color {
        // Deeper violet — same hue family as `splitAccent` but
        // ~25% darker so the people section reads as a heavier
        // counterpart to the lavender purchase section above.
        Color(red: 0.55, green: 0.40, blue: 0.75)
    }

    @ViewBuilder
    private var formulaBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            formulaChart
            formulaLegend
        }
    }

    /// Two-tone stacked chart. Each section is a `NavigationLink` — tapping
    /// the purple "Purchase paid upfront" section pushes the upfront-payers
    /// screen, tapping the orange "N people" section pushes the shares
    /// distribution screen.
    private var formulaChart: some View {
        VStack(spacing: 0) {
            NavigationLink {
                PaidUpfrontView(split: split, currency: transaction.currency)
                    .environmentObject(friendStore)
            } label: {
                purchaseSection
                    .clipShape(TopArchShape(archDepth: 8))
            }
            .buttonStyle(.plain)

            NavigationLink {
                ShareDistributionView(split: split, currency: transaction.currency)
                    .environmentObject(friendStore)
            } label: {
                peopleSection
                    .clipShape(BottomArchShape(archDepth: 8))
            }
            .buttonStyle(.plain)
        }
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
    }

    private var purchaseSection: some View {
        VStack(spacing: AppSpacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(NumberFormatting.integerPart(split.totalAmount))
                    .font(AppFonts.title)
                    .foregroundColor(.white)
                Text(NumberFormatting.decimalPartIfAny(split.totalAmount))
                    .font(AppFonts.subhead)
                    .foregroundColor(.white.opacity(0.85))
                Text(transaction.currency)
                    .font(AppFonts.captionEmphasized)
                    .foregroundColor(.white.opacity(0.85))
                    .padding(.leading, AppSpacing.xs)
            }
            HStack(spacing: AppSpacing.xs) {
                Text("Purchase amount")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(.white.opacity(0.9))
                tapIndicator
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(purchaseSectionColor)
    }

    private var peopleSection: some View {
        VStack(spacing: AppSpacing.sm) {
            HStack(spacing: -6) {
                ForEach(Array(shareList.prefix(8).enumerated()), id: \.offset) { _, block in
                    PixelCatView(id: block.avatarID, size: 32, blackAndWhite: !block.isMe)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.white, lineWidth: 1.5))
                }
                if shareList.count > 8 {
                    Text("+\(shareList.count - 8)")
                        .font(AppFonts.badgeLabel)
                        .foregroundColor(.white)
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.25)))
                }
            }
            HStack(spacing: AppSpacing.xs) {
                Text("\(sharerCount) \(sharerCount == 1 ? "person" : "people")")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(.white.opacity(0.9))
                tapIndicator
            }
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity)
        .background(peopleSectionColor)
    }

    /// Small affordance rendered inline next to each section's label — hints
    /// that the section is tappable and drills into more detail.
    private var tapIndicator: some View {
        Image(systemName: "arrow.up.right")
            .font(AppFonts.iconSmall)
            .foregroundColor(.white.opacity(0.8))
    }

    /// Short, single-line legend below the chart. Colored dots mark the
    /// inputs that map to the chart sections above. The result term
    /// "Debts to settle up" has no dot since that color doesn't appear
    /// on the chart.
    private var formulaLegend: some View {
        let operatorColor = AppColors.textSecondary
        return (Text("● ").foregroundColor(purchaseSectionColor)
            + Text("Purchase amount").foregroundColor(AppColors.textPrimary)
            + Text("  ÷  ").foregroundColor(operatorColor)
            + Text("● ").foregroundColor(peopleSectionColor)
            + Text("\(sharerCount) \(sharerCount == 1 ? "person" : "people")").foregroundColor(AppColors.textPrimary)
            + Text("  =  ").foregroundColor(operatorColor)
            + Text("Debts to settle up").foregroundColor(AppColors.textPrimary))
            .font(AppFonts.captionSmall)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Settlement

    @ViewBuilder
    private var settlementBlock: some View {
        let rows = settlement.rows
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Debts to settle up")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                VStack(spacing: AppSpacing.sm) {
                    ForEach(rows) { row in
                        let friend = friendStore.friend(byID: row.friendID)
                        let friendName = friend?.name ?? "Friend"
                        DebtRowView(
                            kind: settlementKind(for: row, friendName: friendName),
                            currency: transaction.currency,
                            isConnected: friend?.isConnected ?? false
                        )
                    }
                }
            }
        }
    }

    private func settlementKind(for row: PerTransactionSettlement.Row, friendName: String) -> DebtRowView.Kind {
        if abs(row.amount) < 0.005 {
            return .balancesOut(friendID: row.friendID, friendName: friendName)
        }
        if row.amount > 0 {
            return .youLent(friendID: row.friendID, friendName: friendName, amount: row.amount)
        }
        return .youBorrow(friendID: row.friendID, friendName: friendName, amount: abs(row.amount))
    }

    // MARK: - Helpers

    private struct ShareBlock {
        let avatarID: String
        let isMe: Bool
    }

    /// Avatars to stack in the people section of the chart.
    private var shareList: [ShareBlock] {
        var result: [ShareBlock] = []
        if split.myShare > 0.005 {
            result.append(ShareBlock(avatarID: UserIDService.currentID(), isMe: true))
        }
        for friend in split.friends where friend.share > 0.005 {
            result.append(ShareBlock(avatarID: friend.friendID, isMe: false))
        }
        return result
    }
}

// MARK: - Arched Shapes

/// Rectangle whose bottom edge arches UP in the middle. Paired with
/// `BottomArchShape` to produce a uniform-thickness curved divider between
/// the two sections.
struct TopArchShape: Shape {
    let archDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        // Bottom edge: sides at y=H, middle at y=H-archDepth (arches up).
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height),
            control: CGPoint(x: rect.width / 2, y: rect.height - 2 * archDepth)
        )
        path.closeSubpath()
        return path
    }
}

/// Rectangle whose top edge arches UP in the middle, matching `TopArchShape`.
struct BottomArchShape: Shape {
    let archDepth: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Top edge: sides at y=archDepth, middle at y=0 (arches up).
        path.move(to: CGPoint(x: 0, y: archDepth))
        path.addQuadCurve(
            to: CGPoint(x: rect.width, y: archDepth),
            control: CGPoint(x: rect.width / 2, y: -archDepth)
        )
        path.addLine(to: CGPoint(x: rect.width, y: rect.height))
        path.addLine(to: CGPoint(x: 0, y: rect.height))
        path.closeSubpath()
        return path
    }
}

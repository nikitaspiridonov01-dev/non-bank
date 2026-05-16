import SwiftUI
import StoreKit

/// Tip-jar screen behind the "Leave a tip" row in Settings.
///
/// Four consumable IAPs presented as themed cards. The list is hand-
/// tilted toward the middle-high range:
///   - Pizza ($4.99) is rendered with the accent-coloured "Recommended"
///     chip and a thicker outline so it reads as the default choice.
///   - Chef's table ($9.99) carries a "Most generous" chip in muted
///     accent so it feels like an aspirational option rather than the
///     same weight as the cheaper tiers.
struct TipJarView: View {
    @StateObject private var service = TipJarService.shared
    @State private var purchasingTier: TipJarService.Tier?

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text("Support non-bank")
                        .font(AppFonts.displayMedium)
                        .foregroundColor(AppColors.textPrimary)
                    Text("non-bank is built by one person, with no ads and no upsells. If it saved you a chore today, you can fuel the next feature.")
                        .font(AppFonts.bodyRegular)
                        .foregroundColor(AppColors.textSecondary)
                }
                .padding(.vertical, AppSpacing.xs)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))

            Section {
                if service.products.isEmpty && !service.isLoadingProducts {
                    Text("Tips are unavailable right now. Please check back later.")
                        .font(AppFonts.bodyRegular)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.vertical, AppSpacing.sm)
                } else {
                    ForEach(TipJarService.Tier.allCases) { tier in
                        TipRowView(
                            tier: tier,
                            product: service.product(for: tier),
                            isPurchasing: purchasingTier == tier,
                            disabled: purchasingTier != nil && purchasingTier != tier
                        ) {
                            Task { await purchase(tier) }
                        }
                    }
                }
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            .listRowSeparator(.hidden)

            if let last = service.lastPurchasedTier, case .succeeded = service.purchaseState {
                Section {
                    HStack(spacing: 10) {
                        Text(last.emoji)
                            .font(.system(size: 36))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Thank you!")
                                .font(AppFonts.bodyEmphasized)
                                .foregroundColor(AppColors.textPrimary)
                            Text("You just made my day.")
                                .font(AppFonts.metaRegular)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, AppSpacing.xs)
                }
                .listRowBackground(AppColors.backgroundElevated)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Leave a tip")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.loadProducts()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { if case .failed = service.purchaseState { return true } else { return false } },
                set: { if !$0 { service.dismissPurchaseConfirmation() } }
            )
        ) {
            Button("OK") { service.dismissPurchaseConfirmation() }
        } message: {
            if case .failed(let msg) = service.purchaseState {
                Text(msg)
            }
        }
    }

    private func purchase(_ tier: TipJarService.Tier) async {
        purchasingTier = tier
        await service.purchase(tier)
        purchasingTier = nil
    }
}

// MARK: - Tip row

private struct TipRowView: View {
    let tier: TipJarService.Tier
    let product: Product?
    let isPurchasing: Bool
    let disabled: Bool
    let onTap: () -> Void

    private var priceText: String {
        product?.displayPrice ?? "—"
    }

    private var isRecommended: Bool { tier.badge == .recommended }
    private var isMostGenerous: Bool { tier.badge == .mostGenerous }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: AppSpacing.md) {
                Text(tier.emoji)
                    .font(.system(size: 38))
                    .frame(width: 52, height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: 14)
                            .fill(isRecommended ? AppColors.accent.opacity(0.18) : AppColors.backgroundChip)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(tier.title)
                            .font(AppFonts.bodyEmphasized)
                            .foregroundColor(AppColors.textPrimary)
                        if let badge = tier.badge {
                            badgeChip(for: badge)
                        }
                    }
                    Text(tier.blurb)
                        .font(AppFonts.metaRegular)
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                if isPurchasing {
                    ProgressView()
                } else {
                    Text(priceText)
                        .font(AppFonts.bodyEmphasized)
                        .foregroundColor(isRecommended ? AppColors.accent : AppColors.textPrimary)
                }
            }
            .padding(AppSpacing.md)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(AppColors.backgroundElevated)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(
                        isRecommended ? AppColors.accent : Color.clear,
                        lineWidth: isRecommended ? 2 : 0
                    )
            )
            .opacity(disabled ? 0.5 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(disabled || product == nil)
    }

    @ViewBuilder
    private func badgeChip(for badge: TipJarService.Tier.Badge) -> some View {
        switch badge {
        case .recommended:
            Text("Recommended")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                // White text on `Color.accentColor` (`#F18A4D`) only
                // hits ~2.6:1 contrast — fails WCAG AA. `accentBold`
                // is the deeper sienna variant designed exactly for
                // filled CTAs with white labels (≥3:1 large-text AA).
                .background(Capsule().fill(AppColors.accentBold))
        case .mostGenerous:
            Text("Most generous")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(AppColors.accent)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppColors.accent.opacity(0.15)))
        }
    }
}

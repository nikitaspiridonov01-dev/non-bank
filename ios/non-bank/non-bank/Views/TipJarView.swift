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
    @EnvironmentObject private var router: NavigationRouter
    @State private var purchasingTier: TipJarService.Tier?
    @Environment(\.analytics) private var analytics
    /// Wall-clock anchor for `tip_jar_dismissed` dwell — measures
    /// time-spent on the tip jar without converting, which is the
    /// strongest "considered but didn't pay" signal.
    @State private var openedAt: Date = Date()
    /// True once the user scrolled or tapped a tier, distinguishes
    /// "opened and bounced instantly" from "looked then walked
    /// away." Set on the first tier-tap; scroll detection is
    /// expensive in SwiftUI so we lean on tap as the proxy.
    @State private var didEngageWithTier: Bool = false
    @State private var lastTappedTier: TipJarService.Tier?
    /// Drives the celebratory confetti overlay shown after any
    /// successful tip. Flipped on by the `purchaseState` change
    /// observer below, auto-cleared by a timer so the burst tears
    /// itself down once the animation completes.
    @State private var showFireworks: Bool = false
    @State private var fireworksDismissTask: Task<Void, Never>?

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
        // Celebratory burst over the whole screen on any successful tip.
        // `FireworksView` disables hit-testing internally, so the
        // "Thank you!" section and the nav-bar close affordance under it
        // stay fully interactive.
        .overlay {
            if showFireworks {
                FireworksView()
            }
        }
        .navigationTitle("Leave a tip")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await service.loadProducts()
        }
        // Fire confetti when the purchase state lands on `.succeeded`
        // for ANY tier. Driven off the state transition (not the tap
        // handler) so it can't miss a success that resolves after the
        // view-local purchase flow returns.
        .onChange(of: service.purchaseState) { _, newValue in
            if case .succeeded = newValue {
                triggerFireworks()
            }
        }
        .onAppear {
            // Hide the global tab bar while this screen is up — the tip
            // tier rows sit at the bottom of the list and the floating
            // tab bar + FAB would otherwise overlap and swallow taps on
            // the lowest tier. Restored centrally by `SettingsView`'s
            // `.onAppear` when the user pops back to the Settings root —
            // same convention as Import / Export Transactions.
            router.hideTabBar = true
            openedAt = Date()
            // `tipJarViewed` carries the entry source. The setting
            // sub-route is the only path today; expand the enum
            // when other entry points appear (post-split prompt,
            // share-link follow-up, etc.).
            analytics.track(.tipJarViewed(source: .settings))
            analytics.recordFeatureUseIfFirst(.tipJar)
        }
        .onDisappear {
            fireworksDismissTask?.cancel()
            // Fire dismissal only if the user didn't actually
            // purchase — `lastPurchasedTier` going non-nil means
            // they bought and `tipPurchaseSucceeded` already fired
            // from the service. The dismissed event tracks the
            // funnel-leak side: "saw the jar, didn't pay."
            if service.lastPurchasedTier == nil {
                let dwell = Date().timeIntervalSince(openedAt)
                analytics.track(.tipJarDismissed(
                    source: .settings,
                    dwellSecondsBucket: AnalyticsBuckets.dwellSeconds(dwell),
                    scrolledTiers: didEngageWithTier,
                    tappedTier: lastTappedTier.map { mapTier($0) }
                ))
            }
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { service.purchaseState.isFailed },
                set: { if !$0 { service.dismissPurchaseConfirmation() } }
            )
        ) {
            Button("OK") { service.dismissPurchaseConfirmation() }
        } message: {
            if case .failed(let msg) = service.purchaseState {
                Text(msg)
            }
        }
        .trackScreen("TipJarView")
    }

    private func purchase(_ tier: TipJarService.Tier) async {
        purchasingTier = tier
        didEngageWithTier = true
        lastTappedTier = tier
        let analyticsTier = mapTier(tier)
        analytics.track(.tipPurchaseStarted(tier: analyticsTier))
        await service.purchase(tier)
        purchasingTier = nil
        // Inspect the resulting service state to fire the right
        // outcome event. The service drives `purchaseState`, which
        // the alert reads above — we mirror its post-purchase
        // value here so the funnel events line up with the alert
        // semantics.
        switch service.purchaseState {
        case .succeeded:
            analytics.track(.tipPurchaseSucceeded(
                tier: analyticsTier,
                priceBucket: priceBucket(for: tier)
            ))
        case .cancelled:
            analytics.track(.tipPurchaseCancelled(tier: analyticsTier))
        case .failed(let msg):
            // Short stable code over the localised message — drop
            // the message into a fingerprint hash to keep the
            // dashboard's `error_code` cardinality low while
            // staying distinguishable.
            let code = "msg_\(String(msg.hashValue % 100000, radix: 36))"
            analytics.track(.tipPurchaseFailed(tier: analyticsTier, errorCode: code))
        case .idle, .purchasing:
            break
        }
    }

    /// Shows the confetti overlay and schedules its own teardown.
    /// Idempotent within a burst: re-triggering (e.g. a second tip
    /// while the first burst is still on screen) restarts a fresh
    /// burst and resets the dismiss timer so it never lingers.
    private func triggerFireworks() {
        fireworksDismissTask?.cancel()
        // Toggle off→on so SwiftUI rebuilds `FireworksView` from
        // scratch (fresh particle field + animation clock) even if a
        // previous burst hadn't finished.
        showFireworks = false
        showFireworks = true
        fireworksDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(FireworksView.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(AppMotion.normal) {
                showFireworks = false
            }
        }
    }

    /// Maps the `TipJarService.Tier` enum to the analytics-side
    /// `TipTier` enum so the taxonomy file doesn't have to import
    /// StoreKit.
    private func mapTier(_ tier: TipJarService.Tier) -> TipTier {
        switch tier {
        case .coffee:     return .coffee
        case .kitten:     return .kitten
        case .croissant:  return .croissant
        case .pizza:      return .pizza
        case .chefsTable: return .chefstable
        }
    }

    /// Coarse price bucket — we don't want a per-locale exact USD
    /// amount in the event, just "cheap / med / high / premium" so
    /// the dashboard can group by intent rather than localised
    /// display price.
    private func priceBucket(for tier: TipJarService.Tier) -> String {
        switch tier {
        case .coffee:     return "<2"
        case .kitten:     return "<2"
        case .croissant:  return "2-5"
        case .pizza:      return "5-7"
        case .chefsTable: return "7+"
        }
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
                    // Title + badge sit inline when they fit; otherwise the
                    // badge drops to its own line *whole*. `ViewThatFits`
                    // (instead of letting the HStack compress) is what stops
                    // the chip from wrapping mid-word ("Recommende / d").
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 6) {
                            titleText
                            badgeView
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            titleText
                            badgeView
                        }
                    }
                    Text(tier.blurb)
                        .font(AppFonts.metaRegular)
                        .foregroundColor(AppColors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: AppSpacing.sm)

                // The spinner replaces the price *in place*: the price keeps
                // occupying its slot (hidden, not removed) so the row's text
                // and badges don't reflow when a purchase starts.
                ZStack(alignment: .trailing) {
                    Text(priceText)
                        .font(AppFonts.bodyEmphasized)
                        .foregroundColor(isRecommended ? AppColors.accent : AppColors.textPrimary)
                        .opacity(isPurchasing ? 0 : 1)
                    if isPurchasing {
                        ProgressView()
                    }
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

    private var titleText: some View {
        Text(tier.title)
            .font(AppFonts.bodyEmphasized)
            .foregroundColor(AppColors.textPrimary)
            .lineLimit(1)
    }

    @ViewBuilder
    private var badgeView: some View {
        if let badge = tier.badge {
            badgeChip(for: badge)
        }
    }

    @ViewBuilder
    private func badgeChip(for badge: TipJarService.Tier.Badge) -> some View {
        switch badge {
        case .recommended:
            Text("Recommended")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.white)
                .lineLimit(1)
                .fixedSize()
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
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(AppColors.accent.opacity(0.15)))
        }
    }
}

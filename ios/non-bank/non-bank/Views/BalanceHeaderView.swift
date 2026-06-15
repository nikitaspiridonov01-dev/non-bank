import SwiftUI

struct BalanceHeaderView: View {
    let balance: Double
    let onCurrencyChange: (String) -> Void
    
    @EnvironmentObject var currencyStore: CurrencyStore
    @Binding var dateFilter: DateFilterType
    @Binding var hoveredBarIdx: Int?
    @Binding var lastHapticBarIdx: Int?
    
    let trendBars: [TrendBarPoint]
    
    // Debt badge data
    let debtSummary: DebtSummary
    let friends: [Friend]
    let onDebtTap: () -> Void
    
    // Collapse: 0.0 (expanded) ... 1.0 (collapsed)
    let collapseProgress: CGFloat
    let onTap: () -> Void
    let extraTopPadding: CGFloat

    /// Forwarded to `PeriodPickerBar` — fires when the user taps the
    /// "Insights" button next to the period filters. Owned by the
    /// caller (HomeView) so the analytics sheet can be presented
    /// alongside the other home-screen modals.
    let onInsightsTap: () -> Void

    /// One-shot "a save just happened" signal. Drives the count-up: the
    /// number only ROLLS when this fires; every other balance change
    /// (load, tab switch, sync pull, currency swap, trend-bar hover)
    /// snaps instantly with no animation. See `BalanceSavePulse`.
    @ObservedObject private var savePulse = BalanceSavePulse.shared

    /// The value the digits actually render. Lags `displayBalance` only
    /// during a save count-up, when `withAnimation` interpolates it from
    /// the old total to the new one (with `.numericText` rolling the
    /// digits). Outside a save it tracks `displayBalance` exactly.
    @State private var renderedBalance: Double = 0
    @State private var didInitBalance = false

    /// The last `pulseID` we already animated, so a balance change that
    /// arrives in the same save doesn't double-fire, and so we can tell
    /// a save-driven change apart from an incidental recompute.
    @State private var lastAnimatedPulseID = 0

    private var isHoveringBar: Bool { hoveredBarIdx != nil }

    var displayBalance: Double {
        if let idx = hoveredBarIdx, idx < trendBars.count {
            return trendBars[idx].balance
        }
        return balance
    }

    /// Reconcile `renderedBalance` with the latest `displayBalance`,
    /// animating only when a fresh save pulse is responsible.
    ///
    /// Called from both the `displayBalance` and `pulseID` `onChange`
    /// handlers so it's order-independent: a save bumps `pulseID` and
    /// (separately, via the store→HomeView recompute) `displayBalance`,
    /// and SwiftUI may deliver those in either order. We roll the
    /// number on whichever arrives once BOTH a new pulse is pending and
    /// the value actually differs; all other changes snap.
    private func syncRenderedBalance() {
        let target = displayBalance
        let pulsePending = savePulse.pulseID != lastAnimatedPulseID
        if pulsePending && target != renderedBalance {
            lastAnimatedPulseID = savePulse.pulseID
            withAnimation(BalanceCounterMotion.animation) {
                renderedBalance = target
            }
        } else if !pulsePending {
            // No save responsible — instant (load, hover, tab, currency).
            renderedBalance = target
        }
        // else: pulse pending but value unchanged so far — wait for the
        // balance recompute to land, then animate on the next call.
    }

    var body: some View {
        VStack(spacing: 0) {
            // Extra top padding in expanded state only
            Color.clear.frame(height: extraTopPadding * (1 - collapseProgress))
            
            // 1. Net total row + Debt badge (centered)
            HStack(spacing: AppSpacing.sm) {
                Text("Net total")
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textSecondary)

                DebtBadgeView(
                    summary: debtSummary,
                    currency: currencyStore.selectedCurrency,
                    friends: friends,
                    onTap: onDebtTap
                )
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 14 * (1 - collapseProgress))
            .frame(height: max(0, 44 * (1 - collapseProgress)))
            .opacity(max(0, 1.0 - collapseProgress * 2.0))
            .clipped()
            .padding(.bottom, 4 * (1 - collapseProgress))

            // 2. Balance digits
            //
            // The digits read `renderedBalance` (not `displayBalance`)
            // so the save count-up can roll them from the old total to
            // the new one. `.contentTransition(.numericText(value:))`
            // gives each glyph the odometer-style tumble as the value
            // interpolates inside `withAnimation`.
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(NumberFormatting.balanceSign(renderedBalance))
                    .font(AppFonts.balanceSign)
                    .foregroundColor(AppColors.balanceSign)
                    .contentTransition(.numericText(value: renderedBalance))
                    .padding(.trailing, 2)
                Text(NumberFormatting.integerPart(renderedBalance))
                    .font(AppFonts.balanceInteger)
                    .kerning(2)
                    .contentTransition(.numericText(value: renderedBalance))
                Text(NumberFormatting.decimalPart(renderedBalance))
                    .font(AppFonts.balanceDecimal)
                    .foregroundColor(AppColors.textPrimary.opacity(0.8))
                    .contentTransition(.numericText(value: renderedBalance))
                CurrencyDropdownButton(
                    selected: currencyStore.selectedCurrency,
                    onSelect: { code in onCurrencyChange(code) }
                ) {
                    // Currency picker label — the `balanceCurrency`
                    // token now resolves to the warm primary accent
                    // app-wide, so this site picks it up automatically
                    // alongside the same picker in CreateTransactionModal
                    // and DebtSummaryView.
                    Text(currencyStore.selectedCurrency)
                        .font(AppFonts.balanceCurrency)
                        .foregroundColor(AppColors.balanceCurrency)
                        .padding(.leading, AppSpacing.xs)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .frame(maxWidth: .infinity, alignment: .center)
            .frame(height: AppSizes.balanceHeight)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .scaleEffect(1.0 - (0.35 * collapseProgress), anchor: .center)
            .opacity(1.0 - (0.6 * collapseProgress))
            
            // 3. Trend chart + period picker / date label below
            VStack(spacing: 0) {
                GeometryReader { geo in
                    let barWidth: CGFloat = AppSizes.trendBarWidth
                    // Match the home screen's standard horizontal
                    // padding (`.padding(.horizontal, AppSpacing.pageHorizontal)` on the
                    // quick-filters bar, transaction rows, etc.) so
                    // the chart's left/right edges line up with the
                    // rest of the content. Previously this was
                    // `geo.size.width * 0.08` which gave ~31pt
                    // margins on a typical phone — visibly narrower
                    // than the 16pt used elsewhere.
                    let horizontalInset: CGFloat = 16
                    let availableWidth = geo.size.width - horizontalInset * 2
                    let barSpacing: CGFloat = max((availableWidth - (barWidth * CGFloat(trendBars.count))) / CGFloat(max(trendBars.count - 1, 1)), -0.5)

                    HStack(alignment: .bottom, spacing: barSpacing) {
                        ForEach(Array(trendBars.enumerated()), id: \.offset) { idx, bar in
                            BalanceTrendBar(
                                height: bar.height,
                                isHovered: hoveredBarIdx == idx,
                                isDimmed: hoveredBarIdx != nil && hoveredBarIdx != idx,
                                isRecent: idx > trendBars.count - 10
                            )
                            .frame(width: barWidth, height: AppSizes.trendBarHeight, alignment: .bottom)
                            .contentShape(Rectangle())
                        }
                    }
                    .frame(width: availableWidth, height: AppSizes.trendBarHeight, alignment: .bottom)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let x = value.location.x - horizontalInset
                            let idx = min(max(Int(x / (barWidth + barSpacing)), 0), trendBars.count - 1)
                            if hoveredBarIdx != idx {
                                hoveredBarIdx = idx
                                #if canImport(UIKit)
                                if lastHapticBarIdx != idx {
                                    let generator = UIImpactFeedbackGenerator(style: .light)
                                    generator.impactOccurred()
                                    lastHapticBarIdx = idx
                                }
                                #endif
                            }
                        }
                        .onEnded { _ in
                            hoveredBarIdx = nil
                            lastHapticBarIdx = nil
                        }
                    )
                    .simultaneousGesture(TapGesture().onEnded {
                        hoveredBarIdx = nil
                        lastHapticBarIdx = nil
                    })
                }
                .frame(height: 72)
                .padding(.top, AppSpacing.xxs)
                
                // Below chart: date label when hovering, period picker otherwise
                ZStack {
                    // Date label (visible only when hovering a bar)
                    Text(hoveredBarIdx != nil && hoveredBarIdx! < trendBars.count ? trendBars[hoveredBarIdx!].label : "\u{00a0}")
                        .font(.caption)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .opacity(isHoveringBar ? 1 : 0)

                    // Period picker (hidden when hovering)
                    PeriodPickerBar(dateFilter: $dateFilter, onInsightsTap: onInsightsTap)
                        .opacity(isHoveringBar ? 0 : 1)
                }
                .frame(height: 28)
                .padding(.top, 6)
            }
            .padding(.top, 0)
            .frame(height: max(0, 116 * (1 - collapseProgress)), alignment: .top)
            .opacity(max(0, 1.0 - collapseProgress * 1.5))
            .clipped()
        }
        .background(Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            onTap()
        }
        .onAppear {
            // Seed the displayed value without animating on first render
            // (or when the home screen reappears) so the number doesn't
            // count up from zero on a tab switch.
            if !didInitBalance {
                renderedBalance = displayBalance
                lastAnimatedPulseID = savePulse.pulseID
                didInitBalance = true
            } else {
                renderedBalance = displayBalance
            }
        }
        .onChange(of: displayBalance) { _ in
            syncRenderedBalance()
        }
        .onChange(of: savePulse.pulseID) { _ in
            syncRenderedBalance()
        }
    }

}

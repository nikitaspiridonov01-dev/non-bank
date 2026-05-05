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

    private var isHoveringBar: Bool { hoveredBarIdx != nil }

    var displayBalance: Double {
        if let idx = hoveredBarIdx, idx < trendBars.count {
            return trendBars[idx].balance
        }
        return balance
    }

    var body: some View {
        VStack(spacing: 0) {
            // Extra top padding in expanded state only
            Color.clear.frame(height: extraTopPadding * (1 - collapseProgress))
            
            // 1. Net total row + Debt badge (centered)
            HStack(spacing: AppSpacing.sm) {
                Text("Net total")
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(.secondary)

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
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(NumberFormatting.balanceSign(displayBalance))
                    .font(AppFonts.balanceSign)
                    .foregroundColor(AppColors.balanceSign)
                    .padding(.trailing, 2)
                Text(NumberFormatting.integerPart(displayBalance))
                    .font(AppFonts.balanceInteger)
                    .kerning(2)
                Text(NumberFormatting.decimalPart(displayBalance))
                    .font(AppFonts.balanceDecimal)
                    .foregroundColor(AppColors.textPrimary.opacity(0.8))
                Menu {
                    ForEach(currencyStore.currencyOptions, id: \.self) { code in
                        Button {
                            onCurrencyChange(code)
                        } label: {
                            Text("\(code) \(CurrencyInfo.byCode[code]?.emoji ?? "💱")")
                        }
                    }
                } label: {
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
                        .foregroundColor(.secondary)
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
    }

}

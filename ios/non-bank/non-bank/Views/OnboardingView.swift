import SwiftUI

/// First-launch onboarding flow.
///
/// Four steps, paged via the system `TabView(.page)`:
///   1. Track receipts — scanner-bar sweeps across a receipt
///   2. Split with friends — coin shuttles between three figures
///   3. See where it goes — bars climb in sequence
///   4. Set up — big keypad for the initial balance + currency picker
///
/// Per the v2 design refresh:
///   - **Skip is gone.** Each step is short and the final one is
///     optional anyway — users either complete the flow or kill the
///     app, no halfway exit.
///   - **Animations carry weight.** Each illustration uses a
///     `TimelineView(.animation)` driver so it actually moves frame-
///     by-frame (sleeping-cat caliber), not just a scale pulse.
///   - **Balance entry is its own screen.** Big amount text + numpad
///     + currency chip, same shape as the create-transaction modal so
///     users see a familiar interaction at the very first moment.
struct OnboardingView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var router: NavigationRouter

    @ObservedObject private var service = OnboardingService.shared

    @State private var currentStep: Int = 0
    /// Keypad input on the final step. Stored as a string so the
    /// keypad-style edits (append digit, append dot, backspace) work
    /// directly without round-tripping through Double + locale.
    @State private var initialBalanceText: String = ""

    private static let totalSteps = 4

    var body: some View {
        ZStack {
            AppColors.backgroundPrimary.ignoresSafeArea()

            VStack(spacing: 0) {
                TabView(selection: $currentStep) {
                    featureStep(
                        illustration: { OnboardingReceiptIllustration() },
                        title: "Scan receipts",
                        body: "Snap a photo. The app pulls out items and totals."
                    )
                    .tag(0)

                    featureStep(
                        illustration: { OnboardingSplitIllustration() },
                        title: "Split with friends",
                        body: "Split a bill or a shared purchase. Send a link — their share shows up in their app."
                    )
                    .tag(1)

                    featureStep(
                        illustration: { OnboardingInsightsIllustration() },
                        title: "See where it goes",
                        body: "Spot what eats your budget. Without spreadsheets."
                    )
                    .tag(2)

                    setupStep
                        .tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxHeight: .infinity)

                pageDots
                    .padding(.top, AppSpacing.md)

                footerButton
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.bottom, AppSpacing.xxl)
                    .padding(.top, AppSpacing.md)
            }
        }
    }

    // MARK: - Feature step layout

    @ViewBuilder
    private func featureStep<Illustration: View>(
        illustration: () -> Illustration,
        title: String,
        body: String
    ) -> some View {
        VStack(spacing: AppSpacing.xl) {
            Spacer(minLength: AppSpacing.xxxl)
            illustration()
                .frame(height: 220)
            VStack(spacing: AppSpacing.sm) {
                Text(title)
                    .font(AppFonts.displayLarge)
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text(body)
                    .font(AppFonts.bodyRegular)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, AppSpacing.xxl)
            Spacer()
        }
    }

    // MARK: - Setup (balance) step

    private var setupStep: some View {
        VStack(spacing: 0) {
            Spacer(minLength: AppSpacing.xl)

            // Compact piggy/jar — small enough to leave room for the
            // big amount text below without scrolling.
            OnboardingPiggyIllustration()
                .frame(height: 110)

            Text("Have any savings?")
                .font(AppFonts.displayMedium)
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.top, AppSpacing.lg)

            Text("Add what's on your card or in your wallet today. Skip if you'd rather start clean.")
                .font(AppFonts.bodyRegular)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AppSpacing.xxl)
                .padding(.top, AppSpacing.sm)

            Spacer(minLength: AppSpacing.lg)

            // Amount header — mirrors `CreateTransactionModal`'s
            // layout one-for-one:
            //   - big integer on the left, decimal in a smaller font
            //   - currency dropdown immediately *after* the digits
            //   - backspace floats to the trailing edge as an overlay,
            //     visible only when the field has content
            // The `CurrencyDropdownButton` is the same component the
            // create-transaction screen uses, so the dropdown UI and
            // the More-currencies sheet are identical too.
            //
            // `amountFontSize` shrinks in steps as the user types more
            // digits — same step ladder as
            // `CreateTransactionViewModel.amountFontSize`. Discrete
            // sizes keep the currency chip's baseline stable instead
            // of letting `minimumScaleFactor` warp the whole row
            // continuously (which is what produced the "currency
            // jumping up/down" wobble).
            let fontSize = amountFontSize
            ZStack {
                HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                    let parts = formattedAmountGrouped.split(separator: ".", omittingEmptySubsequences: false)
                    Text(String(parts.first ?? "0"))
                        .font(.system(size: fontSize, weight: .bold))
                        .foregroundColor(initialBalanceText.isEmpty ? AppColors.textDisabled : AppColors.textPrimary)
                    if parts.count > 1 {
                        Text("." + String(parts[1]))
                            .font(.system(size: fontSize * 0.5, weight: .medium))
                            .foregroundColor(AppColors.textSecondary)
                    }
                    CurrencyDropdownButton(
                        selected: currencyStore.selectedCurrency,
                        onSelect: { code in currencyStore.selectedCurrency = code }
                    ) {
                        Text(currencyStore.selectedCurrency)
                            .font(.system(size: fontSize * 0.5, weight: .semibold))
                            .foregroundColor(AppColors.balanceCurrency)
                            .padding(.leading, AppSpacing.xs)
                    }
                }
                .padding(.horizontal, 56)
                .frame(maxWidth: .infinity, alignment: .center)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
                .animation(.easeInOut(duration: 0.15), value: fontSize)

                // Trailing-aligned backspace. Same `delete.left.fill`
                // glyph + warm-grey tint as the create-transaction
                // header so users see the same affordance twice.
                HStack {
                    Spacer()
                    Button(action: handleKeypadBackspace) {
                        Image(systemName: "delete.left.fill")
                            .font(.system(size: 28, weight: .regular))
                            .foregroundColor(AppColors.textQuaternary)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .padding(.trailing, 24)
                    .opacity(initialBalanceText.isEmpty ? 0 : 1)
                    .animation(.easeInOut(duration: 0.2), value: initialBalanceText.isEmpty)
                }
            }
            // Generous fixed height — accommodates the largest font
            // step (~64pt) without dragging the rest of the layout
            // around when the size steps down.
            .frame(height: 90)

            Spacer(minLength: AppSpacing.lg)

            // Footer hint — replaces the old "Add regular income"
            // chip. The same idea (income tracking) is reachable from
            // the home tab + button right after onboarding finishes.
            Text("You can add a one-time or regular income later from the home screen.")
                .font(AppFonts.metaRegular)
                .foregroundColor(AppColors.textTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xxl)
                .padding(.bottom, AppSpacing.md)

            // Numpad — digits + dot, no backspace (lives next to the
            // amount header) and no commit tick (the page-level
            // "Get started" button commits). Last cell stays blank to
            // preserve the 3×4 grid the rest of the app uses.
            OnboardingNumpadView(onKey: handleKeypadKey)
                .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    /// Raw amount string ready for display ("0" placeholder when the
    /// field is empty so the layout doesn't collapse on first frame).
    private var displayedBalance: String {
        initialBalanceText.isEmpty ? "0" : initialBalanceText
    }

    /// Integer part with thousand separators ("29 250" or
    /// "29 250.50"). Mirrors `CreateTransactionViewModel
    /// .formattedAmountGrouped` — the grouping matters because large
    /// long-tail-currency amounts (e.g. 65 000 AMD) read as a wall
    /// of digits without spaces.
    private var formattedAmountGrouped: String {
        let raw = displayedBalance
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let intString = String(parts.first ?? "0")
        guard let intValue = Int(intString) else { return raw }
        let grouped = NumberFormatting.integerPart(Double(intValue))
        if parts.count > 1 {
            return grouped + "." + String(parts[1])
        }
        return grouped
    }

    /// Adaptive font size — shrinks as the displayed string grows,
    /// in discrete steps. Matches the ladder used by
    /// `CreateTransactionViewModel.amountFontSize` so the amount
    /// header reads the same in both flows. Discrete sizes keep
    /// the currency chip's baseline stable (continuous shrinking
    /// via `minimumScaleFactor` caused a visible wobble).
    private var amountFontSize: CGFloat {
        let displayLength = displayedBalance.count + currencyStore.selectedCurrency.count + 1
        switch displayLength {
        case ..<8:    return 64
        case 8..<10:  return 56
        case 10..<12: return 48
        case 12..<14: return 40
        default:      return 34
        }
    }

    // MARK: - Keypad input

    /// Append a digit or decimal separator to `initialBalanceText`.
    /// Mirrors the rules in `CreateTransactionViewModel.handleKeyPress`
    /// — single decimal point, max 2 fractional digits, 8-digit cap
    /// on the integer part.
    private func handleKeypadKey(_ key: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if key == "." {
            guard !initialBalanceText.contains(".") else { return }
            if initialBalanceText.isEmpty {
                initialBalanceText = "0."
            } else {
                initialBalanceText.append(".")
            }
            return
        }
        // Digit
        let parts = initialBalanceText.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = parts.first ?? ""
        if !initialBalanceText.contains(".") {
            guard intPart.count < 8 else { return }
        } else if parts.count > 1, parts[1].count >= 2 {
            return
        }
        if initialBalanceText == "0" {
            initialBalanceText = key
        } else {
            initialBalanceText.append(key)
        }
    }

    private func handleKeypadBackspace() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if !initialBalanceText.isEmpty {
            initialBalanceText.removeLast()
        }
    }

    // MARK: - Page dots

    private var pageDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<Self.totalSteps, id: \.self) { idx in
                Circle()
                    .fill(idx == currentStep ? Color.accentColor : AppColors.backgroundChip)
                    .frame(width: 8, height: 8)
            }
        }
    }

    // MARK: - Footer button

    private var footerButton: some View {
        Button {
            if currentStep < Self.totalSteps - 1 {
                withAnimation { currentStep += 1 }
            } else {
                completeOnboarding(persistInitialBalance: true)
            }
        } label: {
            Text(currentStep < Self.totalSteps - 1 ? "Next" : "Get started")
                .font(AppFonts.bodyEmphasized)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                // `accentBold` is the deeper warm orange Apple-style
                // companion to `accentColor`. White text on the
                // lighter `accentColor` hits ~3.5:1 — below AA — and
                // reads as washed out in dark mode. `accentBold`
                // (#B85C21 light / #C66629 dark) brings the contrast
                // above 4.5:1 with the same warm hue. Same rule as
                // the splitAccentBold fix for the Settle Up CTA.
                .background(AppColors.accentBold)
                .foregroundColor(.white)
                .cornerRadius(14)
        }
    }

    // MARK: - Completion

    private func completeOnboarding(persistInitialBalance: Bool = false) {
        if persistInitialBalance {
            let trimmed = initialBalanceText
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: ",", with: ".")
            if let amount = Double(trimmed), amount > 0 {
                let category = categoryStore.findCategory(byTitle: CategoryStore.uncategorized.title)
                    ?? CategoryStore.uncategorized
                let tx = Transaction(
                    id: 0,
                    emoji: category.emoji,
                    category: category.title,
                    title: "Initial balance",
                    description: nil,
                    amount: amount,
                    currency: currencyStore.selectedCurrency,
                    date: Date(),
                    type: .income,
                    tags: nil
                )
                transactionStore.add(tx)
            }
        }
        service.markCompleted()
    }
}

// MARK: - Numpad

/// Trimmed-down numpad for the onboarding setup step.
///   - Same 3×4 grid + cell sizing as `CreateTransactionModal` so the
///     muscle memory carries over.
///   - **No backspace** in the grid — it lives next to the amount
///     header instead, matching the create-transaction screen.
///   - **No commit tick** — the page-level "Get started" button
///     commits, so the bottom-right slot is intentionally blank
///     (rendered as an inert spacer to keep the grid square).
private struct OnboardingNumpadView: View {
    let onKey: (String) -> Void

    private let rows: [[String?]] = [
        ["1", "2", "3"],
        ["4", "5", "6"],
        ["7", "8", "9"],
        [".", "0", nil]
    ]

    var body: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(0..<rows.count, id: \.self) { rIdx in
                HStack(spacing: AppSpacing.sm) {
                    ForEach(0..<rows[rIdx].count, id: \.self) { cIdx in
                        if let key = rows[rIdx][cIdx] {
                            Button {
                                onKey(key)
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AppRadius.medium)
                                        .fill(AppColors.backgroundElevated)
                                    Text(key)
                                        .font(.system(size: 26, weight: .medium))
                                        .foregroundColor(AppColors.textPrimary)
                                }
                                .frame(height: 52)
                            }
                        } else {
                            // Empty slot — keeps the 3-column grid
                            // even when the key is omitted.
                            Color.clear.frame(height: 52)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Pixel illustrations
//
// Each illustration uses `TimelineView(.animation)` so animation
// state is computed from the wall-clock instead of being driven by
// SwiftUI's implicit animation curves. Same approach as
// `SleepingCatIllustration`: cheap, deterministic, no `@State`
// pulse needed, animation never desyncs across illustrations on
// the same screen.

private extension GraphicsContext {
    /// Convenience cell-fill on a fixed pixel grid. Keeps the per-
    /// illustration `body` readable when there are 30+ rects to draw.
    func fillCell(
        _ x: Double,
        _ y: Double,
        w: Double = 1,
        h: Double = 1,
        unit: CGFloat,
        offsetX: CGFloat,
        offsetY: CGFloat,
        color: Color
    ) {
        let rect = CGRect(
            x: offsetX + CGFloat(x) * unit,
            y: offsetY + CGFloat(y) * unit,
            width: CGFloat(w) * unit,
            height: CGFloat(h) * unit
        )
        fill(Path(rect), with: .color(color))
    }
}

// MARK: Receipt — scanner sweep + items revealed line by line

private struct OnboardingReceiptIllustration: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 4-second loop. First 2.5 s the scanner sweeps top→bottom,
            // each line of the receipt "locks in" as the sweep crosses
            // it. Remaining 1.5 s the receipt sits with all lines lit,
            // then the cycle resets.
            let cycle: Double = 4.0
            let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
            // Scan progress: 0 → 1 over the first 0.625 of the cycle,
            // clamped to 1 for the remainder so the bar parks at the
            // bottom while the receipt "settles".
            let scanProgress = min(1.0, phase / 0.625)

            Canvas { ctx, size in
                let cols = 18.0
                let rows = 22.0
                let unit = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
                let offsetX = (size.width - CGFloat(cols) * unit) / 2
                let offsetY = (size.height - CGFloat(rows) * unit) / 2

                let paper = Color.accentColor.opacity(0.92)
                let paperHeader = Color.accentColor
                let ink = AppColors.textPrimary
                let scanColor = AppColors.splitAccent

                // Paper body
                for r in 1..<18 {
                    ctx.fillCell(3, Double(r), w: 12, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paper)
                }
                // Header bar (taller, darker)
                ctx.fillCell(3, 1, w: 12, h: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paperHeader)

                // Item lines reveal one-by-one as the scanner crosses
                // them. Each line is at a row whose `revealAt` value
                // says when in the scan they should ink in.
                let lines: [(row: Int, revealAt: Double)] = [
                    (5, 0.20),
                    (7, 0.35),
                    (9, 0.50),
                    (11, 0.65),
                    (13, 0.80)
                ]
                for line in lines {
                    let inked = scanProgress >= line.revealAt
                    let lineColor = inked ? ink : ink.opacity(0.18)
                    ctx.fillCell(5, Double(line.row), w: 6, unit: unit, offsetX: offsetX, offsetY: offsetY, color: lineColor)
                    ctx.fillCell(12, Double(line.row), w: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: lineColor)
                }
                // Total block — locks in at the very end
                let totalLocked = scanProgress >= 0.95
                let totalColor = totalLocked ? ink : ink.opacity(0.18)
                ctx.fillCell(5, 15, w: 9, unit: unit, offsetX: offsetX, offsetY: offsetY, color: totalColor)
                ctx.fillCell(5, 16, w: 4, unit: unit, offsetX: offsetX, offsetY: offsetY, color: totalColor)
                ctx.fillCell(11, 16, w: 3, unit: unit, offsetX: offsetX, offsetY: offsetY, color: totalColor)

                // Torn zigzag bottom
                for i in 0..<6 {
                    let xStart = 3 + i * 2
                    ctx.fillCell(Double(xStart), 18, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paper)
                    ctx.fillCell(Double(xStart + 1), 19, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paper)
                }

                // Scanner sweep bar — only visible during the scan
                // phase, glides top-of-receipt to bottom. Drawn last
                // so it paints over both inked and pending lines.
                if phase < 0.7 {
                    let scanY = 1.0 + scanProgress * 17.0
                    let scanRect = CGRect(
                        x: offsetX + CGFloat(2.5) * unit,
                        y: offsetY + CGFloat(scanY) * unit,
                        width: CGFloat(13) * unit,
                        height: CGFloat(0.5) * unit
                    )
                    let bandOpacity = 1.0 - abs(scanProgress * 2.0 - 1.0) * 0.4
                    ctx.fill(Path(scanRect), with: .color(scanColor.opacity(bandOpacity)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Split — receipt rains tokens into three figures

private struct OnboardingSplitIllustration: View {
    /// One receipt at the top spawns three coloured tokens that arc
    /// down into the figures one after another. Each token has the
    /// colour of its destination figure so the eye instantly maps
    /// "this share goes to that person." Cycle resets cleanly so the
    /// loop doesn't read as a jitter.
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 3.6-second loop. Each of the three tokens occupies
            // ~1.0 s of the cycle (overlap allowed at the edges so
            // the animation always has something in motion); the
            // remaining 0.6 s holds the scene before the next loop.
            let cycle: Double = 3.6
            let phase = t.truncatingRemainder(dividingBy: cycle) / cycle
            // Slow breath on the figures so they feel alive but
            // don't compete with the falling tokens.
            let breath = sin(t * (2.0 * .pi / 2.4))
            let breathOffset = CGFloat(breath) * 0.18

            Canvas { ctx, size in
                let cols = 22.0
                let rows = 22.0
                let unit = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
                let offsetX = (size.width - CGFloat(cols) * unit) / 2
                let offsetY = (size.height - CGFloat(rows) * unit) / 2

                let accent = Color.accentColor
                let split = AppColors.splitAccent
                let paper = Color.accentColor.opacity(0.92)
                let ink = AppColors.textPrimary

                // MARK: Receipt (centre top)
                //
                // Same chunky paper shape as the receipt-scan slide
                // but smaller — sits between rows 1..7 so the
                // figures + ground get the bottom 14 rows.
                let receiptLeft: Double = 8
                let receiptW: Double = 6
                for r in 1..<7 {
                    ctx.fillCell(receiptLeft, Double(r), w: receiptW, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paper)
                }
                // Header strip
                ctx.fillCell(receiptLeft, 1, w: receiptW, h: 1, unit: unit, offsetX: offsetX, offsetY: offsetY, color: accent)
                // Two inked item lines
                ctx.fillCell(receiptLeft + 1, 3, w: 3, unit: unit, offsetX: offsetX, offsetY: offsetY, color: ink)
                ctx.fillCell(receiptLeft + 1, 4, w: 4, unit: unit, offsetX: offsetX, offsetY: offsetY, color: ink)
                ctx.fillCell(receiptLeft + 1, 5, w: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: ink)
                // Torn bottom edge — two-row zigzag like slide 1
                for i in 0..<3 {
                    let zx = receiptLeft + Double(i * 2)
                    ctx.fillCell(zx, 7, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paper)
                    ctx.fillCell(zx + 1, 8, unit: unit, offsetX: offsetX, offsetY: offsetY, color: paper)
                }

                // MARK: Figures (bottom row)
                //
                // Same proportions as before, shifted down to row
                // 13..21 so the receipt has airspace above.
                func drawFigure(at originX: Double, color: Color, bobble: CGFloat) {
                    let b = Double(bobble)
                    ctx.fillCell(originX + 1, 11 + b, w: 2, h: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: color)
                    ctx.fillCell(originX, 14 + b, w: 4, h: 4, unit: unit, offsetX: offsetX, offsetY: offsetY, color: color)
                    ctx.fillCell(originX, 18 + b, w: 1, h: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: color)
                    ctx.fillCell(originX + 3, 18 + b, w: 1, h: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: color)
                }

                // Each figure's centre x — used as the target landing
                // point for its matching token below.
                struct Figure {
                    let originX: Double
                    let centreX: Double
                    let color: Color
                }
                let figures: [Figure] = [
                    Figure(originX: 1, centreX: 3, color: accent),
                    Figure(originX: 9, centreX: 11, color: split),
                    Figure(originX: 17, centreX: 19, color: accent)
                ]
                for fig in figures {
                    drawFigure(at: fig.originX, color: fig.color, bobble: breathOffset)
                }

                // Ground line
                let groundRect = CGRect(
                    x: offsetX + CGFloat(0.5) * unit,
                    y: offsetY + CGFloat(22) * unit,
                    width: CGFloat(21) * unit,
                    height: CGFloat(0.4) * unit
                )
                ctx.fill(Path(groundRect), with: .color(ink))

                // MARK: Falling tokens
                //
                // Three tokens spawn from the bottom of the receipt
                // (slot row 7, centre column 11) and arc down to
                // each figure's chest. We give them overlapping
                // windows: token i is visible during
                // `phase ∈ [start_i, end_i]`.
                let tokenWindows: [(start: Double, end: Double, target: Figure)] = [
                    (0.00, 0.32, figures[0]),
                    (0.20, 0.56, figures[1]),
                    (0.40, 0.78, figures[2])
                ]
                let spawnX: Double = 11
                let spawnY: Double = 7
                let landY: Double = 15 // mid-body of each figure

                for window in tokenWindows {
                    guard phase >= window.start, phase <= window.end else { continue }
                    let p = (phase - window.start) / (window.end - window.start)
                    // Ease-in vertical drop so the token accelerates
                    // toward the figure (like gravity).
                    let easedFall = p * p
                    let yToken = spawnY + (landY - spawnY) * easedFall
                    // X glides linearly toward the figure's centre.
                    let xToken = spawnX + (window.target.centreX - spawnX) * p
                    // Slight overshoot fade-out near the end so the
                    // token "absorbs" into the figure rather than
                    // disappearing mid-air.
                    let fade = p > 0.85 ? max(0, 1 - (p - 0.85) / 0.15) : 1.0

                    let tokenRect = CGRect(
                        x: offsetX + CGFloat(xToken - 0.7) * unit,
                        y: offsetY + CGFloat(yToken - 0.7) * unit,
                        width: CGFloat(1.4) * unit,
                        height: CGFloat(1.4) * unit
                    )
                    ctx.fill(Path(tokenRect), with: .color(window.target.color.opacity(fade)))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Insights — bars climb in sequence, then settle

private struct OnboardingInsightsIllustration: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 4-second loop: each of the 5 bars rises in sequence
            // over the first ~3 s, then all five hold for 1 s, then
            // a smooth wipe brings them back down for the restart.
            let cycle: Double = 4.0
            let phase = t.truncatingRemainder(dividingBy: cycle) / cycle

            Canvas { ctx, size in
                let cols = 18.0
                let rows = 16.0
                let unit = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
                let offsetX = (size.width - CGFloat(cols) * unit) / 2
                let offsetY = (size.height - CGFloat(rows) * unit) / 2

                let accent = Color.accentColor
                let muted = Color.accentColor.opacity(0.5)
                let ink = AppColors.textPrimary

                // Per-bar target heights (matches the static version
                // we had before) + colour assignments.
                let bars: [(x: Double, height: Double, color: Color)] = [
                    (2, 4, muted),
                    (5, 6, muted),
                    (8, 8, accent),
                    (11, 5, muted),
                    (14, 10, accent)
                ]
                let axisY = 13.0

                // Bar animation phasing
                //   rise[i] is 1.0 once that bar is "fully grown" at
                //   its target height. Each bar reaches full height
                //   at staggered cycle points so they climb left-to-
                //   right like a wave.
                let riseWindow = 0.6 // 60 % of cycle for the whole rise
                let perBarStart = riseWindow / Double(bars.count)

                func rise(for index: Int) -> Double {
                    let start = Double(index) * perBarStart * 0.7
                    let end = start + perBarStart
                    if phase < start { return 0 }
                    if phase > end { return 1 }
                    // Ease-out cubic
                    let p = (phase - start) / (end - start)
                    return 1 - pow(1 - p, 3)
                }

                // Fall-out at the end of the cycle for the wipe back.
                // Last 10 % collapses all bars together.
                let fallStart = 0.9
                let fall: Double = {
                    guard phase > fallStart else { return 1 }
                    let p = (phase - fallStart) / (1 - fallStart)
                    return 1 - p
                }()

                for (idx, bar) in bars.enumerated() {
                    let progress = rise(for: idx) * fall
                    let drawn = bar.height * progress
                    guard drawn > 0.01 else { continue }
                    ctx.fillCell(
                        bar.x,
                        axisY - drawn,
                        w: 2,
                        h: drawn,
                        unit: unit,
                        offsetX: offsetX,
                        offsetY: offsetY,
                        color: bar.color
                    )
                }
                // Axis
                ctx.fillCell(1, axisY, w: 16, unit: unit, offsetX: offsetX, offsetY: offsetY, color: ink)
                for bar in bars {
                    ctx.fillCell(bar.x, axisY + 1, w: 2, unit: unit, offsetX: offsetX, offsetY: offsetY, color: ink)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: Piggy / jar — coin drops in on a 2.4 s rhythm, jar bounces

private struct OnboardingPiggyIllustration: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            // 2.4-second loop: a coin enters from above the jar, falls
            // through the slot, hits the lid, and the jar gives a
            // squash-and-stretch bounce. Then the coin disappears
            // (inside the jar) and the cycle repeats.
            let cycle: Double = 2.4
            let phase = t.truncatingRemainder(dividingBy: cycle) / cycle

            // Coin fall: phase [0..0.55] maps to y [-3..3] (relative
            // to the slot at row 3). After 0.55 the coin is inside,
            // so we draw nothing.
            let coinVisible = phase < 0.55
            let coinFallProgress = min(1.0, phase / 0.55)
            // Ease-in cubic so the coin accelerates toward the slot.
            let coinY = -3.0 + 6.0 * (coinFallProgress * coinFallProgress)

            // Jar squash on impact (phase 0.55..0.75) — height shrinks
            // by ~12 % and width grows by ~6 %, then springs back.
            let impactWindow = (start: 0.55, end: 0.85)
            let squash: CGFloat = {
                guard phase >= impactWindow.start, phase <= impactWindow.end else { return 0 }
                let p = (phase - impactWindow.start) / (impactWindow.end - impactWindow.start)
                // Triangle 0 → 1 → 0
                return CGFloat(1.0 - abs(p * 2.0 - 1.0))
            }()

            Canvas { ctx, size in
                let cols = 16.0
                let rows = 14.0
                let unit = min(size.width / CGFloat(cols), size.height / CGFloat(rows))
                let offsetX = (size.width - CGFloat(cols) * unit) / 2
                let offsetY = (size.height - CGFloat(rows) * unit) / 2

                let accent = Color.accentColor
                let highlight = Color.accentColor.opacity(0.65)
                let ink = AppColors.textPrimary

                // Apply squash transform: jar pivots from its bottom
                // (rows 11+). Height factor < 1 makes it shorter, width
                // factor > 1 makes it wider. We translate every cell's
                // y by an offset proportional to its distance from
                // the bottom so the floor stays planted.
                let heightFactor = 1.0 - 0.12 * squash
                let widthExpand = 0.5 * squash // pixels of bulge per side
                let baseY: CGFloat = 11

                func jarCell(_ x: Double, _ y: Double, w: Double = 1, h: Double = 1, color: Color) {
                    // Distance above the floor row in original coords
                    let dyTop = baseY - CGFloat(y)
                    let dyBottom = baseY - CGFloat(y + h)
                    let adjTopY = baseY - dyTop * heightFactor
                    let adjBottomY = baseY - dyBottom * heightFactor
                    let drawH = adjBottomY - adjTopY
                    // Horizontal bulge — only applied if the cell
                    // touches the body span (rows 4..10). Otherwise
                    // we render at the original x (lid, slot).
                    let inBody = y >= 4 && y <= 10
                    let bulge = inBody ? widthExpand : 0
                    let rect = CGRect(
                        x: offsetX + (CGFloat(x) - bulge) * unit,
                        y: offsetY + adjTopY * unit,
                        width: (CGFloat(w) + bulge * 2) * unit,
                        height: drawH * unit
                    )
                    ctx.fill(Path(rect), with: .color(color))
                }

                // Jar body
                jarCell(3, 4, w: 10, h: 7, color: accent)
                // Shoulders / neck
                jarCell(4, 3, w: 8, h: 1, color: accent)
                jarCell(5, 2, w: 6, h: 1, color: accent)
                // Lid
                jarCell(4, 1, w: 8, h: 1, color: ink)
                // Highlight strip on the side
                jarCell(4, 5, w: 1, h: 5, color: highlight)
                // Coin slot in the lid
                jarCell(7, 3, w: 2, h: 1, color: ink)
                // Legs (anchored — these don't squash)
                let legRect1 = CGRect(
                    x: offsetX + CGFloat(3) * unit,
                    y: offsetY + CGFloat(11) * unit,
                    width: CGFloat(2) * unit,
                    height: CGFloat(1) * unit
                )
                ctx.fill(Path(legRect1), with: .color(ink))
                let legRect2 = CGRect(
                    x: offsetX + CGFloat(11) * unit,
                    y: offsetY + CGFloat(11) * unit,
                    width: CGFloat(2) * unit,
                    height: CGFloat(1) * unit
                )
                ctx.fill(Path(legRect2), with: .color(ink))

                // Falling coin
                if coinVisible {
                    let coinRect = CGRect(
                        x: offsetX + CGFloat(7) * unit,
                        y: offsetY + CGFloat(coinY) * unit,
                        width: CGFloat(2) * unit,
                        height: CGFloat(1) * unit
                    )
                    ctx.fill(Path(coinRect), with: .color(accent))
                }
            }
        }
        .accessibilityHidden(true)
    }
}

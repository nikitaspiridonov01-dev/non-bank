import SwiftUI

// MARK: - Empty State View
//
// Standardised empty / "no data" placeholder. Replaces the 9 ad-hoc
// implementations scattered across `InsightsView`, `CategoryTopCard`
// (compact-in-pill variant), `InsightsDetailView`, `CategoryHistoryView`,
// `FriendsView`, `FriendPickerView`, `ReceiptReviewView`, `HomeView`
// (search empty), and `FilterSheetView`.
//
// **Two figure styles**:
// - **System symbol** — small line-icon (SF Symbols). The default for
//   `.compact` in-pill placeholders where a 18pt glyph fits.
// - **Pixel illustration** — animated pixel-art figure
//   (`SleepingCat`, `EmptyBox`, `Search`, `SuccessCat`,
//   `GrowingPlant`). Used at `.full` and `.page` sizes where the
//   figure carries character. Compact size always falls back to a
//   system symbol regardless — the pixel art is too detailed to
//   read at 18pt.
//
// **Three size variants**:
// - `.compact` — single-line text + small icon, fits inside a pill
//   row (used for "No data for this period" inside Insights cards).
// - `.full`    — centered icon + title (+ optional description),
//   for empty-list screens (FriendsView, ReceiptReviewView).
// - `.page`    — large icon + title + description + optional
//   action button, for whole-screen empty states.
//
// Usage:
//
//     // Compact — system symbol (in-pill placeholder):
//     EmptyStateView(systemImage: "tray", title: "No data", size: .compact)
//
//     // Full — pixel illustration, list-screen empty:
//     EmptyStateView(figure: .sleepingCat, title: "No transactions yet",
//                    description: "...")
//
//     // Page — pixel illustration + CTA:
//     EmptyStateView(
//         figure: .growingPlant,
//         title: "Nothing to analyse yet",
//         description: "Add a transaction to start seeing insights.",
//         size: .page,
//         action: .init(title: "Add transaction") { showCreate = true }
//     )

struct EmptyStateView: View {

    enum Size: Equatable {
        /// In-line empty state — small icon + label, side-by-side.
        /// Drop into a pill row for "No data" placeholders.
        case compact
        /// Centered, vertical layout — list-screen empty states.
        case full
        /// Large hero variant — whole-screen empty states with
        /// optional action button.
        case page
    }

    /// Pixel-illustration figures available in the design system.
    /// Each maps to a corresponding `*Illustration` view in
    /// `Core/DesignSystem/Illustrations/`. Tints carry through —
    /// pass `tint: .reminders` / `.split` for contextual variants.
    enum PixelFigure {
        case sleepingCat(tint: PixelTint = .neutral)
        case emptyBox(tint: PixelTint = .neutral)
        case search(tint: PixelTint = .neutral)
        case successCat(tint: PixelTint = .success)
        case growingPlant(tint: PixelTint = .success)

        /// SF Symbol fallback used when the figure is rendered at
        /// `.compact` size (where the pixel art is too detailed).
        var compactFallbackSymbol: String {
            switch self {
            case .sleepingCat:   return "moon.zzz"
            case .emptyBox:      return "tray"
            case .search:        return "magnifyingglass"
            case .successCat:    return "checkmark.circle"
            case .growingPlant:  return "leaf"
            }
        }
    }

    /// Internal figure representation — either a system symbol or a
    /// pixel illustration. Hidden behind two public initialisers.
    private enum Figure {
        case systemImage(String)
        case pixel(PixelFigure)
    }

    /// Optional CTA at the bottom of `.page` variant. Ignored on
    /// `.compact` and `.full` (those have no action slot by design).
    struct ActionConfig {
        let title: String
        let action: () -> Void
    }

    private let figure: Figure
    let title: String
    var description: String? = nil
    var size: Size = .full
    var action: ActionConfig? = nil

    // MARK: - Initialisers

    /// System-symbol initialiser. Use for `.compact` in-pill empties
    /// or when a simple line glyph carries the meaning better than a
    /// pixel figure.
    init(
        systemImage: String,
        title: String,
        description: String? = nil,
        size: Size = .full,
        action: ActionConfig? = nil
    ) {
        self.figure = .systemImage(systemImage)
        self.title = title
        self.description = description
        self.size = size
        self.action = action
    }

    /// Pixel-figure initialiser. Use for `.full` / `.page` empties
    /// where the figure should carry character. Compact size will
    /// auto-fall back to the figure's `compactFallbackSymbol`.
    init(
        figure: PixelFigure,
        title: String,
        description: String? = nil,
        size: Size = .full,
        action: ActionConfig? = nil
    ) {
        self.figure = .pixel(figure)
        self.title = title
        self.description = description
        self.size = size
        self.action = action
    }

    // MARK: - Body

    var body: some View {
        switch size {
        case .compact: compactBody
        case .full:    fullBody
        case .page:    pageBody
        }
    }

    // MARK: - Figure rendering

    /// 18pt SF Symbol glyph for compact rows. Pixel figures fall back
    /// to their `compactFallbackSymbol` because the pixel art doesn't
    /// read at this size.
    @ViewBuilder
    private var compactGlyph: some View {
        let symbolName: String = {
            switch figure {
            case .systemImage(let name): return name
            case .pixel(let pixel):      return pixel.compactFallbackSymbol
            }
        }()
        Image(systemName: symbolName)
            .font(.system(size: 18, weight: .light))
            .foregroundColor(AppColors.textTertiary)
    }

    /// Standard / hero figure rendering. For pixel figures, picks the
    /// matching illustration view at the given `PixelIllustrationSize`.
    /// For system symbols, renders a 36pt light glyph.
    @ViewBuilder
    private func fullGlyph(size illustrationSize: PixelIllustrationSize) -> some View {
        switch figure {
        case .systemImage(let name):
            Image(systemName: name)
                .font(.system(size: 36, weight: .light))
                .foregroundColor(AppColors.textTertiary)
        case .pixel(let pixel):
            pixelView(for: pixel, size: illustrationSize)
        }
    }

    @ViewBuilder
    private func pixelView(for figure: PixelFigure, size: PixelIllustrationSize) -> some View {
        switch figure {
        case .sleepingCat(let tint):
            SleepingCatIllustration(tint: tint, size: size)
        case .emptyBox(let tint):
            EmptyBoxIllustration(tint: tint, size: size)
        case .search(let tint):
            SearchIllustration(tint: tint, size: size)
        case .successCat(let tint):
            SuccessCatIllustration(tint: tint, size: size)
        case .growingPlant(let tint):
            GrowingPlantIllustration(tint: tint, size: size)
        }
    }

    // MARK: - Variants

    /// Inline: icon + title on one HStack row. Tertiary tone
    /// throughout — empty states are by definition de-emphasized
    /// content.
    private var compactBody: some View {
        HStack(spacing: AppSpacing.md) {
            compactGlyph
            Text(title)
                .font(AppFonts.caption)
                .foregroundColor(AppColors.textTertiary)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
    }

    /// Centered icon + title (+ optional description). Reserves
    /// vertical room (`padding(.vertical, 32)`) so the empty
    /// state has presence inside an otherwise empty screen.
    private var fullBody: some View {
        VStack(spacing: AppSpacing.md) {
            fullGlyph(size: .standard)
            Text(title)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textSecondary)
            if let description {
                Text(description)
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, AppSpacing.xxxl)
    }

    /// Hero — bigger icon, optional CTA button. Use for
    /// whole-screen empty states ("you have no data yet").
    private var pageBody: some View {
        VStack(spacing: AppSpacing.md) {
            fullGlyph(size: .hero)
            Text(title)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
            if let description {
                Text(description)
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.xxl)
            }
            if let action {
                Button(action: action.action) {
                    Text(action.title)
                        .font(AppFonts.bodySmall)
                        .foregroundColor(AppColors.accent)
                        .padding(.top, AppSpacing.xs)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }
}

// MARK: - Previews

#Preview("Compact — system symbol") {
    EmptyStateView(systemImage: "tray", title: "No data for this period", size: .compact)
        .padding()
        .background(AppColors.backgroundPrimary)
}

#Preview("Full — pixel sleeping cat") {
    EmptyStateView(
        figure: .sleepingCat(),
        title: "No transactions yet",
        description: "Add your first transaction to start tracking your spending."
    )
    .background(AppColors.backgroundPrimary)
}

#Preview("Page — growing plant") {
    EmptyStateView(
        figure: .growingPlant(),
        title: "Nothing to analyse yet",
        description: "Add a transaction to start seeing insights here.",
        size: .page
    )
    .background(AppColors.backgroundPrimary)
}

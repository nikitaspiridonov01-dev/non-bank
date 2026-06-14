import SwiftUI

/// "In April, you spent X more on Restaurants — meanwhile Groceries
/// dropped by Y." Surfaces a **single substitution pattern** in the
/// user's recent history: a month where one category went up
/// significantly AND another went down by a similar amount,
/// suggesting the user redirected spend from one habit to another.
///
/// Logic lives in `CategoryAnalyticsService.categoryCannibalization`.
/// Card hides itself when no qualifying pair is found in the last
/// `cannibalizationCandidateMonths` months.
///
/// **Why no icon?** Two emoji-tiles (one per category) competed
/// with the narrative for attention; a single icon would have
/// favoured one side of the substitution arbitrarily. Letting the
/// narrative carry the message keeps the card focused on the
/// substitution itself.
struct CategoryCannibalizationCard: View {

    /// Pre-computed analytics context — replaces the
    /// `transactionStore` / `categoryStore` / `currencyStore` trio
    /// + the `convert` / `emojiByCategory` boilerplate.
    let context: AnalyticsContext

    // MARK: - Derived

    private var event: CategoryAnalyticsService.CategoryCannibalization? {
        context.categoryCannibalization
    }

    // MARK: - Body

    var body: some View {
        Group {
            if let e = event {
                content(for: e)
            }
        }
    }

    private func content(for e: CategoryAnalyticsService.CategoryCannibalization) -> some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            narrative(for: e)
            subtitle
        }
        .insightCardShell()
    }

    // MARK: - Narrative

    /// Bold single-paragraph narrative — bright orange `accent` is
    /// reserved for clickable elements; non-clickable emphasis
    /// (month, both amounts, both categories) uses `accentBold`
    /// (deep warm sienna) — noticeable without competing with the
    /// clickable orange CTAs. "More"/"less" direction is already
    /// encoded in the verbs ("you spent X more on…" / "…dropped by
    /// Y"), so the earlier up/down green/red colour split was
    /// retired in favour of a single warm emphasis colour.
    private func narrative(for e: CategoryAnalyticsService.CategoryCannibalization) -> some View {
        let monthName = e.monthDate.formattedMonth()
        let upAmount = formatAmount(e.deltaUp)
        let downAmount = formatAmount(e.deltaDown)

        // Build the run as typed `Text` intermediates so each
        // sub-expression type-checks trivially — the long inline
        // `Text + Text` chain (with interleaved `.foregroundColor`)
        // overflowed the type-checker budget on Release builds.
        let intro: Text = plainSegment("In ") + emphasisSegment(monthName)
        let spent: Text = plainSegment(", you spent ") + emphasisSegment(upAmount)
        let onCategory: Text = plainSegment(" more on ") + emphasisSegment(e.categoryUp)
        let meanwhile: Text = plainSegment(" — meanwhile ") + emphasisSegment(e.categoryDown)
        let dropped: Text = plainSegment(" dropped by ") + emphasisSegment(downAmount)
        let end: Text = plainSegment(".")

        let firstHalf: Text = intro + spent + onCategory
        let secondHalf: Text = meanwhile + dropped + end
        let paragraph: Text = firstHalf + secondHalf

        return paragraph
            .font(AppFonts.titleSmall)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Non-emphasised run — primary text colour.
    private func plainSegment(_ string: String) -> Text {
        Text(string)
            .foregroundColor(AppColors.textPrimary)
    }

    /// Emphasised run — deep warm sienna `accentBold` (see the
    /// `narrative` doc-comment for why emphasis isn't the clickable
    /// orange `accent`).
    private func emphasisSegment(_ string: String) -> Text {
        Text(string)
            .foregroundColor(AppColors.accentBold)
    }

    // MARK: - Subtitle

    /// Tiny explainer — the cannibalization concept isn't
    /// self-evident from the narrative alone, so we name it
    /// directly so the user knows we're flagging a pattern, not
    /// a coincidence.
    private var subtitle: some View {
        Text("Looks like one category replaced another in your spending.")
            .font(AppFonts.caption)
            .foregroundColor(AppColors.textSecondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Formatting

    /// Non-breaking spaces glue the amount together so it wraps as
    /// one unit — see the matching helper in `BigPurchaseCard` for
    /// the full reasoning.
    private func formatAmount(_ value: Double) -> String {
        let int = NumberFormatting.integerPart(value)
        let dec = NumberFormatting.decimalPartIfAny(value)
        return "\(int)\(dec) \(context.targetCurrency)".replacingOccurrences(of: " ", with: "\u{00A0}")
    }

}

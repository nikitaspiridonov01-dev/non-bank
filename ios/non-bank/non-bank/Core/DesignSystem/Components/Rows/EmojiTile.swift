import SwiftUI

// MARK: - Emoji Tile
//
// Square rounded chip with a centred emoji glyph. Replaces the 8+
// inline implementations scattered across:
//   - `TransactionRowView` (40×40, 28pt emoji)
//   - `CategoryAmountRow`  (38×38, 20pt)
//   - `BigPurchaseCard`    (40×40, 22pt)
//   - `SmallExpensesListView` (40×40, 22pt)
//   - hero variants in `BigCategoryMonthCard`,
//     `SmallPurchasesCard`, `CategoryHistoryView` (60×60, 34pt)
//
// Provides a strict size scale so different surfaces feel like the
// same vocabulary. Custom sizes are still possible via the explicit
// initializer if a one-off layout demands it.
//
// Usage:
//
//     EmojiTile(emoji: "☕", size: .row)
//     EmojiTile(emoji: friend.emoji, size: .hero, background: .reminderBackgroundTint)

struct EmojiTile: View {

    /// Pre-canned size scale. Each preset bundles tile dimensions,
    /// emoji font size, and corner radius into one decision so
    /// callers don't drift on individual values.
    enum Size {
        /// 40×40 frame, 28pt emoji — primary scale for transaction
        /// list rows. Same as `AppSizes.emojiFrame`.
        case row
        /// 40×40 frame, 22pt emoji — compact pill-row variant
        /// (Insights cards' tappable rows).
        case compact
        /// 38×38 frame, 20pt emoji — slightly smaller compact for
        /// dense rows. Used by `CategoryAmountRow`.
        case dense
        /// 60×60 frame, 34pt emoji — standalone hero tile at the
        /// top of a narrative card.
        case hero
        /// 56×56 frame, 28pt emoji — alternate hero, smaller card
        /// inset.
        case heroCompact

        var frame: CGFloat {
            switch self {
            case .row, .compact: return 40
            case .dense: return 38
            case .hero: return 60
            case .heroCompact: return 56
            }
        }

        var emojiFont: Font {
            switch self {
            case .row: return AppFonts.emojiLarge          // 28
            case .compact: return AppFonts.emojiMedium     // 22
            case .dense: return Font.system(size: 20)
            case .hero: return AppFonts.emojiTile          // 34
            case .heroCompact: return AppFonts.emojiLarge  // 28
            }
        }

        var cornerRadius: CGFloat {
            switch self {
            case .row, .compact, .dense: return 9
            case .hero, .heroCompact: return AppRadius.rowPill  // 14
            }
        }
    }

    let emoji: String
    let size: Size
    var background: Color = AppColors.backgroundChip

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size.cornerRadius)
                .fill(background)
            Text(emoji)
                .font(size.emojiFont)
        }
        .frame(width: size.frame, height: size.frame)
    }
}

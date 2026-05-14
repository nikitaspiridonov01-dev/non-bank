import SwiftUI

/// Small inline icon that flags a non-product receipt line — discount,
/// fee, tax, or tip. Regular `.item` rows render nothing (the view
/// collapses), so callers can drop this in front of every item name
/// without adding a leading gap on the common case.
///
/// Discount keeps its existing visual language (`tag.fill` in success
/// green) so the bulk of historic receipts read identically. The other
/// three "proportional charge" kinds (fee / tax / tip) share a subdued
/// `textSecondary` tint so they read as a family — distinct from the
/// celebratory green discount, distinct from regular items, but not
/// fighting them for attention either.
struct ReceiptItemKindIcon: View {
    let kind: ReceiptItem.Kind
    var size: CGFloat = 12

    var body: some View {
        if let symbol = kind.iconSymbol {
            Image(systemName: symbol)
                .font(.system(size: size))
                .foregroundColor(kind.iconColor)
        }
    }
}

extension ReceiptItem.Kind {
    /// SF Symbol name for the kind, or `nil` when no icon should render
    /// (regular `.item` rows). Returning `nil` lets `ReceiptItemKindIcon`
    /// collapse to zero size in HStacks without callers having to branch.
    var iconSymbol: String? {
        switch self {
        case .item:     return nil
        case .discount: return "tag.fill"
        case .fee:      return "creditcard.fill"
        case .tax:      return "percent"
        case .tip:      return "hand.thumbsup.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .item:     return AppColors.textPrimary
        case .discount: return AppColors.success
        case .fee, .tax, .tip:
            return AppColors.textSecondary
        }
    }
}

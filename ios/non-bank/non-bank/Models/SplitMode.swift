import SwiftUI

/// How a split is calculated between participants.
///
/// The raw values are the wire/persistence format. `evenly`'s raw value is
/// preserved as `"50/50"` so existing rows in `transactions.split_info` and
/// `friends.split_mode` continue to decode without a backfill migration.
/// (Previously the only enabled case was the equal-split one with that
/// raw value; the other cases shipped as "Soon" placeholders and never
/// landed in real user data.)
enum SplitMode: String, Codable, CaseIterable, Identifiable {
    /// Equal share for everyone in the split.
    case evenly = "50/50"

    /// Each participant taps the receipt items they bought; their share
    /// is the sum of those items (shared items split equally between
    /// assignees), with fee/tax/tip distributed proportionally to each
    /// participant's item subtotal and discounts subtracted likewise.
    /// Available only when a receipt has been scanned and contains more
    /// than one product line.
    case byItems = "byItems"

    /// Each participant manually enters their share of the total. Also
    /// the wire format used when sharing a `byItems` transaction — the
    /// recipient sees the computed per-person amounts but not the items
    /// themselves (items aren't serialized into the share URL).
    case byAmount = "byAmount"

    /// One person pays the full amount, one other person owes it back —
    /// the canonical "I cover this for you, you'll pay me later" or
    /// "I'm settling my debt to you" case. Storage shape is identical
    /// to a 2-participant split with 100/0 paid + share, but tagging
    /// the mode preserves intent for the UI (subtitle, edit flow) and
    /// the wire payload. `buildTransaction` also auto-coerces other
    /// modes to `.settleUp` whenever the resulting shape ends up
    /// matching, so a user who picked `.evenly` and then assigned 100%
    /// to one friend still reads as "settle up" everywhere.
    case settleUp = "settleUp"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .evenly:   return "Evenly"
        case .byItems:  return "By items in receipt"
        case .byAmount: return "By amount"
        case .settleUp: return "Settle up"
        }
    }

    var iconName: String {
        switch self {
        case .evenly:   return "equal.circle.fill"
        // `viewfinder` mirrors the toolbar receipt-scan button —
        // byItems mode is the one that needs a scanned receipt to
        // do its work, so reusing the scan glyph signals "this mode
        // is the receipt-flow continuation" at a glance.
        case .byItems:  return "viewfinder"
        case .byAmount: return "number.circle.fill"
        case .settleUp: return "arrow.right.circle.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .evenly:   return .blue
        case .byItems:  return .green
        case .byAmount: return .purple
        case .settleUp: return .orange
        }
    }

    var helpText: String {
        switch self {
        case .evenly:   return "Split equally between everyone"
        case .byItems:  return "Each person pays for what they bought"
        case .byAmount: return "Enter each person's share manually"
        case .settleUp: return "One person pays for another"
        }
    }
}

/// A small circular icon badge for a split mode.
struct SplitModeIcon: View {
    let mode: SplitMode
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: mode.iconName)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size, alignment: .center)
            .background(mode.iconColor)
            .clipShape(Circle())
    }
}

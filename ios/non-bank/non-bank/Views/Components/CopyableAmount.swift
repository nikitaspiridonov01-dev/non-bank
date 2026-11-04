import SwiftUI
import UIKit

/// Long-press an amount → the system menu with "Copy amount". The mechanism
/// the transaction detail's hero amount introduced, shared so every
/// read-only amount — split shares, receipt lines, per-person slices,
/// totals — copies the same way.
extension View {
    /// - Parameter negative: prefix the "-" the row shows (a discount line),
    ///   so the clipboard holds what's on screen.
    func copyableAmount(_ amount: Double, currency: String, negative: Bool = false) -> some View {
        modifier(CopyableAmountModifier(text: CopyableAmount.text(amount, currency: currency, negative: negative)))
    }
}

enum CopyableAmount {
    /// The clipboard text: grouped amount with cents only when non-zero,
    /// then the currency code — "1 694.38 RSD", "585 RSD", "-400 RSD". It
    /// pastes back into the amount keypad (`ImportFieldParser` drops the code
    /// and the grouping spaces).
    static func text(_ amount: Double, currency: String, negative: Bool = false) -> String {
        "\(negative ? "-" : "")\(NumberFormatting.amount(amount)) \(currency)"
    }
}

private struct CopyableAmountModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            // The press registers on the gaps between glyphs too.
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy amount", systemImage: "doc.on.doc")
                }
            }
    }
}

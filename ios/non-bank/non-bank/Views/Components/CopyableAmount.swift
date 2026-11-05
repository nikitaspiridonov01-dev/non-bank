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
        copyableAmount(amount, currency: currency, negative: negative, in: Rectangle())
    }

    /// For a whole row: apply it to the row (after its `.glassEffect`), with
    /// the row's outline as `shape`. The press then lands anywhere on the
    /// row, not just on the small figure, and the lifted preview keeps the
    /// row's corners.
    ///
    /// On a glass row the menu has to sit on the row itself, and the row
    /// must be its own glass, not inside a `GlassEffectContainer`: a menu on
    /// the amount inside the glass, or on a row inside a container, doesn't
    /// open (1.0.6 build 16). `CopyableAmountMenuTests` checks the screens.
    func copyableAmount<S: Shape>(
        _ amount: Double,
        currency: String,
        negative: Bool = false,
        in shape: S
    ) -> some View {
        modifier(CopyableAmountModifier(
            text: CopyableAmount.text(amount, currency: currency, negative: negative),
            shape: shape
        ))
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

private struct CopyableAmountModifier<S: Shape>: ViewModifier {
    let text: String
    let shape: S

    func body(content: Content) -> some View {
        content
            // The press registers on the gaps between glyphs too; also the
            // outline of the lifted preview.
            .contentShape(shape)
            .contextMenu {
                Button {
                    UIPasteboard.general.string = text
                } label: {
                    Label("Copy amount", systemImage: "doc.on.doc")
                }
            }
    }
}

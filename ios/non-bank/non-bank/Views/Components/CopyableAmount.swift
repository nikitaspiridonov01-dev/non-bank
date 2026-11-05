import SwiftUI
import UIKit

/// Long-press an amount → the system menu with "Copy amount". The mechanism
/// the transaction detail's hero amount introduced, shared so every
/// read-only amount — split shares, receipt lines, per-person slices,
/// totals, debts — copies the same way.
extension View {
    /// On the amount itself, for an amount on plain content (the
    /// transaction card's hero amount).
    ///
    /// - Parameter negative: prefix the "-" the row shows (a discount line),
    ///   so the clipboard holds what's on screen.
    func copyableAmount(_ amount: Double, currency: String, negative: Bool = false) -> some View {
        modifier(CopyableAmountModifier(text: CopyableAmount.text(amount, currency: currency, negative: negative)))
    }

    /// For a whole row, `shape` being its outline: a long press anywhere on
    /// the row opens the menu, with the amount shown large above it. Apply
    /// it after the row's `.glassEffect`, and before an `.onTapGesture` so
    /// taps still reach that.
    ///
    /// The menu sits on a clear layer over the row rather than in the row:
    /// a menu inside a glass row didn't open (1.0.6 build 16). Over the
    /// glass it's plain content, like the hero amount.
    func copyableAmount<S: Shape>(
        _ amount: Double,
        currency: String,
        negative: Bool = false,
        in shape: S
    ) -> some View {
        modifier(CopyableRowModifier(
            amount: amount,
            currency: currency,
            negative: negative,
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

    static func copy(_ text: String) {
        UIPasteboard.general.string = text
    }
}

private struct CopyAmountButton: View {
    let text: String

    var body: some View {
        Button {
            CopyableAmount.copy(text)
        } label: {
            Label("Copy amount", systemImage: "doc.on.doc")
        }
    }
}

private struct CopyableAmountModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            // The press registers on the gaps between glyphs too.
            .contentShape(Rectangle())
            .contextMenu {
                CopyAmountButton(text: text)
            }
    }
}

private struct CopyableRowModifier<S: Shape>: ViewModifier {
    let amount: Double
    let currency: String
    let negative: Bool
    let shape: S

    private var text: String { CopyableAmount.text(amount, currency: currency, negative: negative) }

    func body(content: Content) -> some View {
        content
            .overlay {
                Color.clear
                    .contentShape(shape)
                    .contextMenu {
                        CopyAmountButton(text: text)
                    } preview: {
                        CopyableAmountPreview(amount: amount, currency: currency, negative: negative)
                    }
                    // VoiceOver gets the action on the row below instead.
                    .accessibilityHidden(true)
            }
            .accessibilityAction(named: Text("Copy amount")) {
                CopyableAmount.copy(text)
            }
    }
}

/// What lifts above the menu: the amount being copied, in the rows' own
/// type — bold integer, smaller decimals and currency.
private struct CopyableAmountPreview: View {
    let amount: Double
    let currency: String
    let negative: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("\(negative ? "-" : "")\(NumberFormatting.integerPart(amount))")
                .font(.system(size: 34, weight: .bold))
                .foregroundColor(negative ? AppColors.success : AppColors.textPrimary)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(.system(size: 22, weight: .medium))
                .foregroundColor(negative ? AppColors.success : AppColors.textSecondary)
            Text(currency)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 5)
        }
        .fixedSize()
        .padding(.horizontal, 24)
        .padding(.vertical, 18)
        .background(AppColors.backgroundElevated)
    }
}

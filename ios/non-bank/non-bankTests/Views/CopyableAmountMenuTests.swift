import XCTest
import SwiftUI
import UIKit
@testable import non_bank

/// Long-press "Copy amount" on the read-only split and receipt screens,
/// checked the way a touch reaches it: hit-test the pressed point, then ask
/// the context-menu interactions on the hit view and its ancestors for a
/// menu.
///
/// The probe sees a menu attached to a glass row's own view — the pattern
/// these screens use (`copyableAmount(_:currency:negative:in:)` after the
/// row's `.glassEffect`, the row not inside a `GlassEffectContainer`). It
/// can't see a menu on plain content (no glass), which SwiftUI resolves
/// only during a real touch, so there's no case for that here.
@MainActor
final class CopyableAmountMenuTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    /// A single row, hosted mid-screen (clear of the safe areas) in a
    /// 100 pt tall window: the row sits on y = 50.
    private func showRow<V: View>(_ view: V) throws -> UIWindow {
        try show(view.frame(maxWidth: .infinity, maxHeight: .infinity), frame: CGRect(x: 0, y: 300, width: 390, height: 100))
    }

    private func show<V: View>(_ view: V, frame: CGRect = CGRect(x: 0, y: 0, width: 390, height: 844)) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        window.rootViewController = UIHostingController(rootView: view)
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        self.window = window
        return window
    }

    private func menuInteractions(in view: UIView) -> [(view: UIView, interaction: UIContextMenuInteraction)] {
        view.interactions.compactMap { $0 as? UIContextMenuInteraction }.map { (view: view, interaction: $0) }
            + view.subviews.flatMap { menuInteractions(in: $0) }
    }

    /// Points along the row: the left edge (avatar, name) to the right
    /// edge (amount), on the row's middle line and 10 pt above and below.
    private var rowPoints: [CGPoint] {
        [40, 50, 60].flatMap { y in
            stride(from: CGFloat(25), through: 365, by: 20).map { CGPoint(x: $0, y: CGFloat(y)) }
        }
    }

    /// A whole screen: left, middle and right of every 20 pt line.
    private var screenPoints: [CGPoint] {
        stride(from: CGFloat(90), through: 830, by: 20).flatMap { y in
            [CGFloat(50), 195, 345].map { CGPoint(x: $0, y: y) }
        }
    }

    /// Of `points` (window coordinates), the ones where a long press would
    /// open a context menu, routed the way a touch is: hit-test the window,
    /// then ask the menu interactions on the hit view and its ancestors.
    /// Gives up after a time budget so a slow probe can't stall the run.
    private func menuPoints(_ points: [CGPoint], in window: UIWindow) -> [CGPoint] {
        let deadline = Date().addingTimeInterval(60)
        var opening: [CGPoint] = []
        for point in points {
            guard Date() < deadline else { break }
            var view = window.hitTest(point, with: nil)
            var opens = false
            while let current = view, !opens {
                for case let interaction as UIContextMenuInteraction in current.interactions {
                    let local = current.convert(point, from: window)
                    if interaction.delegate?.contextMenuInteraction(interaction, configurationForMenuAtLocation: local) != nil {
                        opens = true
                        break
                    }
                }
                view = current.superview
            }
            if opens { opening.append(point) }
        }
        return opening
    }

    private func summary(_ points: [CGPoint], in window: UIWindow) -> String {
        let found = menuInteractions(in: window)
        let hosts = found.map { String(describing: type(of: $0.view)) }.joined(separator: ", ")
        guard !points.isEmpty else {
            return "no menu at any probed point; \(found.count) menu interaction(s) on [\(hosts)]"
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return "\(points.count) points, x \(xs.min()!)...\(xs.max()!), y \(ys.min()!)...\(ys.max()!);"
            + " \(found.count) menu interaction(s) on [\(hosts)]"
    }

    private func probe(_ name: String, _ window: UIWindow, at points: [CGPoint]) -> [CGPoint] {
        print("Test case 'probe \(name): \(points.count) points, \(menuInteractions(in: window).count) interaction(s)'")
        let started = Date()
        let opening = menuPoints(points, in: window)
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("Test case 'probe \(name) done in \(ms) ms: \(summary(opening, in: window))'")
        return opening
    }

    // MARK: - Fixtures

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    private let me = ItemAssignmentParticipant(id: ReceiptItem.selfParticipantID, name: "You", isMe: true, isConnected: true)
    private let miha = ItemAssignmentParticipant(id: "miha", name: "Miha", isMe: false, isConnected: true)

    private var amount: some View {
        ReceiptItemAmountText(amount: 83.84, currency: "RSD")
    }

    // MARK: - The pattern

    /// A glass row with the menu on the row itself: a press on the name
    /// opens it, not just one on the amount.
    func testMenuOnAGlassRowOpensFromTheName() throws {
        let window = try showRow(
            HStack {
                Text("You")
                Spacer()
                amount
            }
            .padding(14)
            .glassEffect(.regular, in: shape)
            .copyableAmount(83.84, currency: "RSD", in: shape)
            .padding(.horizontal, 16)
        )
        let points = probe("standalone glass row", window, at: rowPoints)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
    }

    // MARK: - The screens

    /// The "Fee" sheet from the screenshot: each person's cut.
    func testFeeSheet_pressAnywhereOnARowCopies() throws {
        let fee = ReceiptItem(name: "Fee", quantity: nil, price: nil, total: 149.40, forcedKind: .fee)
        let window = try show(PerChargeDistributionSheet(
            charge: fee,
            currency: "RSD",
            claimants: [SplitClaimant(participant: me, slice: 83.84), SplitClaimant(participant: miha, slice: 65.56)]
        ))
        let points = probe("fee sheet", window, at: screenPoints)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
    }

    /// "Debts to settle up" on a split transaction: "You lent Miha 1 325.02".
    func testDebtRow_pressAnywhereCopiesTheAmountOwed() throws {
        let window = try showRow(
            DebtRowView(
                kind: .youLent(friendID: "miha", friendName: "Miha", amount: 1325.02),
                currency: "RSD",
                isConnected: true
            )
            .padding(.horizontal, 16)
        )
        let points = probe("debt row", window, at: rowPoints)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
        XCTAssertTrue(points.contains { $0.x > 300 }, summary(points, in: window))
    }

    /// A settled balance has no amount to copy.
    func testDebtRow_balancedOutHasNoMenu() throws {
        let window = try showRow(
            DebtRowView(kind: .balancesOut(friendID: "miha", friendName: "Miha"), currency: "RSD")
                .padding(.horizontal, 16)
        )
        let points = probe("balanced-out debt row", window, at: rowPoints)
        XCTAssertTrue(points.isEmpty, summary(points, in: window))
    }

    /// "Receipt items" from the transaction card: item, discount and fee
    /// rows (tappable, with avatar piles) and the total.
    func testReceiptItemsSheet_pressAnywhereOnARowCopies() throws {
        let items = [
            ReceiptItem(name: "Салат Оливье", quantity: nil, price: nil, total: 1170, assignedParticipantIDs: [me.id, miha.id]),
            ReceiptItem(name: "Рыбный суп", quantity: nil, price: nil, total: 1250, assignedParticipantIDs: [me.id]),
            ReceiptItem(name: "Discount", quantity: nil, price: nil, total: -400, forcedKind: .discount),
            ReceiptItem(name: "Fee", quantity: nil, price: nil, total: 149.40, forcedKind: .fee),
        ]
        let window = try show(ReceiptItemsReadOnlySheet(
            items: items,
            currency: "RSD",
            participants: [me.id: me, miha.id: miha]
        ))
        let points = probe("receipt items sheet", window, at: screenPoints)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
    }
}

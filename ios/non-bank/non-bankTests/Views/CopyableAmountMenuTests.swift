import XCTest
import SwiftUI
import UIKit
@testable import non_bank

/// Long-press "Copy amount" on the read-only split and receipt screens,
/// checked the way UIKit decides it: every context-menu interaction in the
/// window is asked for a menu at the pressed point.
@MainActor
final class CopyableAmountMenuTests: XCTestCase {

    private var window: UIWindow?

    override func tearDown() {
        window?.isHidden = true
        window = nil
        super.tearDown()
    }

    // MARK: - Harness

    private func show<V: View>(_ view: V) throws -> UIWindow {
        let scene = try XCTUnwrap(
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first,
            "the test host has no window scene"
        )
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
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

    /// Points of a 10 pt grid (window coordinates) where a long press
    /// would open a context menu.
    private func menuPoints(in window: UIWindow) -> [CGPoint] {
        let found = menuInteractions(in: window)
        var points: [CGPoint] = []
        for y in stride(from: CGFloat(5), to: window.bounds.height, by: 10) {
            for x in stride(from: CGFloat(5), to: window.bounds.width, by: 10) {
                let point = CGPoint(x: x, y: y)
                let opens = found.contains { entry in
                    let local = entry.view.convert(point, from: window)
                    guard entry.view.bounds.contains(local) else { return false }
                    return entry.interaction.delegate?.contextMenuInteraction(
                        entry.interaction,
                        configurationForMenuAtLocation: local
                    ) != nil
                }
                if opens { points.append(point) }
            }
        }
        return points
    }

    private func summary(_ points: [CGPoint], in window: UIWindow) -> String {
        let found = menuInteractions(in: window)
        let hosts = found.map { String(describing: type(of: $0.view)) }.joined(separator: ", ")
        guard !points.isEmpty else {
            return "no menu anywhere; \(found.count) menu interaction(s) on [\(hosts)]"
        }
        let xs = points.map(\.x), ys = points.map(\.y)
        return "\(points.count) points, x \(xs.min()!)...\(xs.max()!), y \(ys.min()!)...\(ys.max()!);"
            + " \(found.count) menu interaction(s) on [\(hosts)]"
    }

    private func probe(_ name: String, _ window: UIWindow) -> [CGPoint] {
        let points = menuPoints(in: window)
        print("Test case 'probe \(name): \(summary(points, in: window))'")
        return points
    }

    // MARK: - Fixtures

    private let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
    private let me = ItemAssignmentParticipant(id: ReceiptItem.selfParticipantID, name: "You", isMe: true, isConnected: true)
    private let miha = ItemAssignmentParticipant(id: "miha", name: "Miha", isMe: false, isConnected: true)

    private var amount: some View {
        ReceiptItemAmountText(amount: 83.84, currency: "RSD")
    }

    // MARK: - The pattern

    /// The harness itself: a menu on the amount, no glass around it.
    func testMenuOnAPlainAmountOpens() throws {
        let window = try show(
            HStack {
                Text("You")
                Spacer()
                amount.copyableAmount(83.84, currency: "RSD")
            }
            .padding(30)
        )
        let points = probe("plain amount", window)
        XCTAssertFalse(points.isEmpty, summary(points, in: window))
    }

    /// 1.0.6 (16): the menu sat on the amount inside the row's glass.
    func testMenuOnTheAmountInsideAGlassRow() throws {
        let window = try show(
            GlassEffectContainer {
                HStack {
                    Text("You")
                    Spacer()
                    amount.copyableAmount(83.84, currency: "RSD")
                }
                .padding(14)
                .glassEffect(.regular, in: shape)
            }
            .padding(.horizontal, 16)
        )
        let points = probe("amount inside glass", window)
        XCTAssertFalse(points.isEmpty, summary(points, in: window))
    }

    /// The fix: the menu on the whole row, outside its glass — a press on
    /// the name opens it too.
    func testMenuOnTheWholeGlassRowOpensFromTheName() throws {
        let window = try show(
            GlassEffectContainer {
                HStack {
                    Text("You")
                    Spacer()
                    amount
                }
                .padding(14)
                .glassEffect(.regular, in: shape)
                .copyableAmount(83.84, currency: "RSD", in: shape)
            }
            .padding(.horizontal, 16)
        )
        let points = probe("whole glass row", window)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
        XCTAssertTrue(points.contains { $0.x > 300 }, summary(points, in: window))
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
        let points = probe("fee sheet", window)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
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
        let points = probe("receipt items sheet", window)
        XCTAssertTrue(points.contains { $0.x < 100 }, summary(points, in: window))
    }
}

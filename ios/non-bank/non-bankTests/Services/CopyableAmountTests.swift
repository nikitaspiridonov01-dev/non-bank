import XCTest
@testable import non_bank

/// The text a long-press "Copy amount" puts on the clipboard — the same
/// on every read-only amount (split shares, receipt lines, per-person
/// slices, totals) as on the transaction detail's hero amount.
@MainActor
final class CopyableAmountTests: XCTestCase {

    func testText_readsLikeTheScreen() {
        XCTAssertEqual(CopyableAmount.text(1694.38, currency: "RSD"), "1 694.38 RSD")
        XCTAssertEqual(CopyableAmount.text(585, currency: "RSD"), "585 RSD")
        XCTAssertEqual(CopyableAmount.text(83.84, currency: "RSD"), "83.84 RSD")
        XCTAssertEqual(CopyableAmount.text(3019.4, currency: "RSD"), "3 019.40 RSD")
        // Rounded to cents, as displayed.
        XCTAssertEqual(CopyableAmount.text(12.996666, currency: "EUR"), "13 EUR")
    }

    /// A discount row shows "-224.46"; the copy carries the same minus.
    func testText_discountKeepsItsMinus() {
        XCTAssertEqual(CopyableAmount.text(-224.46, currency: "RSD", negative: true), "-224.46 RSD")
        XCTAssertEqual(CopyableAmount.text(-400, currency: "RSD"), "400 RSD")
    }

    /// Copied amounts paste back into the amount keypad.
    func testText_pastesBackAsTheSameNumber() {
        for (amount, negative) in [(1694.38, false), (3019.4, false), (585.0, false), (-224.46, true)] {
            let pasted = ImportFieldParser.parseAmountString(
                CopyableAmount.text(amount, currency: "RSD", negative: negative)
            )
            XCTAssertEqual(pasted ?? .nan, amount, accuracy: 0.001)
        }
    }
}

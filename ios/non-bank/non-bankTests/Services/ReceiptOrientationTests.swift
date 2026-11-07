import XCTest
import UIKit
import ImageIO
@testable import non_bank

/// A receipt photographed sideways or upside down is turned upright before
/// it's read; an upright one, or a photo without text, is left alone.
@MainActor
final class ReceiptOrientationTests: XCTestCase {

    private static let lines = [
        "MAXI SUPERMARKET",
        "BULEVAR OSLOBODJENJA 12",
        "PIB 100000001",
        "MLEKO 2.8% 1L          149.99",
        "HLEB BELI 500G          89.99",
        "JOGURT 1KG             179.99",
        "BANANE KG              219.99",
        "JAJA 10 KOM            299.99",
        "SIR GAUDA 300G         459.99",
        "SAPUN TECNI 1L         329.99",
        "CAJ KAMILICA            99.99",
        "KAFA 200G              389.99",
        "PAPIR TOALETNI         549.99",
        "VODA 1.5L               69.99",
        "SOK JABUKA 1L          189.99",
        "COKOLADA 100G          159.99",
        "KEKS 200G              129.99",
        "PASTA 500G             139.99",
        "ULJE 1L                249.99",
        "SECER 1KG              119.99",
        "UKUPNO                4157.78",
        "GOTOVINA              5000.00",
        "HVALA NA POSETI",
    ]

    /// The receipt as printed: black monospaced lines on white.
    private func receipt() -> UIImage {
        let size = CGSize(width: 640, height: 1040)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 26, weight: .regular),
            .foregroundColor: UIColor.black,
        ]
        return render(size) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            for (index, line) in Self.lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 30, y: 40 + CGFloat(index) * 42), withAttributes: attributes)
            }
        }
    }

    /// An app's order screen, as a screenshot: each price on the line under
    /// its item, on the left; only the total on the right.
    private func orderScreenshot() -> UIImage {
        let size = CGSize(width: 750, height: 1334)
        let title: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 40, weight: .bold),
            .foregroundColor: UIColor.black,
        ]
        let body: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 30, weight: .regular),
            .foregroundColor: UIColor.black,
        ]
        let items = [
            ("Margherita pizza", "12.90 EUR"),
            ("Caesar salad", "8.50 EUR"),
            ("Lemonade, large", "3.20 EUR"),
            ("Tiramisu", "5.40 EUR"),
            ("Delivery", "2.99 EUR"),
            ("Service fee", "0.99 EUR"),
        ]
        return render(size) { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            ("Your order" as NSString).draw(at: CGPoint(x: 40, y: 60), withAttributes: title)
            for (index, (name, price)) in items.enumerated() {
                let y = 150 + CGFloat(index) * 110
                (name as NSString).draw(at: CGPoint(x: 40, y: y), withAttributes: body)
                (price as NSString).draw(at: CGPoint(x: 40, y: y + 44), withAttributes: body)
            }
            let total = "33.98 EUR" as NSString
            ("Total" as NSString).draw(at: CGPoint(x: 40, y: 840), withAttributes: body)
            total.draw(at: CGPoint(x: size.width - 40 - total.size(withAttributes: body).width, y: 840), withAttributes: body)
        }
    }

    /// `image`'s pixels turned the way `orientation` displays them.
    private func turned(_ image: UIImage, _ orientation: UIImage.Orientation) -> UIImage {
        let flagged = UIImage(cgImage: image.cgImage!, scale: 1, orientation: orientation)
        return render(flagged.size) { _ in flagged.draw(in: CGRect(origin: .zero, size: flagged.size)) }
    }

    private func render(_ size: CGSize, _ draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }

    private func orientation(of image: UIImage) -> CGImagePropertyOrientation {
        ReceiptOrientation.textOrientation(of: image.cgImage!)
    }

    func testUprightReceiptIsLeftAsItIs() {
        let original = receipt()
        XCTAssertEqual(orientation(of: original), .up)
        XCTAssertTrue(ReceiptOrientation.uprighted(original) === original)
    }

    /// Prices on the left are that screen's layout, not a sign it's upside
    /// down.
    func testUprightScreenshotWithPricesOnTheLeftIsLeftAsItIs() {
        let screenshot = orderScreenshot()
        let reading = ReceiptOrientation.reading(of: screenshot.cgImage!, orientation: .up)
        // The layout this is about: the prices read, on the left.
        XCTAssertGreaterThanOrEqual(reading.amountsLeft, ReceiptOrientation.minimumAmounts)
        XCTAssertEqual(orientation(of: screenshot), .up)
        XCTAssertTrue(ReceiptOrientation.uprighted(screenshot) === screenshot)
    }

    /// Turned a quarter one way, the receipt reads upright a quarter the
    /// other way.
    func testQuarterTurnedReceiptIsFound() {
        XCTAssertEqual(orientation(of: turned(receipt(), .right)), .left)
        XCTAssertEqual(orientation(of: turned(receipt(), .left)), .right)
    }

    func testUpsideDownReceiptIsFound() {
        XCTAssertEqual(orientation(of: turned(receipt(), .down)), .down)
    }

    /// Turned back, the receipt reads as printed: amounts on the right.
    func testTurnedReceiptComesBackUpright() {
        let original = receipt()
        for turn in [UIImage.Orientation.right, .left, .down] {
            let upright = ReceiptOrientation.uprighted(turned(original, turn))
            XCTAssertEqual(upright.size, original.size, "\(turn.rawValue)")
            let reading = ReceiptOrientation.reading(of: upright.cgImage!, orientation: .up)
            XCTAssertGreaterThanOrEqual(reading.amountsRight, 10, "\(turn.rawValue)")
            XCTAssertEqual(reading.amountsLeft, 0, "\(turn.rawValue)")
        }
    }

    // MARK: - What the decision rests on

    /// Amounts close the receipt's lines, right-aligned: read upright,
    /// they're on the right.
    func testUprightReadingHasTheAmountsOnTheRight() {
        let reading = ReceiptOrientation.reading(of: receipt().cgImage!, orientation: .up)
        XCTAssertGreaterThanOrEqual(reading.amountsRight, 10)
        XCTAssertEqual(reading.amountsLeft, 0)
    }

    /// Vision's coordinates are those of the image turned the way it was
    /// asked to read it: an upside-down receipt read upside down has its
    /// amounts on the right too.
    func testReadingTurnedTheRightWayHasTheAmountsOnTheRight() {
        let reading = ReceiptOrientation.reading(of: turned(receipt(), .down).cgImage!, orientation: .down)
        XCTAssertGreaterThanOrEqual(reading.amountsRight, 10)
    }

    func testAmountsOnTheRightDecide() {
        typealias Reading = ReceiptOrientation.Reading
        let garbled = Reading(readability: 280, amountsRight: 1, amountsLeft: 0)
        let upright = Reading(readability: 300, amountsRight: 12, amountsLeft: 0)
        XCTAssertEqual(ReceiptOrientation.pick(.up, garbled, or: .down, upright), .down)
        XCTAssertEqual(ReceiptOrientation.pick(.up, upright, or: .down, garbled), .up)
    }

    /// Amounts on the left of one reading don't count for the opposite
    /// one; with nothing else clear, no way is picked.
    func testAmountsOnTheLeftDecideNothing() {
        typealias Reading = ReceiptOrientation.Reading
        let screenshot = Reading(readability: 300, amountsRight: 1, amountsLeft: 6)
        let upsideDown = Reading(readability: 280, amountsRight: 0, amountsLeft: 0)
        XCTAssertNil(ReceiptOrientation.pick(.up, screenshot, or: .down, upsideDown))
    }

    /// No amounts to go by: the clearly more readable way, else none.
    func testReadabilityDecidesWithoutAmounts() {
        typealias Reading = ReceiptOrientation.Reading
        XCTAssertEqual(
            ReceiptOrientation.pick(.right, Reading(readability: 200), or: .left, Reading(readability: 60)),
            .right
        )
        XCTAssertNil(ReceiptOrientation.pick(.right, Reading(readability: 200), or: .left, Reading(readability: 150)))
        XCTAssertNil(ReceiptOrientation.pick(.right, Reading(readability: 20), or: .left, Reading(readability: 5)))
    }

    func testTrailingAmount() {
        func amount(_ line: String) -> String? {
            ReceiptOrientation.trailingAmount(in: line).map { String(line[$0]) }
        }
        XCTAssertEqual(amount("MLEKO 2.8% 1L          149.99"), "149.99")
        XCTAssertEqual(amount("UKUPNO 4.157,78 A"), "4.157,78")
        XCTAssertEqual(amount("GOTOVINA 5000.00"), "5000.00")
        XCTAssertEqual(amount("89,99"), "89,99")
        XCTAssertEqual(amount("TOTAL 12.50 EUR"), "12.50")
        XCTAssertNil(amount("HVALA NA POSETI"))
        XCTAssertNil(amount("PIB 100000001"))
        XCTAssertNil(amount("JAJA 10 KOM"))
    }

    /// A receipt that fills only part of a full-size camera photo, lying
    /// across the frame: found on the downscaled copy, turned at full size.
    func testReceiptAcrossALargePhotoIsTurned() {
        let photoSize = CGSize(width: 3000, height: 4000)
        let receiptImage = receipt()
        let photo = render(photoSize) { context in
            UIColor(white: 0.55, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: photoSize))
            let size = CGSize(width: receiptImage.size.width * 2.6, height: receiptImage.size.height * 2.6)
            receiptImage.draw(in: CGRect(
                x: (photoSize.width - size.width) / 2,
                y: (photoSize.height - size.height) / 2,
                width: size.width,
                height: size.height
            ))
        }
        let sideways = turned(photo, .right)
        XCTAssertEqual(orientation(of: sideways), .left)
        let upright = ReceiptOrientation.uprighted(sideways)
        XCTAssertEqual(upright.size, photoSize)
    }

    /// The camera's own orientation flag is applied first: a photo whose
    /// flag already shows it upright isn't turned any further.
    func testCameraFlagIsAppliedFirst() {
        let pixelsSideways = turned(receipt(), .left)
        let flagged = UIImage(cgImage: pixelsSideways.cgImage!, scale: 1, orientation: .right)
        let upright = ReceiptOrientation.uprighted(flagged)
        XCTAssertEqual(upright.size, receipt().size)
        XCTAssertEqual(orientation(of: upright), .up)
    }

    func testPhotoWithoutTextIsLeftAlone() {
        let blank = render(CGSize(width: 900, height: 1200)) { context in
            UIColor(white: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 1200))
        }
        XCTAssertEqual(orientation(of: blank), .up)
        XCTAssertEqual(orientation(of: turned(blank, .right)), .up)
    }
}

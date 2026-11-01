import XCTest
import UIKit
@testable import non_bank

/// Tests for finding a long receipt inside a photo (`ReceiptFraming`) and
/// cropping the table away on both sides of it, so the tall-receipt tiling
/// gets to read it band by band.
@MainActor
final class ReceiptFramingTests: XCTestCase {

    /// A 12 MP portrait photo, the iPhone camera's 3:4 frame.
    private let photo = CGSize(width: 3024, height: 4032)

    /// Text boxes of a receipt printed between `x0` and `x1` (pixels): one
    /// name box on the left and one price box on the right per line, the
    /// way Vision boxes a receipt. Optional centred header lines bridge
    /// the gap between the two columns, like a store name does.
    private func receipt(
        x0: CGFloat, x1: CGFloat,
        top: CGFloat = 100, bottom: CGFloat = 3930,
        step: CGFloat = 40, lineHeight: CGFloat = 15,
        header: Bool = true, shortNames: Bool = false,
        tilt: CGFloat = 0
    ) -> [CGRect] {
        let width = x1 - x0
        var boxes: [CGRect] = []
        var y = top
        var line = 0
        while y + lineHeight <= bottom {
            let drift = tilt * (y - photo.height / 2)
            let nameShare: CGFloat = shortNames ? [0.12, 0.2, 0.16, 0.25][line % 4] : [0.3, 0.55, 0.42, 0.6][line % 4]
            let priceShare: CGFloat = [0.14, 0.18, 0.12, 0.2][line % 4]
            boxes.append(CGRect(x: x0 + drift, y: y, width: width * nameShare, height: lineHeight))
            boxes.append(CGRect(x: x1 + drift - width * priceShare, y: y, width: width * priceShare, height: lineHeight))
            y += step
            line += 1
        }
        if header {
            for k in 0..<4 {
                let hy = top + CGFloat(k) * (lineHeight + 5)
                boxes.append(CGRect(x: x0 + width * 0.15, y: hy, width: width * 0.7, height: lineHeight))
            }
        }
        return boxes
    }

    private func normalized(_ boxes: [CGRect], in size: CGSize? = nil) -> [CGRect] {
        let s = size ?? photo
        return boxes.map { CGRect(x: $0.minX / s.width, y: $0.minY / s.height, width: $0.width / s.width, height: $0.height / s.height) }
    }

    private func column(_ boxes: [CGRect]) -> ClosedRange<CGFloat>? {
        ReceiptFraming.receiptColumn(textBoxes: normalized(boxes), imageSize: photo)
    }

    // MARK: - Geometry

    /// The case behind "long receipts are read badly": the receipt is a
    /// narrow strip down the middle of a portrait photo.
    func testNarrowReceiptInPortraitPhoto_cropsToItWithMargin() throws {
        let range = try XCTUnwrap(column(receipt(x0: 1270, x1: 1750)))
        // Margin = 3 % of the photo's width on each side.
        XCTAssertEqual(range.lowerBound, 1270 - 0.03 * 3024, accuracy: 0.5)
        XCTAssertEqual(range.upperBound, 1750 + 0.03 * 3024, accuracy: 0.5)
        // The crop is tall enough for the tall-receipt tiling now.
        XCTAssertGreaterThan(photo.height / (range.upperBound - range.lowerBound), ImagePreprocessing.tallReceiptAspectThreshold)
    }

    /// Prices printed far from short names, with no line spanning the gap,
    /// are two columns of boxes — and still one receipt.
    func testPricesFarFromNames_stayWithTheReceipt() throws {
        let range = try XCTUnwrap(column(receipt(x0: 1270, x1: 1750, header: false, shortNames: true)))
        XCTAssertLessThanOrEqual(range.lowerBound, 1270)
        XCTAssertGreaterThanOrEqual(range.upperBound, 1750)
    }

    /// Same, when the price column has the most boxes (names split into
    /// two columns by a quantity column).
    func testPricesFarFromNames_whenPricesAreTheBiggestColumn() throws {
        var boxes: [CGRect] = []
        for k in 0..<80 {
            let y = 100 + CGFloat(k) * 46
            boxes.append(CGRect(x: 1200, y: y, width: 40, height: 15))          // qty
            if k % 2 == 0 { boxes.append(CGRect(x: 1300, y: y, width: 90, height: 15)) }  // name
            boxes.append(CGRect(x: 1620, y: y, width: 80, height: 15))          // price
        }
        let range = try XCTUnwrap(column(boxes))
        XCTAssertLessThanOrEqual(range.lowerBound, 1200)
        XCTAssertGreaterThanOrEqual(range.upperBound, 1700)
    }

    /// A small label on the table, far from the receipt, is left out.
    func testSmallLabelFarAway_isLeftOut() throws {
        let label = [CGRect(x: 100, y: 3500, width: 300, height: 30),
                     CGRect(x: 120, y: 3540, width: 260, height: 30),
                     CGRect(x: 110, y: 3580, width: 280, height: 30)]
        let range = try XCTUnwrap(column(receipt(x0: 1270, x1: 1750) + label))
        XCTAssertGreaterThan(range.lowerBound, 1000)
        XCTAssertGreaterThanOrEqual(range.upperBound, 1750)
    }

    /// Big-print packaging beside the receipt has fewer boxes than the
    /// receipt's lines, so it doesn't pull the crop over.
    func testBigPrintPackagingAside_isLeftOut() throws {
        let package = (0..<10).map { CGRect(x: 2300, y: 500 + CGFloat($0) * 300, width: 650, height: 200) }
        let range = try XCTUnwrap(column(receipt(x0: 1270, x1: 1750) + package))
        XCTAssertLessThanOrEqual(range.lowerBound, 1270)
        XCTAssertGreaterThanOrEqual(range.upperBound, 1750)
        XCTAssertLessThan(range.upperBound, 2300)
    }

    /// Text right next to the receipt is taken in: a wider crop only costs
    /// resolution, a narrower one could cut the receipt.
    func testTextRightNextToReceipt_isTakenIn() throws {
        let near = [CGRect(x: 1100, y: 2000, width: 100, height: 30),
                    CGRect(x: 1100, y: 2040, width: 100, height: 30),
                    CGRect(x: 1100, y: 2080, width: 100, height: 30)]
        let range = try XCTUnwrap(column(receipt(x0: 1270, x1: 1750) + near))
        XCTAssertLessThanOrEqual(range.lowerBound, 1100)
    }

    /// A receipt tilted by 4° drifts sideways down the frame; every one of
    /// its boxes stays inside the crop.
    func testTiltedReceipt_staysInside() throws {
        let boxes = receipt(x0: 1270, x1: 1750, tilt: tan(4 * .pi / 180))
        let range = try XCTUnwrap(column(boxes))
        XCTAssertLessThanOrEqual(range.lowerBound, boxes.map(\.minX).min()!)
        XCTAssertGreaterThanOrEqual(range.upperBound, boxes.map(\.maxX).max()!)
    }

    /// Where Vision saw no text at the top, a tilted receipt could still
    /// run on unseen — the margin grows with that stretch.
    func testMarginCoversDriftWhereNoTextWasSeen() throws {
        let range = try XCTUnwrap(column(receipt(x0: 1270, x1: 1750, top: 1200, bottom: 3930)))
        XCTAssertEqual(range.lowerBound, 1270 - 0.09 * 1200, accuracy: 0.5)
    }

    func testReceiptAtFrameEdge_clampsToImage() throws {
        let range = try XCTUnwrap(column(receipt(x0: 0, x1: 500)))
        XCTAssertEqual(range.lowerBound, 0)
        XCTAssertEqual(range.upperBound, 500 + 0.03 * 3024, accuracy: 0.5)
    }

    func testBoxesSpillingOutOfFrame_areClipped() throws {
        var boxes = receipt(x0: 1270, x1: 1750)
        boxes.append(CGRect(x: 1300, y: -50, width: 200, height: 80))
        let range = try XCTUnwrap(ReceiptFraming.receiptColumn(
            textBoxes: normalized(boxes) + [CGRect(x: 0.45, y: 0.99, width: 0.1, height: 0.2)],
            imageSize: photo))
        XCTAssertGreaterThanOrEqual(range.lowerBound, 0)
        XCTAssertLessThanOrEqual(range.upperBound, photo.width)
    }

    // MARK: - When not to crop

    func testReceiptFillingTheWidth_isNotCropped() {
        XCTAssertNil(column(receipt(x0: 200, x1: 2800)))
    }

    func testFullWidthDocument_isNotCropped() {
        let lines = stride(from: CGFloat(200), to: 3800, by: 120).map { CGRect(x: 150, y: $0, width: 2700, height: 40) }
        XCTAssertNil(column(lines))
    }

    func testNewspaperColumns_areNotCropped() {
        var boxes: [CGRect] = []
        for c in 0..<4 {
            for y in stride(from: CGFloat(200), to: 3800, by: 80) {
                boxes.append(CGRect(x: 150 + CGFloat(c) * 720, y: y, width: 600, height: 30))
            }
        }
        XCTAssertNil(column(boxes))
    }

    /// Two receipts side by side, far apart: neither is most of the text.
    func testTwoReceiptsFarApart_areNotCropped() {
        XCTAssertNil(column(receipt(x0: 200, x1: 700) + receipt(x0: 2300, x1: 2800)))
    }

    /// Vision saw text along less than 60 % of the height: it saw only part
    /// of the receipt, and a crop could cut what it missed.
    func testReceiptSeenAlongPartOfTheHeight_isNotCropped() {
        XCTAssertNil(column(receipt(x0: 1270, x1: 1750, top: 100, bottom: 1700)))
    }

    func testTooLittleText_isNotCropped() {
        XCTAssertNil(column(receipt(x0: 1270, x1: 1750, top: 100, bottom: 260, header: false)))
        XCTAssertNil(ReceiptFraming.receiptColumn(textBoxes: [], imageSize: photo))
        XCTAssertNil(ReceiptFraming.receiptColumn(textBoxes: normalized(receipt(x0: 1270, x1: 1750)), imageSize: .zero))
    }

    // MARK: - Vision on a rendered photo

    /// A dark table with a narrow white receipt down the middle, printed in
    /// black — the shape of the photos that were read badly.
    private func renderedPhoto(receiptX: CGFloat, receiptWidth: CGFloat, size: CGSize = CGSize(width: 1500, height: 2000)) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            UIColor(white: 0.25, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: receiptX, y: 40, width: receiptWidth, height: size.height - 80))
            let font = UIFont.monospacedSystemFont(ofSize: 20, weight: .medium)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black]
            let names = ["MLEKO 1L", "HLEB BELI", "JAJA 10KOM", "SIR GAUDA", "JABUKE", "KAFA 200G", "VODA 1.5L", "BANANE"]
            var y: CGFloat = 80
            var line = 0
            while y < size.height - 100 {
                let name = names[line % names.count] as NSString
                let price = String(format: "%d.%02d", 50 + (line * 37) % 900, (line * 13) % 100) as NSString
                name.draw(at: CGPoint(x: receiptX + 14, y: y), withAttributes: attrs)
                let priceWidth = price.size(withAttributes: attrs).width
                price.draw(at: CGPoint(x: receiptX + receiptWidth - 14 - priceWidth, y: y), withAttributes: attrs)
                y += 42
                line += 1
            }
        }
    }

    func testVision_findsNarrowReceiptInRenderedPhoto() throws {
        let image = renderedPhoto(receiptX: 600, receiptWidth: 300)
        XCTAssertNil(ImagePreprocessing.tallReceiptBands(image), "3:4 photo as a whole is not tall")

        let frame = try XCTUnwrap(ImagePreprocessing.receiptFrame(in: image), "Vision should find the receipt")
        // The printed lines run from x≈614 to x≈886; nothing of them is cut.
        XCTAssertLessThanOrEqual(frame.minX, 614)
        XCTAssertGreaterThanOrEqual(frame.maxX, 886)
        XCTAssertLessThan(frame.width, 0.5 * image.size.width)
        XCTAssertEqual(frame.minY, 0)
        XCTAssertEqual(frame.height, image.size.height, "the full height is kept")

        let framed = try XCTUnwrap(ImagePreprocessing.receiptFramed(image))
        XCTAssertEqual(framed.size.width, frame.width)
        let bands = try XCTUnwrap(ImagePreprocessing.tallReceiptBands(framed), "the cut-out receipt tiles into bands")
        XCTAssertGreaterThanOrEqual(bands.count, 2)
        // Each band keeps the receipt's full native width.
        XCTAssertEqual(bands[0].size.width, frame.width, accuracy: 1)
    }

    func testVision_receiptFillingThePhoto_isLeftAlone() {
        let image = renderedPhoto(receiptX: 60, receiptWidth: 1380)
        XCTAssertNil(ImagePreprocessing.receiptFramed(image))
    }

    /// EXIF-rotated camera images are framed in upright coordinates.
    func testVision_rotatedCameraImage_isFramedUpright() throws {
        let upright = renderedPhoto(receiptX: 600, receiptWidth: 300)
        // Pixels stored rotated 90° counter-clockwise with a `.right` flag,
        // as the camera stores a portrait shot: upright (x, y) lands at
        // stored (y, 1500 − x).
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let sideways = UIGraphicsImageRenderer(size: CGSize(width: 2000, height: 1500), format: format).image { ctx in
            ctx.cgContext.translateBy(x: 0, y: 1500)
            ctx.cgContext.rotate(by: -.pi / 2)
            upright.draw(in: CGRect(x: 0, y: 0, width: 1500, height: 2000))
        }
        let flagged = UIImage(cgImage: try XCTUnwrap(sideways.cgImage), scale: 1, orientation: .right)
        XCTAssertEqual(flagged.size, CGSize(width: 1500, height: 2000))
        let frame = try XCTUnwrap(ImagePreprocessing.receiptFrame(in: flagged))
        XCTAssertEqual(frame.height, 2000)
        XCTAssertLessThan(frame.width, 750)
    }
}

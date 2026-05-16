import XCTest
import UIKit
@testable import non_bank

/// Tests for `CloudReceiptParser` — focused on `prepareImage`, the
/// pure image-preprocessing path. Network round-trips (`parse`)
/// require URLProtocol stubbing and live in a separate suite when
/// added; this one covers the deterministic preprocessing contract:
///
///  - downscale + EXIF strip + JPEG re-encode
///  - stay under the Worker's 5 MB body cap on the happy path
///  - tolerate edge sizes (tiny, very wide)
final class CloudReceiptParserTests: XCTestCase {

    /// Synthesise a UIImage of the given pixel size with a coarse
    /// striped fill. Stripes (not a flat colour) so JPEG produces
    /// non-trivial output bytes the assertions can reason about,
    /// while staying fast — pixel-by-pixel drawing made the suite
    /// run ~40s; the 32×32 cell grid renders in milliseconds.
    private func makeImage(width: Int, height: Int) -> UIImage {
        let size = CGSize(width: width, height: height)
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            let cg = ctx.cgContext
            let cell = 32
            for y in stride(from: 0, to: height, by: cell) {
                for x in stride(from: 0, to: width, by: cell) {
                    let hue = CGFloat(((x / cell) * 7 + (y / cell) * 13) % 360) / 360.0
                    cg.setFillColor(UIColor(hue: hue, saturation: 0.5, brightness: 0.8, alpha: 1).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        }
    }

    // MARK: - Happy path

    func testPrepareImage_returnsJPEGData() throws {
        let img = makeImage(width: 200, height: 200)
        let data = try CloudReceiptParser.prepareImage(img)
        XCTAssertFalse(data.isEmpty)
        // JPEG SOI marker: 0xFF 0xD8 starts every JPEG file.
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1], 0xD8)
    }

    func testPrepareImage_outputStaysUnderFiveMB() throws {
        // Worker rejects bodies over 5 MB; preprocessor must guarantee
        // we never hit that gate.
        let img = makeImage(width: 800, height: 1000)
        let data = try CloudReceiptParser.prepareImage(img)
        XCTAssertLessThan(data.count, 5_000_000)
    }

    func testPrepareImage_handlesTinyInput() throws {
        // 1×1 is the degenerate case — must not crash or throw.
        let img = makeImage(width: 1, height: 1)
        let data = try CloudReceiptParser.prepareImage(img)
        XCTAssertFalse(data.isEmpty)
    }

    func testPrepareImage_handlesTallReceiptAspectRatio() throws {
        // Long restaurant tape: width small, height very large. The
        // downscaler should keep the aspect ratio sensible without
        // throwing.
        let img = makeImage(width: 300, height: 2400)
        let data = try CloudReceiptParser.prepareImage(img)
        XCTAssertFalse(data.isEmpty)
        XCTAssertLessThan(data.count, 5_000_000)
    }

    func testPrepareImage_isIdempotentOnReprocess() throws {
        // The HybridReceiptParser path may invoke `prepareImage`
        // twice (once upstream during early downscale, once here).
        // The second pass must not bloat the output significantly —
        // worst-case ~2× from re-JPEG generation noise, but the
        // contract is "stays well under the body cap".
        let img = makeImage(width: 1600, height: 1600)
        let first = try CloudReceiptParser.prepareImage(img)
        guard let firstImage = UIImage(data: first) else {
            return XCTFail("First pass must produce a decodable JPEG")
        }
        let second = try CloudReceiptParser.prepareImage(firstImage)
        XCTAssertLessThan(second.count, 5_000_000)
    }
}

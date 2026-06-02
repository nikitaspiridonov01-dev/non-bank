import UIKit
import CoreImage

/// Shared image-preparation helpers used by every receipt-parsing path
/// (cloud upload, local Vision OCR, Foundation Models).
///
/// Centralising the downscale here so all three parser entry points
/// see the same memory ceiling. Previously only `CloudReceiptParser`
/// downscaled before upload; the local fallback (`ReceiptOCRService`)
/// handed Vision the original `UIImage` straight from the camera,
/// which on a 12 MP iPhone photo is ~36 MB of decoded pixels —
/// enough to spike memory on older devices when the Vision pipeline
/// holds two buffers at once.
enum ImagePreprocessing {

    /// Long-edge ceiling for receipt images across all parser paths.
    /// 2560 gives roughly 56 % more pixels than the prior 2048 cap —
    /// the extra resolution buys back legibility on items printed
    /// near the top/bottom edges of long supermarket receipts, where
    /// at 2048 the font landed close to Vision's recognition floor
    /// and edge items occasionally dropped out of the parse. Memory
    /// cost stays bounded (still well under a stock 12 MP shot's raw
    /// pixel count) and every supported cloud vision model accepts
    /// 2560 along its long edge.
    ///
    /// Tunable: bump to 3072 only if dense receipts still miss
    /// items; drop back to 2048 if memory crashes reappear on
    /// low-end devices.
    static let receiptMaxDimension: CGFloat = 2560

    /// Downscale so the longest edge is at most `maxDimension`.
    /// Idempotent — an already-small image returns unchanged (no
    /// re-render). Uses `UIGraphicsImageRenderer` with scale=1 so
    /// the output `UIImage` has no Retina-multiplier baggage; the
    /// receipt parsers don't care about display density.
    static func downscaled(
        _ image: UIImage,
        maxDimension: CGFloat = receiptMaxDimension
    ) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: target, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
    }

    // MARK: - Tall-receipt tiling

    /// Height/width ratio above which a receipt is "very tall" and gets
    /// split into bands. 2.4 ≈ a long supermarket tape; restaurant bills
    /// and normal receipts sit below this and parse fine whole. Tuned
    /// conservatively so only the receipts that actually defeat a single
    /// vision-model pass (the whole strip compressed into the model's
    /// token budget → small text → dropped lines) get the multi-call
    /// treatment.
    static let tallReceiptAspectThreshold: CGFloat = 2.4

    /// Per-band long-edge ceiling. Higher than the whole-image cap
    /// because a band is only a slice of the height, so the same long
    /// edge buys a WIDER band — and width (legible text) is exactly what
    /// a tall narrow receipt lacks. A 1200-px-wide original keeps its
    /// width here instead of being squashed to ~540 by the whole-image
    /// 2560 cap.
    static let bandMaxDimension: CGFloat = 2200

    /// Split a very tall receipt into overlapping horizontal bands so a
    /// vision model can resolve every line. Crops from the orientation-
    /// normalised FULL-resolution source (not the 2560-capped one) so
    /// each band keeps maximal width, then downscales each band to
    /// `bandMaxDimension`. The overlap guarantees every line is fully
    /// visible in at least one band (a line sliced by one band's edge is
    /// whole in its neighbour). Returns `nil` when the image isn't tall
    /// enough to need tiling — callers then take the single-image path.
    static func tallReceiptBands(_ image: UIImage, overlapFraction: CGFloat = 0.16) -> [UIImage]? {
        let normalized = orientationNormalized(image)
        guard let cg = normalized.cgImage else { return nil }
        let pxW = CGFloat(cg.width)
        let pxH = CGFloat(cg.height)
        guard pxW > 0, pxH / pxW > tallReceiptAspectThreshold else { return nil }

        // Aim for ~1.6:1 bands — comfortably inside what every vision
        // model handles without internal compression.
        let targetBandAspect: CGFloat = 1.6
        let bandCount = max(2, Int((pxH / pxW / targetBandAspect).rounded(.up)))
        let baseBandPxH = pxH / CGFloat(bandCount)
        let overlapPx = baseBandPxH * overlapFraction

        var bands: [UIImage] = []
        for i in 0..<bandCount {
            let top = max(0, CGFloat(i) * baseBandPxH - overlapPx)
            let bottom = min(pxH, CGFloat(i + 1) * baseBandPxH + overlapPx)
            let rect = CGRect(x: 0, y: top, width: pxW, height: bottom - top)
            guard let cropped = cg.cropping(to: rect) else { continue }
            let band = downscaled(UIImage(cgImage: cropped), maxDimension: bandMaxDimension)
            bands.append(sharpenedForOCR(band))
        }
        return bands.count > 1 ? bands : nil
    }

    /// Re-render the image upright so `cgImage` pixel cropping aligns
    /// with the visual top-to-bottom layout (the camera hands back
    /// images with an EXIF orientation flag rather than rotated pixels).
    /// Idempotent for already-upright images.
    static func orientationNormalized(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    // MARK: - OCR sharpening

    /// Reused across calls — `CIContext` allocation is expensive and the
    /// filter chain is stateless.
    private static let ciContext = CIContext(options: nil)

    /// Mild contrast + unsharp-mask pass that makes thin digit strokes
    /// survive a vision model's internal downsampling of small receipt
    /// text. The bar that separates `8` from `0` (or `6` from `0`, `5`
    /// from `6`) is exactly the thin feature that dissolves first when a
    /// 1179-px-wide screenshot of a long receipt is tiled and re-sampled
    /// by the model — boosting local edge contrast keeps those strokes
    /// legible. Settings are deliberately gentle: just enough emphasis to
    /// preserve strokes, not so much that ringing invents phantom ones.
    /// Returns the input unchanged if Core Image can't process it.
    static func sharpenedForOCR(_ image: UIImage) -> UIImage {
        guard let cg = image.cgImage else { return image }
        let input = CIImage(cgImage: cg)
        guard
            let contrasted = CIFilter(name: "CIColorControls", parameters: [
                kCIInputImageKey: input,
                kCIInputContrastKey: 1.08,
                kCIInputSaturationKey: 1.0,
                kCIInputBrightnessKey: 0.0,
            ])?.outputImage,
            let sharpened = CIFilter(name: "CIUnsharpMask", parameters: [
                kCIInputImageKey: contrasted,
                kCIInputRadiusKey: 1.8,
                kCIInputIntensityKey: 0.7,
            ])?.outputImage,
            let out = ciContext.createCGImage(sharpened, from: input.extent)
        else { return image }
        return UIImage(cgImage: out)
    }
}

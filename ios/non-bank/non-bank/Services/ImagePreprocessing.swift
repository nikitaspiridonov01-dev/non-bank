import UIKit

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
}

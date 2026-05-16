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
    /// 2048 keeps text crisp on every receipt seen so far (typical
    /// font size at 2048 px lands at 30–40 px tall, well above
    /// Vision's recognition floor) while cutting raw memory ~10×
    /// versus a stock 12 MP shot.
    ///
    /// Tunable: bump to 2560 / 3072 if Vision starts missing text
    /// on dense receipts; drop to 1536 only if memory crashes
    /// reappear on low-end devices.
    static let receiptMaxDimension: CGFloat = 2048

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

import UIKit
import Vision

/// Turns a receipt photo so its text reads upright.
///
/// The camera's orientation flag follows how the phone was held, not the
/// paper: shot with the phone flat over a table, or of a receipt lying
/// across the frame, the lines come out sideways or upside down. Every
/// later step reads upright lines — the long-receipt check and its bands,
/// the receipt framing, the vision models — so a turned photo was read
/// badly or not at all.
///
/// On-device check: Vision's fast text recognizer reads a small copy of
/// the photo as it stands and turned upside down; when neither reads as
/// text (lines running vertically), also turned a quarter each way. The
/// way that reads the most text wins — and only when it wins clearly, so
/// a photo with little readable text is never turned on noise.
nonisolated enum ReceiptOrientation {

    /// Long edge of the copy the recognizer reads. Large enough for the
    /// print of a receipt filling the frame; the full photo stays as is.
    static let probeMaxDimension: CGFloat = 1600
    /// A reading this good, and clearly ahead of the opposite way, settles
    /// it without trying the quarter turns.
    static let settledScore: Double = 120
    /// The least reading that can turn a photo at all.
    static let minimumScore: Double = 30
    /// How far a turned reading has to beat the photo as it stands.
    static let winningRatio: Double = 1.5

    /// The photo with its text upright: re-rendered when a turn is needed,
    /// the same image otherwise. Applies the camera's orientation flag
    /// first, like the rest of the pipeline.
    static func uprighted(_ image: UIImage) -> UIImage {
        let normalized = flagApplied(image)
        guard let cg = normalized.cgImage else { return normalized }
        let orientation = textOrientation(of: cg)
        guard orientation != .up else { return normalized }
        return render(cg, orientation: orientation)
    }

    /// How Vision has to treat `image` to read its text upright — `.up`
    /// when it already reads upright, or when no way reads clearly better.
    static func textOrientation(of image: CGImage) -> CGImagePropertyOrientation {
        let probe = downscaled(image, maxDimension: probeMaxDimension)
        let up = readability(of: probe, orientation: .up)
        let down = readability(of: probe, orientation: .down)
        if max(up, down) >= settledScore {
            if up >= down * winningRatio { return .up }
            if down >= up * winningRatio { return .down }
        }
        var best: (orientation: CGImagePropertyOrientation, score: Double) = up >= down ? (.up, up) : (.down, down)
        for orientation in [CGImagePropertyOrientation.right, .left] {
            let score = readability(of: probe, orientation: orientation)
            if score > best.score { best = (orientation, score) }
        }
        guard best.orientation != .up,
              best.score >= minimumScore,
              best.score >= up * winningRatio
        else { return .up }
        return best.orientation
    }

    /// How much readable text the recognizer finds: each line's letters
    /// (digits at half weight — 0, 1 and 8 read the same upside down)
    /// times its confidence.
    static func readability(of image: CGImage, orientation: CGImagePropertyOrientation) -> Double {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return 0
        }
        var score = 0.0
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            var weight = 0.0
            for scalar in candidate.string.unicodeScalars {
                if CharacterSet.letters.contains(scalar) {
                    weight += 1
                } else if CharacterSet.decimalDigits.contains(scalar) {
                    weight += 0.5
                }
            }
            score += Double(candidate.confidence) * weight
        }
        return score
    }

    /// `image` turned the way `orientation` says — the pixels Vision reads
    /// when handed `image` with that orientation.
    static func render(_ image: CGImage, orientation: CGImagePropertyOrientation) -> UIImage {
        flagApplied(UIImage(cgImage: image, scale: 1, orientation: uiOrientation(orientation)))
    }

    /// The image re-rendered with its orientation flag applied to the
    /// pixels (what `ImagePreprocessing.orientationNormalized` does, kept
    /// here so this runs off the main actor).
    private static func flagApplied(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: image.size)) }
    }

    private static func uiOrientation(_ orientation: CGImagePropertyOrientation) -> UIImage.Orientation {
        switch orientation {
        case .up: return .up
        case .upMirrored: return .upMirrored
        case .down: return .down
        case .downMirrored: return .downMirrored
        case .left: return .left
        case .leftMirrored: return .leftMirrored
        case .right: return .right
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }

    private static func downscaled(_ image: CGImage, maxDimension: CGFloat) -> CGImage {
        let longest = CGFloat(max(image.width, image.height))
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let size = CGSize(width: (CGFloat(image.width) * scale).rounded(), height: (CGFloat(image.height) * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let small = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            UIImage(cgImage: image).draw(in: CGRect(origin: .zero, size: size))
        }
        return small.cgImage ?? image
    }
}

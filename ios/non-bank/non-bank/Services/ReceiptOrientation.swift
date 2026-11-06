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
/// text (lines running vertically), also turned a quarter each way. That
/// finds the axis the lines run along. Which end is up comes from the
/// receipt's layout: amounts close each line, right-aligned, so in the
/// right reading they sit on the right. (How much text reads can't tell:
/// receipts are printed in capitals and digits, many of which — H, I, N,
/// O, S, X, Z, 0, 1, 8 — read the same upside down.) Without amounts to
/// go by, the clearly more readable way wins; when nothing is clear, the
/// photo is left as it is.
nonisolated enum ReceiptOrientation {

    /// Long edge of the copy the recognizer reads. Large enough for the
    /// print of a receipt filling the frame; the full photo stays as is.
    static let probeMaxDimension: CGFloat = 1600
    /// Reading this much as it stands or upside down, the lines run across
    /// the photo: the quarter turns aren't tried.
    static let settledScore: Double = 120
    /// The least reading that can turn a photo at all.
    static let minimumScore: Double = 30
    /// How far one way has to out-read the other to win on readability.
    static let winningRatio: Double = 1.5
    /// Amounts it takes to tell which end is up, and the lead they need.
    static let minimumAmounts = 3
    static let amountsRatio = 2

    /// What the recognizer makes of the photo read one way.
    struct Reading: Equatable {
        /// Each line's letters (digits at half weight) times its confidence.
        var readability: Double = 0
        /// Lines ending in an amount ("149.99", "1.234,50 A"), by which half
        /// of the photo, read this way, the amount sits in.
        var amountsRight = 0
        var amountsLeft = 0
    }

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
    /// when it already reads upright, or when nothing tells clearly.
    static func textOrientation(of image: CGImage) -> CGImagePropertyOrientation {
        let probe = downscaled(image, maxDimension: probeMaxDimension)
        let up = reading(of: probe, orientation: .up)
        let down = reading(of: probe, orientation: .down)
        let across = max(up.readability, down.readability)
        if across >= settledScore {
            return pick(.up, up, or: .down, down) ?? .up
        }
        let right = reading(of: probe, orientation: .right)
        let left = reading(of: probe, orientation: .left)
        let along = max(right.readability, left.readability)
        if along >= minimumScore && along >= across * winningRatio {
            return pick(.right, right, or: .left, left) ?? .up
        }
        if across >= minimumScore {
            return pick(.up, up, or: .down, down) ?? .up
        }
        return .up
    }

    /// Of two opposite ways, the one the receipt reads in. The two
    /// readings mirror each other: an amount on the right read one way is
    /// on the left read the other, so both count. Failing a clear count,
    /// the clearly more readable way; nil when neither is clear.
    static func pick(
        _ a: CGImagePropertyOrientation, _ readingA: Reading,
        or b: CGImagePropertyOrientation, _ readingB: Reading
    ) -> CGImagePropertyOrientation? {
        let forA = readingA.amountsRight + readingB.amountsLeft
        let forB = readingB.amountsRight + readingA.amountsLeft
        if max(forA, forB) >= minimumAmounts {
            if forA >= forB * amountsRatio && forA > forB { return a }
            if forB >= forA * amountsRatio && forB > forA { return b }
        }
        if readingA.readability >= max(readingB.readability * winningRatio, minimumScore) { return a }
        if readingB.readability >= max(readingA.readability * winningRatio, minimumScore) { return b }
        return nil
    }

    /// Reads `image` the way `orientation` says (Vision's coordinates are
    /// those of the image turned that way).
    static func reading(of image: CGImage, orientation: CGImagePropertyOrientation) -> Reading {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, orientation: orientation, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return Reading()
        }
        var result = Reading()
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
            result.readability += Double(candidate.confidence) * weight
            if let amount = trailingAmount(in: candidate.string),
               let box = (try? candidate.boundingBox(for: amount))?.boundingBox {
                if box.midX >= 0.55 {
                    result.amountsRight += 1
                } else if box.midX <= 0.45 {
                    result.amountsLeft += 1
                }
            }
        }
        return result
    }

    /// An amount closing `line` — digits, a decimal point or comma, two
    /// decimals, maybe a tax letter or a currency code after it ("149.99",
    /// "1.234,50 A", "12.50 EUR").
    static func trailingAmount(in line: String) -> Range<String.Index>? {
        let range = NSRange(line.startIndex..., in: line)
        guard let match = amountPattern.firstMatch(in: line, range: range),
              let amount = Range(match.range(at: 1), in: line)
        else { return nil }
        return amount
    }

    private static let amountPattern = try! NSRegularExpression(
        pattern: #"(\d+(?:[.,]\d{3})*[.,]\d{2})\s*\p{L}{0,3}\s*$"#
    )

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

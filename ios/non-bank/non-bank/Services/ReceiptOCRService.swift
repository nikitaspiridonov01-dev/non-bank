import Vision
import UIKit
import ImageIO

// MARK: - Receipt OCR Service

actor ReceiptOCRService {

    struct RecognizedLine: Sendable {
        let text: String
        let boundingBox: CGRect  // Vision normalized coords: origin bottom-left, Y up
        let confidence: Float
    }

    struct OCRRow: Sendable, Identifiable {
        let id: UUID
        let lines: [RecognizedLine]
        let boundingBox: CGRect  // Union of all lines' bounding boxes (Vision coords)
        let text: String         // Combined text, left to right
    }

    // MARK: - Public API

    func recognizeText(
        from image: UIImage,
        minimumConfidence: Float = 0
    ) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else {
            throw ReceiptOCRError.invalidImage
        }

        let orientation = Self.cgOrientation(from: image.imageOrientation)

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: [])
                    return
                }

                let lines: [RecognizedLine] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    // Drop lines Vision is unsure about. Defaults to `0`
                    // (back-compat) so existing callers behave as before.
                    if candidate.confidence < minimumConfidence { return nil }
                    return RecognizedLine(
                        text: candidate.string,
                        boundingBox: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }

                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            // Order matters — Vision uses the list as priority hints. We
            // front-load the most common Latin scripts seen on receipts,
            // keeping Cyrillic at the end so it doesn't bias mixed-script
            // documents. Polish was added for Phase 3.5 alongside the
            // multi-language receipt filter.
            request.recognitionLanguages = ["en", "sr-Latn", "de", "fr", "es", "it", "pt", "pl", "ru"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(
                cgImage: cgImage,
                orientation: orientation,
                options: [:]
            )
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Group recognized lines into visual rows based on Y-coordinate proximity.
    /// Compares each line against the group's average midY for better skew tolerance.
    func groupIntoRows(from lines: [RecognizedLine]) -> [OCRRow] {
        // Sort top-first (descending Y), then left-to-right
        let sorted = lines.sorted { a, b in
            let ay = a.boundingBox.midY
            let by = b.boundingBox.midY
            if abs(ay - by) < 0.02 {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return ay > by
        }

        var rows: [OCRRow] = []
        var currentGroup: [RecognizedLine] = []
        var groupMidYSum: CGFloat = 0

        for line in sorted {
            if currentGroup.isEmpty {
                currentGroup = [line]
                groupMidYSum = line.boundingBox.midY
            } else {
                // Compare against group average midY, not just last element
                let groupAvgY = groupMidYSum / CGFloat(currentGroup.count)
                let tolerance: CGFloat = 0.02
                if abs(line.boundingBox.midY - groupAvgY) < tolerance {
                    currentGroup.append(line)
                    groupMidYSum += line.boundingBox.midY
                } else {
                    rows.append(Self.makeRow(from: currentGroup))
                    currentGroup = [line]
                    groupMidYSum = line.boundingBox.midY
                }
            }
        }
        if !currentGroup.isEmpty {
            rows.append(Self.makeRow(from: currentGroup))
        }

        return rows
    }

    /// Build a clean text representation from OCR lines, sorted top-to-bottom.
    func buildReceiptText(from lines: [RecognizedLine]) -> String {
        let sorted = lines.sorted { a, b in
            let ay = a.boundingBox.midY
            let by = b.boundingBox.midY
            if abs(ay - by) < 0.02 {
                return a.boundingBox.minX < b.boundingBox.minX
            }
            return ay > by
        }

        var result = ""
        var lastY: CGFloat = -1

        for line in sorted {
            let currentY = line.boundingBox.midY
            if lastY >= 0 && abs(currentY - lastY) < 0.02 {
                result += "\t" + line.text
            } else {
                if !result.isEmpty { result += "\n" }
                result += line.text
            }
            lastY = currentY
        }

        return result
    }

    // MARK: - Private

    private static func makeRow(from lines: [RecognizedLine]) -> OCRRow {
        let sorted = lines.sorted { $0.boundingBox.minX < $1.boundingBox.minX }
        let text = sorted.map(\.text).joined(separator: " ")

        var union = sorted[0].boundingBox
        for line in sorted.dropFirst() {
            union = union.union(line.boundingBox)
        }

        return OCRRow(id: UUID(), lines: sorted, boundingBox: union, text: text)
    }

    /// Map UIImage.Orientation → CGImagePropertyOrientation for VNImageRequestHandler.
    private static func cgOrientation(from uiOrientation: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch uiOrientation {
        case .up:            return .up
        case .down:          return .down
        case .left:          return .left
        case .right:         return .right
        case .upMirrored:    return .upMirrored
        case .downMirrored:  return .downMirrored
        case .leftMirrored:  return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default:    return .up
        }
    }
}

// MARK: - Errors

enum ReceiptOCRError: LocalizedError {
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .invalidImage: return "Could not get CGImage from the provided UIImage."
        }
    }
}

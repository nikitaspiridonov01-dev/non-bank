import CoreGraphics

/// Finds the receipt in a photo from where Vision sees text, so the
/// tall-receipt path can crop away the table on both sides of it.
///
/// A long receipt shot on the camera's 3:4 frame fills the height but only
/// a narrow strip of the width. As a whole picture (H/W ≈ 1.33) it never
/// reached `ImagePreprocessing.tallReceiptAspectThreshold`, so it went to
/// the AI model in one piece — and every vision model shrinks its input to
/// a fixed pixel budget, which leaves the print of a long receipt a few
/// pixels tall. Cropped to the receipt, the same photo is a tall strip that
/// tiles into bands, and each band reaches the model at full resolution.
///
/// Only the width is cropped. The full height is kept, so a line Vision
/// missed at the top or the bottom can't be cut off. Every rule errs toward
/// a wider crop, or none at all: too wide only costs resolution, too narrow
/// could cut off the prices.
enum ReceiptFraming {

    /// Fewer text boxes than this is not a long receipt.
    static let minimumBoxes = 8
    /// Boxes closer than this, as a share of the image width, are one column.
    static let columnGap: CGFloat = 0.015
    /// A column this close to the receipt's core joins it outright: within
    /// this share of the image width, or of the core's own width.
    static let nearGapOfImage: CGFloat = 0.03
    static let nearGapOfCore: CGFloat = 0.25
    /// A column farther out joins only if it looks like another column of
    /// the same receipt (prices printed far from their names, with no line
    /// spanning the gap): it runs along a good part of the core's height,
    /// has a box on many of its lines, and is no farther than a receipt is
    /// wide — twice the span so far, or 40 lines of text tall.
    static let columnExtentShare: CGFloat = 0.3
    static let columnBoxShare: CGFloat = 0.2
    static let reachOfSpan: CGFloat = 2.0
    static let reachInTextHeights: CGFloat = 40
    /// The crop must hold this share of all the text boxes in the frame…
    static let minimumBoxShare: CGFloat = 0.6
    /// …and Vision must have seen text along this share of its height.
    static let minimumHeightCoverage: CGFloat = 0.6
    /// Side margin: at least this share of the image width, this share of
    /// the receipt's width (print running past its boxes), and room for a
    /// receipt tilted by up to ~5° to drift sideways along the stretch of
    /// the frame where Vision found no text.
    static let minimumMargin: CGFloat = 0.03
    static let widthMargin: CGFloat = 0.08
    static let tiltSlope: CGFloat = 0.09
    /// A crop that keeps this share of the width or more isn't worth it.
    static let maximumCropShare: CGFloat = 0.85

    /// The horizontal pixel range holding the receipt, or nil when the
    /// photo should be used as it is.
    /// - Parameters:
    ///   - textBoxes: text boxes normalised to 0…1, with a TOP-LEFT origin.
    ///   - imageSize: the image's size in pixels.
    static func receiptColumn(textBoxes: [CGRect], imageSize: CGSize) -> ClosedRange<CGFloat>? {
        let width = imageSize.width, height = imageSize.height
        guard width > 0, height > 0 else { return nil }
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let boxes: [CGRect] = textBoxes.compactMap { box in
            let clipped = box.standardized.intersection(unit)
            guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { return nil }
            return CGRect(x: clipped.minX * width, y: clipped.minY * height,
                          width: clipped.width * width, height: clipped.height * height)
        }
        guard boxes.count >= minimumBoxes else { return nil }

        // 1. Columns of text: boxes whose x-ranges overlap or nearly touch.
        var columns: [Column] = []
        for box in boxes.sorted(by: { $0.minX < $1.minX }) {
            if let last = columns.indices.last, box.minX <= columns[last].maxX + columnGap * width {
                columns[last].add(box)
            } else {
                columns.append(Column(box))
            }
        }

        // 2. The receipt's core is the column with the most boxes: a receipt
        //    is dozens of short lines, background text (packaging, a sign)
        //    a few big words. Then widen it by the columns that belong to it.
        guard let coreIndex = columns.indices.max(by: {
            (columns[$0].boxes.count, columns[$0].area) < (columns[$1].boxes.count, columns[$1].area)
        }) else { return nil }
        let core = columns[coreIndex]
        let textHeight = core.medianBoxHeight
        var left = core.minX, right = core.maxX
        var taken: Set<Int> = [coreIndex]
        var grew = true
        while grew {
            grew = false
            for (index, column) in columns.enumerated() where !taken.contains(index) {
                if column.minX >= left, column.maxX <= right {
                    taken.insert(index)   // lies between columns already taken
                    continue
                }
                let gap = column.minX > right ? column.minX - right : left - column.maxX
                let sharedHeight = min(column.maxY, core.maxY) - max(column.minY, core.minY)
                guard sharedHeight >= 0.5 * max(column.extent, 1) else { continue }
                let near = gap <= max(nearGapOfImage * width, nearGapOfCore * core.width)
                let looksLikeColumn = column.extent >= columnExtentShare * core.extent
                    && CGFloat(column.boxes.count) >= columnBoxShare * CGFloat(core.boxes.count)
                let reachable = gap <= max(reachOfSpan * (right - left), reachInTextHeights * textHeight)
                guard near || (looksLikeColumn && reachable) else { continue }
                taken.insert(index)
                left = min(left, column.minX)
                right = max(right, column.maxX)
                grew = true
            }
        }

        // 3. The receipt must be most of the text in the frame, seen along
        //    most of its height; otherwise something else dominates the
        //    photo, or Vision saw only part of the receipt.
        let allBoxes = columns.reduce(0) { $0 + $1.boxes.count }
        let takenBoxes = taken.reduce(0) { $0 + columns[$1].boxes.count }
        guard CGFloat(takenBoxes) >= minimumBoxShare * CGFloat(allBoxes) else { return nil }
        let top = taken.map { columns[$0].minY }.min() ?? 0
        let bottom = taken.map { columns[$0].maxY }.max() ?? 0
        guard bottom - top >= minimumHeightCoverage * height else { return nil }

        // 4. Margins, then only crop if it removes a real share of the width.
        let unseen = max(top, height - bottom)
        let margin = max(minimumMargin * width, widthMargin * (right - left), tiltSlope * unseen)
        let cropLeft = max(0, left - margin)
        let cropRight = min(width, right + margin)
        guard cropRight - cropLeft < maximumCropShare * width else { return nil }
        return cropLeft...cropRight
    }

    private struct Column {
        var minX: CGFloat
        var maxX: CGFloat
        var minY: CGFloat
        var maxY: CGFloat
        var boxes: [CGRect]
        var area: CGFloat

        init(_ box: CGRect) {
            minX = box.minX; maxX = box.maxX
            minY = box.minY; maxY = box.maxY
            boxes = [box]
            area = box.width * box.height
        }

        mutating func add(_ box: CGRect) {
            minX = min(minX, box.minX)
            maxX = max(maxX, box.maxX)
            minY = min(minY, box.minY)
            maxY = max(maxY, box.maxY)
            boxes.append(box)
            area += box.width * box.height
        }

        var width: CGFloat { maxX - minX }
        var extent: CGFloat { maxY - minY }
        var medianBoxHeight: CGFloat {
            let heights = boxes.map(\.height).sorted()
            return heights[heights.count / 2]
        }
    }
}

import SwiftUI
import UIKit

// MARK: - Receipt Highlighter View

struct ReceiptHighlighterView: View {
    let image: UIImage
    let ocrRows: [ReceiptOCRService.OCRRow]

    @State private var selectedRowIDs: Set<UUID> = []
    @State private var showPreview = false
    @Environment(\.dismiss) private var dismiss

    private var itemGroups: [ParsedItemGroup] {
        let rows = ocrRows.filter { selectedRowIDs.contains($0.id) }
        return ReceiptLineParser.extractItemGroups(from: rows)
    }

    private var parsedRowIDs: Set<UUID> {
        var s = Set<UUID>()
        for g in itemGroups { s.formUnion(g.rowIDs) }
        return s
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ReceiptCanvasView(
                    image: image,
                    ocrRows: ocrRows,
                    selectedRowIDs: $selectedRowIDs,
                    parsedRowIDs: parsedRowIDs,
                    itemGroups: itemGroups
                )

                bottomBar
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .fontWeight(.semibold)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("Highlight Items")
                        .font(.headline)
                }
            }
            .sheet(isPresented: $showPreview) {
                ItemPreviewSheet(
                    items: itemGroups.map(\.item),
                    onSave: {
                        showPreview = false
                        dismiss()
                    }
                )
            }
        }
    }

    // MARK: - Bottom Bar

    @ViewBuilder
    private var bottomBar: some View {
        let groups = itemGroups
        let total = groups.reduce(0.0) { $0 + $1.item.lineTotal }

        VStack(spacing: 0) {
            Divider()
            HStack {
                if !selectedRowIDs.isEmpty {
                    if groups.isEmpty {
                        Text("No items detected so far")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button {} label: {
                            Label("Confirm", systemImage: "checkmark")
                                .font(.headline)
                                .padding(.horizontal, AppSpacing.xl)
                                .padding(.vertical, 10)
                                .background(Color.accentColor.opacity(0.4))
                                .foregroundColor(.white.opacity(0.5))
                                .clipShape(Capsule())
                        }
                        .disabled(true)
                    } else {
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text("\(groups.count) item\(groups.count == 1 ? "" : "s")")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Text(String(format: "%.2f", total))
                                .font(.title2.bold())
                        }
                        Spacer()
                        Button {
                            showPreview = true
                        } label: {
                            Label("Confirm", systemImage: "checkmark")
                                .font(.headline)
                                .padding(.horizontal, AppSpacing.xl)
                                .padding(.vertical, 10)
                                .background(Color.accentColor)
                                .foregroundColor(.white)
                                .clipShape(Capsule())
                        }
                    }
                } else {
                    Spacer()
                    VStack(spacing: AppSpacing.xs) {
                        Text("☝️ Swipe across items to select")
                            .font(.subheadline)
                        Text("✌️ Two fingers to scroll")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.vertical, AppSpacing.rowVertical)
            .padding(.bottom, AppSpacing.lg)
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Receipt Canvas (UIViewRepresentable)

struct ReceiptCanvasView: UIViewRepresentable {
    let image: UIImage
    let ocrRows: [ReceiptOCRService.OCRRow]
    @Binding var selectedRowIDs: Set<UUID>
    var parsedRowIDs: Set<UUID>
    var itemGroups: [ParsedItemGroup]

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> ReceiptCanvasUIView {
        let view = ReceiptCanvasUIView()
        view.coordinator = context.coordinator
        view.configure(image: image, ocrRows: ocrRows)
        return view
    }

    func updateUIView(_ uiView: ReceiptCanvasUIView, context: Context) {
        context.coordinator.parent = self
        uiView.updateOverlay(
            selectedRowIDs: selectedRowIDs,
            parsedRowIDs: parsedRowIDs,
            itemGroups: itemGroups
        )
    }

    class Coordinator {
        var parent: ReceiptCanvasView
        init(_ parent: ReceiptCanvasView) { self.parent = parent }

        func select(rowID: UUID) { parent.selectedRowIDs.insert(rowID) }
        func deselect(rowID: UUID) { parent.selectedRowIDs.remove(rowID) }
        func deselectGroup(rowIDs: [UUID]) {
            for id in rowIDs { parent.selectedRowIDs.remove(id) }
        }
    }
}

// MARK: - Canvas UIKit View

class ReceiptCanvasUIView: UIView, UIScrollViewDelegate {
    private let scrollView = UIScrollView()
    private let contentView = UIView()
    private let imageView = UIImageView()
    let overlayView = ReceiptOverlayDrawView()
    private let checkmarkContainer = UIView()

    private var image: UIImage?
    private var ocrRows: [ReceiptOCRService.OCRRow] = []
    private var selectedRowIDs: Set<UUID> = []
    private var tentativeRowIDs: Set<UUID> = []
    private let feedback = UIImpactFeedbackGenerator(style: .light)

    var coordinator: ReceiptCanvasView.Coordinator?
    private var lastPanPoint: CGPoint?
    private var contentSizeApplied: CGSize = .zero
    private var hasAutoZoomed = false

    private enum GestureMode { case select, deselect }
    private var gestureMode: GestureMode = .select

    /// Track which group IDs already have a visible checkmark (for animation)
    private var visibleCheckmarkGroupIDs: Set<String> = []

    func configure(image: UIImage, ocrRows: [ReceiptOCRService.OCRRow]) {
        self.image = image
        self.ocrRows = ocrRows
        backgroundColor = .black

        scrollView.delegate = self
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 3.0
        scrollView.showsVerticalScrollIndicator = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.panGestureRecognizer.minimumNumberOfTouches = 2
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        scrollView.addSubview(contentView)
        imageView.image = image
        imageView.contentMode = .scaleToFill
        contentView.addSubview(imageView)

        overlayView.backgroundColor = .clear
        overlayView.isOpaque = false
        overlayView.ocrRows = ocrRows
        contentView.addSubview(overlayView)

        // Checkmark container sits ON TOP of scrollView (viewport-relative)
        checkmarkContainer.backgroundColor = .clear
        checkmarkContainer.isUserInteractionEnabled = false
        addSubview(checkmarkContainer)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        scrollView.addGestureRecognizer(pan)

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        scrollView.addGestureRecognizer(tap)

        feedback.prepare()
    }

    func updateOverlay(selectedRowIDs: Set<UUID>, parsedRowIDs: Set<UUID>, itemGroups: [ParsedItemGroup]) {
        overlayView.selectedRowIDs = selectedRowIDs
        overlayView.parsedRowIDs = parsedRowIDs
        overlayView.itemGroups = itemGroups
        overlayView.setNeedsDisplay()
        updateCheckmarks(itemGroups: itemGroups)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let image, bounds.width > 0 else { return }

        let w = bounds.width
        let h = w * (image.size.height / image.size.width)
        let newSize = CGSize(width: w, height: h)
        guard newSize != contentSizeApplied else { return }
        contentSizeApplied = newSize

        contentView.frame = CGRect(origin: .zero, size: newSize)
        imageView.frame = contentView.bounds
        overlayView.frame = contentView.bounds
        checkmarkContainer.frame = bounds
        overlayView.imageDisplaySize = newSize
        scrollView.contentSize = newSize
        overlayView.setNeedsDisplay()

        if !hasAutoZoomed && !ocrRows.isEmpty {
            hasAutoZoomed = true
            DispatchQueue.main.async { self.zoomToTextArea() }
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let bs = scrollView.bounds.size
        var f = contentView.frame
        f.origin.x = max(0, (bs.width - f.width) / 2)
        f.origin.y = max(0, (bs.height - f.height) / 2)
        contentView.frame = f
        repositionCheckmarks()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        repositionCheckmarks()
    }

    // MARK: - Auto Zoom

    private func zoomToTextArea() {
        let ds = overlayView.imageDisplaySize
        guard ds.width > 0, !ocrRows.isEmpty else { return }

        var union = visionToView(ocrRows[0].boundingBox, ds: ds)
        for row in ocrRows.dropFirst() {
            union = union.union(visionToView(row.boundingBox, ds: ds))
        }

        // Check if text already fills viewport well (>70% of visible area)
        let viewportArea = bounds.width * bounds.height
        let textArea = union.width * union.height
        guard viewportArea > 0, textArea / viewportArea < 0.70 else { return }

        // Tighter padding: 8% on each side
        let padX = union.width * 0.08
        let padY = union.height * 0.08
        let target = union.insetBy(dx: -padX, dy: -padY)

        scrollView.zoom(to: target, animated: false)
    }

    // MARK: - Checkmark Management

    /// Maps group ID → content-space Y center (for viewport repositioning)
    private var checkmarkContentY: [String: CGFloat] = [:]
    private let indicatorSize: CGFloat = 6.0
    private let indicatorX: CGFloat = 14.0  // fixed X from left edge of viewport

    private func updateCheckmarks(itemGroups: [ParsedItemGroup]) {
        let ds = overlayView.imageDisplaySize
        guard ds.width > 0 else { return }

        // Build a set of current group identifiers
        var currentGroupIDs = Set<String>()
        for group in itemGroups {
            currentGroupIDs.insert(groupKey(group))
        }

        // Remove checkmarks for groups that no longer exist
        for sub in checkmarkContainer.subviews where sub is CheckmarkView {
            guard let tag = sub.accessibilityIdentifier else {
                sub.removeFromSuperview()
                continue
            }
            if !currentGroupIDs.contains(tag) {
                visibleCheckmarkGroupIDs.remove(tag)
                checkmarkContentY.removeValue(forKey: tag)
                UIView.animate(withDuration: 0.2, animations: {
                    sub.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
                    sub.alpha = 0
                }) { _ in sub.removeFromSuperview() }
            }
        }

        // Add checkmarks for new groups
        for group in itemGroups {
            let gid = groupKey(group)
            guard !visibleCheckmarkGroupIDs.contains(gid) else { continue }
            visibleCheckmarkGroupIDs.insert(gid)

            // Compute Y center in content-space from row bounding boxes
            let rects = group.rowIDs.compactMap { id -> CGRect? in
                guard let row = ocrRows.first(where: { $0.id == id }) else { return nil }
                return visionToView(row.boundingBox, ds: ds)
            }
            guard !rects.isEmpty else { continue }
            var union = rects[0]
            for r in rects.dropFirst() { union = union.union(r) }

            let contentCenterY = union.midY
            checkmarkContentY[gid] = contentCenterY

            // Convert to viewport position
            let viewportY = contentToViewportY(contentCenterY)

            let check = CheckmarkView(frame: CGRect(
                x: indicatorX - indicatorSize / 2,
                y: viewportY - indicatorSize / 2,
                width: indicatorSize,
                height: indicatorSize
            ))
            check.accessibilityIdentifier = gid
            check.transform = CGAffineTransform(scaleX: 0.01, y: 0.01)
            checkmarkContainer.addSubview(check)

            // Bounce animation
            UIView.animate(
                withDuration: 0.45,
                delay: 0,
                usingSpringWithDamping: 0.5,
                initialSpringVelocity: 0.8,
                options: [.curveEaseOut]
            ) {
                check.transform = .identity
            }

            // Shimmer wave across parsed block (in content space)
            let shimmerRect = contentView.convert(union.insetBy(dx: -6, dy: -4), to: self)
            addShimmer(to: shimmerRect)
        }
    }

    /// Reposition all checkmark dots based on current scroll offset and zoom
    private func repositionCheckmarks() {
        for sub in checkmarkContainer.subviews where sub is CheckmarkView {
            guard let gid = sub.accessibilityIdentifier,
                  let contentY = checkmarkContentY[gid] else { continue }
            let viewportY = contentToViewportY(contentY)
            sub.center = CGPoint(x: indicatorX, y: viewportY)
        }
    }

    /// Convert content-space Y to viewport Y
    private func contentToViewportY(_ contentY: CGFloat) -> CGFloat {
        let zoom = scrollView.zoomScale
        let offset = scrollView.contentOffset
        let contentOriginY = contentView.frame.origin.y
        return (contentY * zoom) - offset.y + contentOriginY
    }

    private func groupKey(_ group: ParsedItemGroup) -> String {
        group.rowIDs.map(\.uuidString).sorted().joined(separator: "-")
    }

    private func addShimmer(to rect: CGRect) {
        let shimmer = UIView(frame: rect)
        shimmer.backgroundColor = .clear
        shimmer.clipsToBounds = true
        shimmer.layer.cornerRadius = 5
        shimmer.isUserInteractionEnabled = false
        // Add shimmer to self (viewport space) since rect is already in viewport coords
        addSubview(shimmer)

        let bandWidth = rect.width * 0.35
        let band = CAGradientLayer()
        band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: rect.height)
        band.colors = [
            UIColor.white.withAlphaComponent(0.0).cgColor,
            UIColor.white.withAlphaComponent(0.15).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        shimmer.layer.addSublayer(band)

        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -bandWidth / 2
        anim.toValue = rect.width + bandWidth / 2
        anim.duration = 0.6
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        anim.isRemovedOnCompletion = false
        anim.fillMode = .forwards

        CATransaction.begin()
        CATransaction.setCompletionBlock { shimmer.removeFromSuperview() }
        band.add(anim, forKey: "shimmer")
        CATransaction.commit()
    }

    // MARK: - Pan Gesture

    @objc private func handlePan(_ g: UIPanGestureRecognizer) {
        let pt = g.location(in: contentView)

        switch g.state {
        case .began:
            lastPanPoint = pt
            gestureMode = .select
            if let row = hitRow(at: pt), selectedRowIDs.contains(row.id) {
                gestureMode = .deselect
            }
            processHit(at: pt)

        case .changed:
            if let last = lastPanPoint { interpolateHits(from: last, to: pt) }
            lastPanPoint = pt
            overlayView.setNeedsDisplay()

        case .ended, .cancelled:
            if gestureMode == .select { finalizeTentative() }
            lastPanPoint = nil
            overlayView.setNeedsDisplay()

        default: break
        }
    }

    private func interpolateHits(from a: CGPoint, to b: CGPoint) {
        let dist = hypot(b.x - a.x, b.y - a.y)
        let steps = max(1, Int(dist / 4))
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            processHit(at: CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
        }
    }

    private func processHit(at pt: CGPoint) {
        switch gestureMode {
        case .select: checkHitForSelect(at: pt)
        case .deselect: checkHitForDeselect(at: pt)
        }
    }

    private func checkHitForSelect(at pt: CGPoint) {
        let ds = overlayView.imageDisplaySize
        guard ds.width > 0 else { return }
        for row in ocrRows {
            guard !selectedRowIDs.contains(row.id),
                  !tentativeRowIDs.contains(row.id) else { continue }
            let r = visionToView(row.boundingBox, ds: ds)
            let tol = max(r.height * 0.5, 8)
            if pt.y >= r.minY - tol && pt.y <= r.maxY + tol {
                tentativeRowIDs.insert(row.id)
                overlayView.tentativeRowIDs = tentativeRowIDs
                feedback.impactOccurred(intensity: 0.4)
            }
        }
    }

    private func checkHitForDeselect(at pt: CGPoint) {
        let ds = overlayView.imageDisplaySize
        guard ds.width > 0 else { return }
        for row in ocrRows where selectedRowIDs.contains(row.id) {
            let r = visionToView(row.boundingBox, ds: ds)
            let tol = max(r.height * 0.5, 8)
            if pt.y >= r.minY - tol && pt.y <= r.maxY + tol {
                if let group = overlayView.itemGroups.first(where: { $0.rowIDs.contains(row.id) }) {
                    for gid in group.rowIDs { selectedRowIDs.remove(gid) }
                    coordinator?.deselectGroup(rowIDs: group.rowIDs)
                } else {
                    selectedRowIDs.remove(row.id)
                    coordinator?.deselect(rowID: row.id)
                }
                overlayView.selectedRowIDs = selectedRowIDs
                feedback.impactOccurred(intensity: 0.3)
            }
        }
    }

    private func finalizeTentative() {
        for rowID in tentativeRowIDs {
            selectedRowIDs.insert(rowID)
            coordinator?.select(rowID: rowID)
        }
        overlayView.selectedRowIDs = selectedRowIDs
        tentativeRowIDs.removeAll()
        overlayView.tentativeRowIDs = tentativeRowIDs
    }

    // MARK: - Tap Gesture

    @objc private func handleTap(_ g: UITapGestureRecognizer) {
        let pt = g.location(in: contentView)
        let ds = overlayView.imageDisplaySize
        guard ds.width > 0 else { return }

        for row in ocrRows where selectedRowIDs.contains(row.id) {
            let r = visionToView(row.boundingBox, ds: ds)
            let band = CGRect(x: 0, y: r.minY - 4, width: ds.width, height: r.height + 8)
            if band.contains(pt) {
                if let group = overlayView.itemGroups.first(where: { $0.rowIDs.contains(row.id) }) {
                    for gid in group.rowIDs { selectedRowIDs.remove(gid) }
                    coordinator?.deselectGroup(rowIDs: group.rowIDs)
                } else {
                    selectedRowIDs.remove(row.id)
                    coordinator?.deselect(rowID: row.id)
                }
                overlayView.selectedRowIDs = selectedRowIDs
                feedback.impactOccurred(intensity: 0.3)
                overlayView.setNeedsDisplay()
                return
            }
        }

        for row in ocrRows where !selectedRowIDs.contains(row.id) {
            let r = visionToView(row.boundingBox, ds: ds)
            let tol = max(r.height * 0.5, 8)
            if pt.y >= r.minY - tol && pt.y <= r.maxY + tol {
                selectedRowIDs.insert(row.id)
                overlayView.selectedRowIDs = selectedRowIDs
                coordinator?.select(rowID: row.id)
                feedback.impactOccurred(intensity: 0.6)
                overlayView.setNeedsDisplay()
                return
            }
        }
    }

    private func hitRow(at pt: CGPoint) -> ReceiptOCRService.OCRRow? {
        let ds = overlayView.imageDisplaySize
        guard ds.width > 0 else { return nil }
        for row in ocrRows {
            let r = visionToView(row.boundingBox, ds: ds)
            let tol = max(r.height * 0.5, 8)
            if pt.y >= r.minY - tol && pt.y <= r.maxY + tol { return row }
        }
        return nil
    }

    private func visionToView(_ rect: CGRect, ds: CGSize) -> CGRect {
        CGRect(
            x: rect.minX * ds.width,
            y: (1 - rect.minY - rect.height) * ds.height,
            width: rect.width * ds.width,
            height: rect.height * ds.height
        )
    }
}

// MARK: - White Dot Indicator

class CheckmarkView: UIView {
    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 2
        layer.shadowOffset = CGSize(width: 0, height: 0.5)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let inset = rect.insetBy(dx: 1, dy: 1)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.7).cgColor)
        ctx.fillEllipse(in: inset)
    }
}

// MARK: - Overlay Draw View

class ReceiptOverlayDrawView: UIView {
    var ocrRows: [ReceiptOCRService.OCRRow] = []
    var selectedRowIDs: Set<UUID> = []
    var tentativeRowIDs: Set<UUID> = []
    var parsedRowIDs: Set<UUID> = []
    var itemGroups: [ParsedItemGroup] = []
    var imageDisplaySize: CGSize = .zero

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(),
              imageDisplaySize.width > 0 else { return }

        // === Heavy dim over entire image (background is very dark) ===
        ctx.saveGState()
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.65).cgColor)
        ctx.fill(rect)

        // Punch out ALL text areas completely
        ctx.setBlendMode(.clear)
        ctx.beginPath()
        for row in ocrRows {
            let vr = visionToView(row.boundingBox)
            let padded = vr.insetBy(dx: -6, dy: -3)
            ctx.addRect(padded)
        }
        ctx.fillPath()
        ctx.restoreGState()

        // === Re-dim all non-parsed text equally (unselected + blue selected = same 35%) ===
        // First, compute merged parsed blocks (union overlapping/adjacent parsed rects)
        var rawParsedRects: [CGRect] = parsedRowIDs.compactMap { id -> CGRect? in
            guard let row = ocrRows.first(where: { $0.id == id }) else { return nil }
            return visionToView(row.boundingBox).insetBy(dx: -8, dy: -5)
        }
        // Sort top-to-bottom and merge overlapping/touching rects
        rawParsedRects.sort { $0.minY < $1.minY }
        var mergedParsedBlocks: [CGRect] = []
        for r in rawParsedRects {
            if let last = mergedParsedBlocks.last, last.intersects(r) || abs(last.maxY - r.minY) < 2 {
                mergedParsedBlocks[mergedParsedBlocks.count - 1] = last.union(r)
            } else {
                mergedParsedBlocks.append(r)
            }
        }

        // Clip out merged parsed blocks so dim never bleeds into them
        ctx.saveGState()
        let parsedExclude = UIBezierPath(rect: rect)
        for block in mergedParsedBlocks {
            parsedExclude.append(UIBezierPath(rect: block).reversing())
        }
        parsedExclude.addClip()

        // Single rect fill over clipped area — no per-row rects, no overlap artifacts
        ctx.setFillColor(UIColor.black.withAlphaComponent(0.35).cgColor)
        ctx.fill(rect)

        ctx.restoreGState()

        // === Parsed item group bright background (merged blocks, subtle lift) ===
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)

        // White fill using merged blocks — no seams between adjacent parsed rows
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.10).cgColor)
        for block in mergedParsedBlocks {
            let path = UIBezierPath(roundedRect: block, cornerRadius: 4)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // === Blue tint for selected-but-unparsed ===
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(UIColor.systemBlue.withAlphaComponent(0.12).cgColor)

        for row in ocrRows {
            guard selectedRowIDs.contains(row.id), !parsedRowIDs.contains(row.id) else { continue }
            let vr = visionToView(row.boundingBox)
            let padded = vr.insetBy(dx: -4, dy: -2)
            ctx.fill(padded)
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()

        // === Tentative highlights (bright white during swipe) ===
        ctx.saveGState()
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setFillColor(UIColor.white.withAlphaComponent(0.18).cgColor)

        for row in ocrRows where tentativeRowIDs.contains(row.id) {
            let vr = visionToView(row.boundingBox)
            let padded = vr.insetBy(dx: -4, dy: -2)
            ctx.fill(padded)
        }

        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    private func visionToView(_ rect: CGRect) -> CGRect {
        CGRect(
            x: rect.minX * imageDisplaySize.width,
            y: (1 - rect.minY - rect.height) * imageDisplaySize.height,
            width: rect.width * imageDisplaySize.width,
            height: rect.height * imageDisplaySize.height
        )
    }
}

// MARK: - Item Preview Sheet

struct ItemPreviewSheet: View {
    let items: [ParsedLineItem]
    let onSave: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var total: Double {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack {
                            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                Text(item.name)
                                    .font(.body)
                                if item.quantity > 1 {
                                    Text("×\(Int(item.quantity)) @ \(String(format: "%.2f", item.unitPrice))")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                            Spacer()
                            Text(String(format: "%.2f", item.lineTotal))
                                .font(.body.monospacedDigit())
                                .fontWeight(.medium)
                        }
                    }
                }

                Section {
                    HStack {
                        Text("Total")
                            .fontWeight(.bold)
                        Spacer()
                        Text(String(format: "%.2f", total))
                            .font(.body.monospacedDigit())
                            .fontWeight(.bold)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Scanned Items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave() }
                }
            }
        }
    }
}

import SwiftUI
import UIKit

struct ReceiptImageEditorView: View {
    let originalImage: UIImage
    let onSave: (UIImage) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rotationSteps = 0        // 0,1,2,3 → 0°,90°,180°,270°
    @State private var fineAngle: Double = 0    // -45...45 degrees

    /// Only rendered on save — NOT during live preview
    private func renderFinalImage() -> UIImage {
        var img = originalImage
        if rotationSteps % 4 != 0 {
            img = Self.rotate90(img, steps: rotationSteps % 4)
        }
        if abs(fineAngle) > 0.1 {
            img = Self.rotateFine(img, degrees: fineAngle)
        }
        return img
    }

    /// Base image with only 90° steps applied (cheap orientation change)
    private var rotatedBase: UIImage {
        rotationSteps % 4 != 0
            ? Self.rotate90(originalImage, steps: rotationSteps % 4)
            : originalImage
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Image preview — fine angle via rotationEffect (GPU, no bitmap)
                GeometryReader { geo in
                    Image(uiImage: rotatedBase)
                        .resizable()
                        .scaledToFit()
                        .rotationEffect(.degrees(fineAngle))
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                }

                // Controls
                VStack(spacing: AppSpacing.md) {
                    Divider()

                    // Tick-mark angle ruler
                    AngleRulerView(angle: $fineAngle)
                        .frame(height: 56)
                        .padding(.horizontal, AppSpacing.pageHorizontal)

                    // Single rotate button (like Apple Photos)
                    HStack {
                        Spacer()
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) {
                                rotationSteps = (rotationSteps + 3) % 4 // CCW 90°
                            }
                            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        } label: {
                            Image(systemName: "rotate.left")
                                .font(AppFonts.iconLarge)
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                        }
                        Spacer()
                    }

                    Spacer().frame(height: 4)
                }
                .padding(.bottom, AppSpacing.lg)
                .background(.ultraThinMaterial)
            }
            .background(Color.black)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .principal) {
                    Text("Adjust Photo")
                        .font(.headline)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(renderFinalImage())
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Image Rotation Helpers

    private static func rotate90(_ image: UIImage, steps: Int) -> UIImage {
        guard steps > 0, let cgImage = image.cgImage else { return image }

        let orientations: [UIImage.Orientation] = [.up, .right, .down, .left]
        let currentIndex: Int
        switch image.imageOrientation {
        case .up: currentIndex = 0
        case .right: currentIndex = 1
        case .down: currentIndex = 2
        case .left: currentIndex = 3
        default: currentIndex = 0
        }
        let newIndex = (currentIndex + steps) % 4
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: orientations[newIndex])
    }

    private static func rotateFine(_ image: UIImage, degrees: Double) -> UIImage {
        let radians = CGFloat(degrees) * .pi / 180
        let size = image.size

        let rotatedRect = CGRect(origin: .zero, size: size)
            .applying(CGAffineTransform(rotationAngle: radians))
        let newSize = CGSize(width: abs(rotatedRect.width), height: abs(rotatedRect.height))

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        guard let ctx = UIGraphicsGetCurrentContext() else { return image }

        ctx.translateBy(x: newSize.width / 2, y: newSize.height / 2)
        ctx.rotate(by: radians)
        image.draw(in: CGRect(
            x: -size.width / 2,
            y: -size.height / 2,
            width: size.width,
            height: size.height
        ))

        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result ?? image
    }
}

// MARK: - Apple Photos-style Angle Ruler

struct AngleRulerView: UIViewRepresentable {
    @Binding var angle: Double

    func makeCoordinator() -> Coordinator { Coordinator(angle: $angle) }

    func makeUIView(context: Context) -> AngleRulerUIView {
        let view = AngleRulerUIView()
        view.onAngleChanged = { newAngle in
            context.coordinator.angle.wrappedValue = newAngle
        }
        view.setAngle(angle, animated: false)
        return view
    }

    func updateUIView(_ uiView: AngleRulerUIView, context: Context) {
        if abs(uiView.currentAngle - angle) > 0.05 {
            uiView.setAngle(angle, animated: false)
        }
    }

    class Coordinator {
        var angle: Binding<Double>
        init(angle: Binding<Double>) { self.angle = angle }
    }
}

class AngleRulerUIView: UIView {
    var onAngleChanged: ((Double) -> Void)?
    private(set) var currentAngle: Double = 0

    private let scrollView = UIScrollView()
    private let tickContainer = UIView()
    private let centerLine = UIView()
    private let angleLabel = UILabel()
    private let feedback = UISelectionFeedbackGenerator()

    private let totalDegrees: Double = 90     // -45 to +45
    private let degreesPerTick: Double = 1.0
    private let tickSpacing: CGFloat = 12.0
    private var lastHapticTick: Int = 0
    private var isUpdatingFromCode = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        backgroundColor = .clear
        clipsToBounds = true

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.decelerationRate = .fast
        scrollView.delegate = self
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        scrollView.addSubview(tickContainer)

        // Center indicator (yellow line)
        centerLine.backgroundColor = UIColor.systemYellow
        centerLine.translatesAutoresizingMaskIntoConstraints = false
        centerLine.layer.cornerRadius = 1.5
        addSubview(centerLine)

        // Angle label
        angleLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        angleLabel.textColor = .secondaryLabel
        angleLabel.textAlignment = .center
        angleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(angleLabel)
        angleLabel.text = "0°"

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scrollView.heightAnchor.constraint(equalToConstant: 28),

            centerLine.centerXAnchor.constraint(equalTo: centerXAnchor),
            centerLine.topAnchor.constraint(equalTo: scrollView.topAnchor),
            centerLine.widthAnchor.constraint(equalToConstant: 3),
            centerLine.heightAnchor.constraint(equalToConstant: 28),

            angleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            angleLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 2),
        ])

        feedback.prepare()
    }

    private var hasBuiltTicks = false
    private var hasSetInitial = false
    private var didCompleteSetup = false

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }

        isUpdatingFromCode = true

        let tickCount = Int(totalDegrees / degreesPerTick) + 1  // 91 ticks
        let contentWidth = CGFloat(tickCount - 1) * tickSpacing
        let sideInset = bounds.width / 2

        tickContainer.frame = CGRect(x: 0, y: 0, width: contentWidth + sideInset * 2, height: 28)
        scrollView.contentSize = tickContainer.frame.size
        scrollView.contentInset = .zero

        // Build ticks only once
        if !hasBuiltTicks {
            hasBuiltTicks = true
            for i in 0..<tickCount {
                let degree = -45 + Double(i) * degreesPerTick
                let x = sideInset + CGFloat(i) * tickSpacing
                let isMajor = Int(degree) % 10 == 0
                let isZero = abs(degree) < 0.1

                let tickH: CGFloat = isZero ? 22 : (isMajor ? 14 : 8)
                let tickW: CGFloat = isZero ? 3 : (isMajor ? 1.5 : 1)
                let tickY: CGFloat = (28 - tickH) / 2

                let tick = UIView(frame: CGRect(x: x - tickW / 2, y: tickY, width: tickW, height: tickH))
                tick.backgroundColor = isZero ? .white : (isMajor ? .white.withAlphaComponent(0.5) : .white.withAlphaComponent(0.25))
                tick.layer.cornerRadius = tickW / 2
                tickContainer.addSubview(tick)
            }
        }

        // Set initial scroll to 0° exactly once
        if !hasSetInitial {
            hasSetInitial = true
            let offsetX = sideInset + CGFloat(45.0 / degreesPerTick) * tickSpacing - bounds.width / 2
            scrollView.contentOffset = CGPoint(x: offsetX, y: 0)
            currentAngle = 0
            lastHapticTick = 45
            // Allow scroll callbacks only after UIKit finishes settling
            DispatchQueue.main.async { [weak self] in
                self?.isUpdatingFromCode = false
                self?.didCompleteSetup = true
            }
            return  // don't reset isUpdatingFromCode synchronously
        }

        isUpdatingFromCode = false
    }

    func setAngle(_ angle: Double, animated: Bool) {
        currentAngle = max(-45, min(45, angle))
        let sideInset = bounds.width / 2
        let offsetX = sideInset + CGFloat((currentAngle + 45) / degreesPerTick) * tickSpacing - bounds.width / 2

        isUpdatingFromCode = true
        scrollView.setContentOffset(CGPoint(x: offsetX, y: 0), animated: animated)
        isUpdatingFromCode = false
        updateLabel()
    }

    private func angleFromOffset() -> Double {
        let sideInset = bounds.width / 2
        let centerOffset = scrollView.contentOffset.x + bounds.width / 2 - sideInset
        let angle = (Double(centerOffset) / Double(tickSpacing)) * degreesPerTick - 45
        return max(-45, min(45, angle))
    }

    private func updateLabel() {
        if abs(currentAngle) < 0.05 {
            angleLabel.text = "0°"
        } else {
            angleLabel.text = String(format: "%.1f°", currentAngle)
        }
    }
}

extension AngleRulerUIView: UIScrollViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard didCompleteSetup, !isUpdatingFromCode else { return }

        let newAngle = angleFromOffset()
        currentAngle = newAngle
        updateLabel()

        // Haptic on each degree tick
        let tickIndex = Int(round((newAngle + 45) / degreesPerTick))
        if tickIndex != lastHapticTick {
            lastHapticTick = tickIndex
            let isMajor = Int(round(newAngle)) % 10 == 0
            if isMajor {
                UIImpactFeedbackGenerator(style: .light).impactOccurred(intensity: 0.6)
            } else {
                feedback.selectionChanged()
            }
        }

        onAngleChanged?(newAngle)
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { snapToNearestTick() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        snapToNearestTick()
    }

    private func snapToNearestTick() {
        let angle = angleFromOffset()
        let snapped = round(angle / degreesPerTick) * degreesPerTick
        setAngle(snapped, animated: true)
        onAngleChanged?(snapped)

        // Snap to zero with stronger haptic
        if abs(snapped) < 0.5 && abs(currentAngle) < 1.5 {
            setAngle(0, animated: true)
            onAngleChanged?(0)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        }
    }
}

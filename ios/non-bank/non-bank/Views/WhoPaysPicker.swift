// WhoPaysPicker — Drum-roll "Who pays?" picker.
// Commented out for now. Preserved for future use.
// The new split flow uses WhoPaidPickerView instead.

/*
import SwiftUI
import AudioToolbox

/// A "Who pays?" drum-roll picker shown as a half-sheet after saving a split transaction.
struct WhoPaysPicker: View {
    let friends: [Friend]
    let totalAmount: String
    let currency: String
    let onConfirm: (_ payerName: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedIndex: Int = 0

    private var options: [String] {
        ["Me"] + friends.map(\.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Drag indicator
            Capsule()
                .fill(AppColors.textQuaternary)
                .frame(width: 36, height: 5)
                .padding(.top, AppSpacing.sm)
                .padding(.bottom, AppSpacing.md)

            // Title
            Text("Who paid")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textSecondary)
                .padding(.bottom, AppSpacing.sm)

            Spacer()

            // Drum-roll picker
            PayerWheel(
                options: options,
                selectedIndex: $selectedIndex,
                totalAmount: totalAmount,
                currency: currency
            )

            Spacer()

            // Confirm button — minimal style
            Button {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                onConfirm(options[selectedIndex])
            } label: {
                Text("Confirm")
                    .font(AppFonts.bodyEmphasized)
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(AppColors.backgroundElevated)
                    .cornerRadius(AppRadius.xlarge)
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.bottom, AppSpacing.xxxl)
        }
        .background(AppColors.backgroundPrimary)
        .presentationDetents([.medium])
        .presentationDragIndicator(.hidden)
    }
}

// MARK: - Drum-Roll Picker

private struct PayerWheel: View {
    let options: [String]
    @Binding var selectedIndex: Int
    let totalAmount: String
    let currency: String

    private let fontSize: CGFloat = 21
    private let nameColumnRatio: CGFloat = 0.28
    // Reserve 2 lines of text height per slot for the suffix
    private var slotHeight: CGFloat { ceil(fontSize * 1.2) * 2 + 4 } // ~54pt for selected + neighbors
    private let compressedHeight: CGFloat = 28 // distant items spacing
    private let visibleCount = 5

    @State private var currentIndex: CGFloat = 0 // continuous float index for smooth tracking
    @State private var dragStartIndex: CGFloat = 0
    @State private var lastHapticIndex: Int = -1
    @State private var isDragging: Bool = false

    private var totalHeight: CGFloat { slotHeight * CGFloat(visibleCount) }
    private var centerY: CGFloat { totalHeight / 2 }

    /// Compute the y-position of a given item index relative to center,
    /// using compressed spacing for items far from the selected one.
    private func yPosition(for index: Int, activeIndex: CGFloat) -> CGFloat {
        let delta = CGFloat(index) - activeIndex
        let absDelta = abs(delta)
        let sign: CGFloat = delta >= 0 ? 1 : -1

        if absDelta <= 1.0 {
            // Selected item and immediate neighbors: full spacing
            return centerY + delta * slotHeight - slotHeight / 2
        } else {
            // First slot at full height, then compressed for the rest
            let fullPart: CGFloat = 1.0 * slotHeight
            let compressedPart = (absDelta - 1.0) * compressedHeight
            return centerY + sign * (fullPart + compressedPart) - slotHeight / 2
        }
    }

    var body: some View {
        GeometryReader { geo in
            let nameWidth = geo.size.width * nameColumnRatio

            ZStack {
                // Left column: names drum-roll
                ForEach(Array(options.enumerated()), id: \.offset) { index, name in
                    let yPos = yPosition(for: index, activeIndex: currentIndex)
                    let distanceFromCenter = abs(yPos - centerY + slotHeight / 2)
                    let normalizedDistance = min(distanceFromCenter / (totalHeight / 2), 1.0)
                    let opacity = max(1.0 - normalizedDistance * 1.2, 0.0)
                    let isSelected = index == selectedIndex

                    Text(name)
                        .font(.system(size: fontSize, weight: isSelected ? .bold : .medium))
                        .foregroundColor(isSelected ? AppColors.splitAccent : AppColors.textQuaternary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: nameWidth, height: slotHeight, alignment: .topTrailing)
                        .opacity(opacity)
                        .position(x: nameWidth / 2, y: yPos)
                        .onTapGesture {
                            guard index != selectedIndex else { return }
                            AudioServicesPlaySystemSound(1157)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                                selectedIndex = index
                                currentIndex = CGFloat(index)
                            }
                        }
                }

                // Right column: suffix, always aligned with selected name
                Text(" paid \(totalAmount) \(currency)")
                    .font(.system(size: fontSize, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)
                    .frame(width: geo.size.width - nameWidth, height: slotHeight, alignment: .topLeading)
                    .position(x: nameWidth + (geo.size.width - nameWidth) / 2,
                              y: yPosition(for: selectedIndex, activeIndex: currentIndex))
            }
            .frame(width: geo.size.width, height: totalHeight)
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .frame(height: totalHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isDragging {
                        isDragging = true
                        dragStartIndex = currentIndex
                    }
                    let dragDelta = -value.translation.height / slotHeight
                    let newIndex = dragStartIndex + dragDelta
                    let clamped = max(0, min(newIndex, CGFloat(options.count - 1)))
                    currentIndex = clamped

                    let snappedIndex = Int(round(clamped))
                    if snappedIndex != lastHapticIndex {
                        AudioServicesPlaySystemSound(1157)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        lastHapticIndex = snappedIndex
                    }
                    selectedIndex = snappedIndex
                }
                .onEnded { _ in
                    isDragging = false
                    let snapped = CGFloat(selectedIndex)
                    withAnimation(.spring(response: 0.45, dampingFraction: 1.0)) {
                        currentIndex = snapped
                    }
                    lastHapticIndex = -1
                }
        )
        .onAppear {
            currentIndex = CGFloat(selectedIndex)
        }
    }
}
*/

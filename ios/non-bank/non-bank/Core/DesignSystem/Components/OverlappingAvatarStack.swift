import SwiftUI

/// Horizontal pile of pixel-cat avatars — each clipped to a circle
/// and outlined with the surface colour so adjacent avatars read as
/// overlapping discs rather than a continuous smear. Overlap is 50%
/// of the avatar diameter; first participant sits on top via `zIndex`
/// so the stacking direction stays "primary face leads".
///
/// Used in two places: the Home `DebtBadgeView` debt pill (size 20)
/// and the create-modal split chip (size 14). New compact stacks
/// should reuse this rather than re-derive the geometry — the 50%
/// overlap and per-row `zIndex` are easy to get subtly wrong.
struct OverlappingAvatarStack: View {
    struct Participant: Hashable {
        let id: String
        let isConnected: Bool
    }

    let participants: [Participant]
    let avatarSize: CGFloat
    /// Outline colour — should match the surrounding surface fill so
    /// the ring blends into the background and only the dark disc
    /// edge between adjacent avatars reads visibly.
    let strokeColor: Color
    var strokeWidth: CGFloat = 1.5
    var maxVisible: Int = 3

    var body: some View {
        let visible = Array(participants.prefix(maxVisible))
        let overlap = avatarSize * 0.5
        return HStack(spacing: -overlap) {
            ForEach(Array(visible.enumerated()), id: \.offset) { idx, p in
                PixelCatView(id: p.id, size: avatarSize, blackAndWhite: !p.isConnected)
                    .clipShape(Circle())
                    .overlay(
                        Circle().stroke(strokeColor, lineWidth: strokeWidth)
                    )
                    .zIndex(Double(visible.count - idx))
            }
        }
    }
}

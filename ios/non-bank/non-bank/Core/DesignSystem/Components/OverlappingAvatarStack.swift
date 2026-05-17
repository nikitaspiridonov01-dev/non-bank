import SwiftUI

/// Horizontal pile of pixel-cat avatars — each clipped to a circle
/// and outlined with the surface colour so adjacent avatars read as
/// overlapping discs rather than a continuous smear. Overlap is 50%
/// of the avatar diameter; rightmost element sits on top via `zIndex`
/// so the "+N" overflow pill — always at the tail — naturally leads
/// the row instead of needing a special zIndex to overlap its
/// neighbour. Earlier a "first participant leads" stack forced the
/// pill to claim zIndex 2.5 as a one-off so the "+" wasn't hidden
/// under the trailing avatar, which read as inconsistent against the
/// rest of the row (the pill was the only element breaking the
/// stacking rule).
///
/// When the data carries more participants than `maxVisible` allows,
/// an extra "+N" pill renders at the tail showing the number that
/// didn't fit. The pill matches the avatars' size + stroke so it
/// reads as another member of the row, not a separate badge.
///
/// Used in two places: the Home `DebtBadgeView` debt pill (size 20)
/// and the create-modal split chip (also size 20 — matched to home
/// for visual consistency across screens). New compact stacks
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
    /// Number of participants beyond the `maxVisible` cap that exist
    /// in the source data but couldn't fit. When > 0, an extra "+N"
    /// pill renders at the tail of the row to signal the truncation.
    /// Callers compute this from their own source (e.g.
    /// `DebtSummary.nonZeroFriendCount - maxVisible`).
    var overflowCount: Int = 0

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
                    .zIndex(Double(idx))
            }
            if overflowCount > 0 {
                overflowPill
                    .zIndex(Double(visible.count))
            }
        }
    }

    private var overflowPill: some View {
        Text("+\(overflowCount)")
            // Font scales with the avatar so the +N reads as the
            // same row weight as the cats. ~45% of avatar size is the
            // sweet spot: legible but doesn't pop out as an alert.
            .font(.system(size: avatarSize * 0.45, weight: .semibold))
            .foregroundColor(AppColors.textSecondary)
            .frame(width: avatarSize, height: avatarSize)
            .background(
                Circle().fill(AppColors.backgroundChip)
            )
            .overlay(
                Circle().stroke(strokeColor, lineWidth: strokeWidth)
            )
    }
}

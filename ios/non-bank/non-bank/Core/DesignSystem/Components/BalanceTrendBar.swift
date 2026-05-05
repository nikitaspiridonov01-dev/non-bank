import SwiftUI

/// A single trend bar with color states: hovered, dimmed, recent, or default.
struct BalanceTrendBar: View {
    let height: CGFloat
    let isHovered: Bool
    let isDimmed: Bool
    let isRecent: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: AppSizes.trendBarWidth)
            .fill(barColor)
            .frame(width: AppSizes.trendBarWidth, height: height)
            .animation(.easeInOut(duration: 0.18), value: height)
    }

    private var barColor: Color {
        if isHovered {
            return AppColors.trendBarHovered
        } else if isDimmed {
            return AppColors.trendBarDimmed
        } else if isRecent {
            return AppColors.trendBarRecent
        } else {
            return AppColors.trendBarDefault
        }
    }
}

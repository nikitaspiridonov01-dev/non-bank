import SwiftUI

// MARK: - Quick Filters Bar

struct QuickFiltersBar: View {
    let topCategories: [String]
    let getEmoji: (String) -> String
    let isActive: (QuickFilter) -> Bool
    let onToggle: (QuickFilter) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(topCategories, id: \.self) { cat in
                    let filter = QuickFilter.category(cat)
                    QuickFilterButton(
                        title: cat,
                        emoji: getEmoji(cat),
                        isActive: isActive(filter),
                        action: { onToggle(filter) }
                    )
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }
}

// MARK: - Quick Filter Button

struct QuickFilterButton: View {
    let title: String
    let emoji: String?
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            withAnimation {
                action()
            }
        }) {
            HStack(spacing: 6) {
                if let emoji = emoji {
                    Text(emoji).font(AppFonts.emojiSmall)
                }
                Text(title)
                    .font(AppFonts.labelSecondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.sm)
            .background(isActive ? Color.accentColor.opacity(0.15) : AppColors.backgroundChipSoft)
            .foregroundColor(isActive ? .accentColor : AppColors.textPrimary)
            .cornerRadius(AppRadius.large)
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .stroke(isActive ? Color.accentColor.opacity(0.5) : AppColors.border, lineWidth: 0.5)
            )
        }
    }
}

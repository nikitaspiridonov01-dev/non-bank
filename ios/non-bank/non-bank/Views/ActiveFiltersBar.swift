import SwiftUI

// MARK: - Active Filters Sticky Bar

struct ActiveFiltersBar: View {
    let activeCategories: Set<String>
    let activeTypes: Set<TransactionType>
    let getEmoji: (String) -> String
    let onRemoveCategory: (String) -> Void
    let onRemoveType: (TransactionType) -> Void
    let onClearAll: () -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AppSpacing.sm) {
                ForEach(Array(activeCategories), id: \.self) { cat in
                    ActiveFilterChip(text: cat, emoji: getEmoji(cat)) { onRemoveCategory(cat) }
                }
                ForEach(Array(activeTypes), id: \.self) { type in
                    ActiveFilterChip(text: type == .income ? "Income" : "Expenses", emoji: nil) { onRemoveType(type) }
                }
                
                Button("Clear all") {
                    withAnimation {
                        onClearAll()
                    }
                }
                .font(AppFonts.labelCaption)
                .foregroundColor(.accentColor)
                .padding(.leading, AppSpacing.sm)
                .padding(.trailing, AppSpacing.lg)
            }
            .padding(.leading, AppSpacing.lg)
            .padding(.vertical, 10)
        }
    }
}

// MARK: - Active Filter Chip

struct ActiveFilterChip: View {
    let text: String
    let emoji: String?
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let emoji = emoji {
                Text(emoji)
                    .font(AppFonts.rowDescription)
            }
            Text(text)
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textPrimary)
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.horizontal, AppSizes.chipHorizontalPadding)
        .padding(.vertical, AppSizes.chipVerticalPadding)
        .background(AppColors.backgroundChip)
        .cornerRadius(AppRadius.large)
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .stroke(AppColors.border, lineWidth: 0.5)
        )
        .onTapGesture {
            withAnimation { onRemove() }
        }
    }
}

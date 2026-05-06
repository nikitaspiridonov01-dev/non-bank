import SwiftUI

/// Review screen shown after `HybridReceiptParser` returns structured items.
/// User can drop unwanted lines via swipe-delete and confirm to push the
/// items + computed total back to the create-transaction flow.
struct ReceiptReviewView: View {
    let parseResult: HybridReceiptParser.Result
    let sourceImage: UIImage?
    var onConfirm: (_ items: [ReceiptItem], _ total: Double) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var items: [ReceiptItem]
    @State private var currency: String

    init(
        parseResult: HybridReceiptParser.Result,
        sourceImage: UIImage?,
        onConfirm: @escaping (_ items: [ReceiptItem], _ total: Double) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.parseResult = parseResult
        self.sourceImage = sourceImage
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _items = State(initialValue: parseResult.parsedReceipt.items)
        _currency = State(initialValue: parseResult.parsedReceipt.currency ?? "USD")
    }

    private var itemsTotal: Double {
        items.reduce(0) { $0 + $1.lineTotal }
    }

    private var grandTotal: Double? {
        parseResult.parsedReceipt.totalAmount
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xl) {
                    headerBlock
                    confidenceBannerIfNeeded
                    itemsList
                    totalsSummary
                    Spacer().frame(height: 40)
                }
                .padding(.top, AppSpacing.lg)
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Receipt items")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use") {
                        onConfirm(items, itemsTotal)
                        dismiss()
                    }
                    .disabled(items.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var headerBlock: some View {
        HStack(alignment: .center, spacing: 14) {
            if let image = sourceImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 64, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.small))
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.small)
                            .stroke(AppColors.border, lineWidth: 1)
                    )
            } else {
                RoundedRectangle(cornerRadius: AppRadius.small)
                    .fill(AppColors.backgroundChip)
                    .frame(width: 64, height: 80)
                    .overlay(
                        Image(systemName: "doc.text.image")
                            .font(AppFonts.emojiMedium)
                            .foregroundColor(AppColors.textTertiary)
                    )
            }
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                if let store = parseResult.parsedReceipt.storeName, !store.isEmpty {
                    Text(store)
                        .font(AppFonts.subhead)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                }
                if let date = parseResult.parsedReceipt.date, !date.isEmpty {
                    Text(date)
                        .font(.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                }
                Text("\(items.count) \(items.count == 1 ? "item" : "items")")
                    .font(.caption)
                    .foregroundColor(AppColors.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Confidence banner

    @ViewBuilder
    private var confidenceBannerIfNeeded: some View {
        switch parseResult.confidence {
        case .high:
            EmptyView()
        case .medium:
            banner(
                icon: "exclamationmark.triangle.fill",
                tint: AppColors.warning,
                title: "Totals don't match",
                subtitle: "The sum of items doesn't match the receipt total. Please review the lines below."
            )
        case .low:
            banner(
                icon: "info.circle.fill",
                tint: AppColors.textSecondary,
                title: "Quick scan",
                subtitle: "Apple Intelligence isn't available, so we used a simpler text parser. Double-check the items."
            )
        }
    }

    private func banner(icon: String, tint: Color, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(tint)
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(AppColors.textSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .fill(tint.opacity(0.1))
        )
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Items list

    @ViewBuilder
    private var itemsList: some View {
        if items.isEmpty {
            VStack(spacing: AppSpacing.sm) {
                Image(systemName: "tray")
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(AppColors.textTertiary)
                Text("No items detected")
                    .font(.subheadline)
                    .foregroundColor(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: AppSpacing.sm) {
                ForEach(items) { item in
                    itemRow(item)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
    }

    private func itemRow(_ item: ReceiptItem) -> some View {
        HStack(alignment: .center, spacing: AppSpacing.md) {
            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(item.name)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(2)
                if let qty = item.quantity, qty != 1, let price = item.price {
                    Text("\(formattedQuantity(qty)) × \(formattedAmount(price))")
                        .font(.caption)
                        .foregroundColor(AppColors.textSecondary)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(NumberFormatting.integerPart(item.lineTotal))
                    .font(AppFonts.rowAmountInteger)
                    .foregroundColor(AppColors.textPrimary)
                Text(NumberFormatting.decimalPartIfAny(item.lineTotal))
                    .font(AppFonts.rowAmountCurrency)
                    .foregroundColor(AppColors.textSecondary)
                Text(currency)
                    .font(AppFonts.rowAmountCurrency)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.leading, 3)
            }
            .fixedSize(horizontal: true, vertical: false)
            Button(action: { delete(item) }) {
                Image(systemName: "minus.circle.fill")
                    .font(AppFonts.iconLarge)
                    .foregroundColor(AppColors.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove item")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
    }

    // MARK: - Totals

    @ViewBuilder
    private var totalsSummary: some View {
        VStack(spacing: 6) {
            HStack {
                Text("Items total")
                    .font(.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
                amountText(itemsTotal, primary: true)
            }
            if let grand = grandTotal, grand > 0 {
                HStack {
                    Text("Receipt total")
                        .font(.subheadline)
                        .foregroundColor(AppColors.textSecondary)
                    Spacer()
                    amountText(grand, primary: false)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    private func amountText(_ amount: Double, primary: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(NumberFormatting.integerPart(amount))
                .font(.system(size: 17, weight: primary ? .bold : .medium))
                .foregroundColor(primary ? AppColors.textPrimary : AppColors.textSecondary)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(AppFonts.captionEmphasized)
                .foregroundColor(AppColors.textSecondary)
            Text(currency)
                .font(AppFonts.captionEmphasized)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 3)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    // MARK: - Actions

    private func delete(_ item: ReceiptItem) {
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Formatting

    private func formattedQuantity(_ quantity: Double) -> String {
        if quantity.rounded() == quantity {
            return String(Int(quantity))
        }
        return String(format: "%.2f", quantity)
    }

    private func formattedAmount(_ value: Double) -> String {
        NumberFormatting.integerPart(value) + NumberFormatting.decimalPartIfAny(value)
    }
}

import SwiftUI

/// Shown right after a user saves a new split transaction.
///
/// Nudges them to send the share link to their friends before they
/// forget — the receiver opens the link and the split lands in their
/// own non-bank automatically. Mirrors the share path on
/// `TransactionDetailView` so users get the same experience from
/// both entry points:
///   - If the user already set their profile name, the system share
///     sheet pops directly.
///   - If the name isn't set yet, `ProfileNameSheet` is presented
///     first; on save the flow transitions to the share sheet
///     automatically.
///
/// Both presentations ride on a **single** `.sheet(item:)` driven by
/// the `ShareFlowStep` state machine — the same unified-sheet
/// pattern `TransactionDetailView` uses. Stacking two separate
/// `.sheet` bindings caused dismissal-animation conflicts in the
/// transaction-detail screen; we cribbed the working solution rather
/// than reinventing it here.
struct ShareSplitPromptSheet: View {
    let transaction: Transaction

    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    @State private var shareFlow: ShareFlowStep? = nil
    @Environment(\.dismiss) private var dismiss

    /// One-shot state machine for the share flow. `Identifiable`
    /// because `.sheet(item:)` requires it.
    private enum ShareFlowStep: Identifiable {
        /// Profile name not set yet — present `ProfileNameSheet`
        /// first so the receiver sees who shared.
        case askName(initial: String)
        /// Name is set — present the system share sheet with the
        /// composed URL.
        case share(URL)

        var id: String {
            switch self {
            case .askName: return "askName"
            case .share(let url): return "share-\(url.absoluteString)"
            }
        }
    }

    private var resolvedCategory: Category? {
        categoryStore.categories.first(where: { $0.title == transaction.category })
    }

    private func buildShareURL() -> URL? {
        guard let category = resolvedCategory else { return nil }
        return try? SharedTransactionLink.encode(
            transaction: transaction,
            sharerID: UserIDService.currentID(),
            sharerName: UserProfileService.displayName(),
            friends: friendStore.friends,
            category: category,
            repeatInterval: transaction.repeatInterval
        )
    }

    /// Tap handler for the "Share now" button. Matches the logic in
    /// `TransactionDetailView.handleShareTap` — name-gate before the
    /// system share sheet so the receiver sees who sent the link.
    private func handleShareTap() {
        if UserProfileService.isNameSet {
            if let url = buildShareURL() {
                shareFlow = .share(url)
                uploadShareItemsIfApplicable(for: url)
            }
        } else {
            shareFlow = .askName(initial: "")
        }
    }

    /// Mirrors `TransactionDetailView.uploadShareItemsIfApplicable`.
    /// Kept inline rather than centralised on `ShareItemsService`
    /// because the dependencies (transaction + receiptItemStore) live
    /// in the view layer; centralising would force the service to grow
    /// store dependencies it otherwise doesn't need.
    private func uploadShareItemsIfApplicable(for url: URL) {
        guard transaction.splitInfo?.splitMode == .byItems else { return }
        let items = receiptItemStore.items(forTransactionID: transaction.id)
        guard !items.isEmpty else { return }
        guard let urlPayload = SharedTransactionLink.urlPayloadString(of: url) else { return }
        guard let shareID = try? SharedTransactionLink.payloadChecksum(of: url) else { return }
        Task {
            do {
                let ciphertext = try ShareItemsCrypto.encryptItems(items, urlPayload: urlPayload)
                try await ShareItemsService.shared.upload(shareID: shareID, ciphertextBase64: ciphertext)
            } catch {
                #if DEBUG
                print("[ShareItems] upload failed: \(error.localizedDescription)")
                #endif
            }
        }
    }

    /// Persist the name, then swap the sheet content from the name
    /// prompt to the share-activity view. Single `.sheet(item:)`
    /// binding means SwiftUI sees a clean content swap instead of a
    /// dismiss-then-present sequence (the latter would race with the
    /// first sheet's dismiss animation and drop the activity sheet).
    private func handleProfileNameSaved(_ newName: String) {
        UserProfileService.setDisplayName(newName)
        guard let url = buildShareURL() else {
            shareFlow = nil
            return
        }
        shareFlow = .share(url)
        uploadShareItemsIfApplicable(for: url)
    }

    var body: some View {
        VStack(spacing: AppSpacing.xl) {
            // Spacer + decorative iconography keeps the sheet feeling
            // celebratory rather than transactional.
            VStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle()
                        .fill(AppColors.splitAccent.opacity(0.15))
                        .frame(width: 84, height: 84)
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundColor(AppColors.splitAccent)
                }

                Text("Split saved")
                    .font(AppFonts.displayMedium)
                    .foregroundColor(AppColors.textPrimary)

                Text("Send \u{201C}\(transaction.title)\u{201D} to friends so they always have the latest version on their side.")
                    .font(AppFonts.bodyRegular)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, AppSpacing.lg)
            }

            VStack(spacing: AppSpacing.sm) {
                Button(action: handleShareTap) {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "square.and.arrow.up")
                            .font(AppFonts.bodyEmphasized)
                        Text("Share now")
                            .font(AppFonts.bodyEmphasized)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(AppColors.splitAccentBold)
                    .cornerRadius(AppRadius.rowPill)
                }
                .disabled(resolvedCategory == nil)

                Button {
                    dismiss()
                } label: {
                    Text("Maybe later")
                        .font(AppFonts.bodyRegular)
                        .foregroundColor(AppColors.textSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
        .padding(.vertical, AppSpacing.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Match the canonical sheet background used everywhere else
        // (CategoriesSheetView, CurrencyRatesSheet, CreateTransactionModal).
        // `presentationBackground(.regularMaterial)` on the presenter
        // was rendering as a flat translucent grey card that didn't
        // match the rest of the sheet family.
        .background(AppColors.backgroundPrimary)
        // Single sheet binding — same unified-sheet trick as
        // `TransactionDetailView`. Content swaps based on
        // `shareFlow`; without this, asking the name and presenting
        // the share sheet from two separate `.sheet` bindings
        // produces a visible dismiss-then-present race.
        .sheet(item: $shareFlow) { step in
            switch step {
            case .askName(let initial):
                ProfileNameSheet(
                    initialName: initial,
                    title: "Your name",
                    subtitle: "This is shown to people you share split transactions with. You can change it anytime in Settings.",
                    saveButtonTitle: "Continue",
                    dismissOnSave: false
                ) { newName in
                    handleProfileNameSaved(newName)
                }
            case .share(let url):
                let summary = buildSummary(for: url)
                ShareSheet(activityItems: [
                    TransactionShareItemSource(url: url, summaryText: summary)
                ])
                .ignoresSafeArea()
                .onDisappear {
                    // Drop the prompt itself once the system share
                    // sheet finishes (whether the user shared or
                    // cancelled). Keeps the flow short.
                    shareFlow = nil
                    dismiss()
                }
            }
        }
    }

    private func buildSummary(for url: URL) -> String {
        let context = TransactionShareSummary.Context(
            title: transaction.title,
            categoryEmoji: resolvedCategory?.emoji ?? transaction.emoji,
            totalAmount: transaction.splitInfo?.totalAmount ?? transaction.amount,
            currency: transaction.currency,
            isExpense: transaction.type != .income,
            date: transaction.date,
            sharerName: UserProfileService.displayName(),
            items: [],
            recurring: transaction.repeatInterval
        )
        return TransactionShareSummary.build(context)
    }
}

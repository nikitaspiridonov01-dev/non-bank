import SwiftUI
import PhotosUI

// MARK: - Transaction Tab

enum TransactionTab: Int, CaseIterable {
    case expense, income, split
}

/// Drives the review-sheet presentation. Wraps the parser result + the source
/// image so the sheet content has everything it needs to render.
private struct ReceiptReviewPayload: Identifiable {
    let id = UUID()
    let result: HybridReceiptParser.Result
    let image: UIImage?
}

/// Bundle of bindings + callbacks needed to drive the receipt scan flow.
/// Extracted into a `ViewModifier` so SwiftUI's type-checker doesn't choke
/// on `CreateTransactionModal.body` once you stack a confirmation dialog,
/// document scanner, photos picker, review sheet and progress overlay on
/// top of the existing sheet zoo.
private struct ReceiptScanFlowModifier: ViewModifier {
    @Binding var showSourceDialog: Bool
    @Binding var showDocumentScanner: Bool
    @Binding var showPhotosPicker: Bool
    @Binding var photosPickerItem: PhotosPickerItem?
    @Binding var reviewPayload: ReceiptReviewPayload?
    @Binding var receiptParseError: String?
    @Binding var showReceiptParseError: Bool
    @Binding var isParsingReceipt: Bool

    let onScannedImage: (UIImage) -> Void
    let onReviewConfirm: ([ReceiptItem], Double, String?) -> Void
    let onReviewCancel: () -> Void

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                "Scan a receipt",
                isPresented: $showSourceDialog,
                titleVisibility: .hidden
            ) {
                Button {
                    showDocumentScanner = true
                } label: {
                    Label("Take photo", systemImage: "camera")
                }
                Button {
                    showPhotosPicker = true
                } label: {
                    Label("Choose from library", systemImage: "photo.on.rectangle")
                }
                Button("Cancel", role: .cancel) {}
            }
            .fullScreenCover(isPresented: $showDocumentScanner) {
                DocumentScannerView(
                    onScan: { image in
                        showDocumentScanner = false
                        onScannedImage(image)
                    },
                    onCancel: { showDocumentScanner = false },
                    onError: { error in
                        showDocumentScanner = false
                        receiptParseError = error.localizedDescription
                        showReceiptParseError = true
                    }
                )
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photosPickerItem,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: photosPickerItem) { newItem in
                guard let newItem else { return }
                Task {
                    if let data = try? await newItem.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        onScannedImage(image)
                    }
                    photosPickerItem = nil
                }
            }
            .sheet(item: $reviewPayload) { payload in
                ReceiptReviewView(
                    parseResult: payload.result,
                    sourceImage: payload.image,
                    onConfirm: { items, total in
                        onReviewConfirm(items, total, payload.result.parsedReceipt.currency)
                    },
                    onCancel: onReviewCancel
                )
            }
            .alert(
                "Couldn't read receipt",
                isPresented: $showReceiptParseError,
                presenting: receiptParseError
            ) { _ in
                Button("OK", role: .cancel) {
                    receiptParseError = nil
                }
            } message: { message in
                Text(message)
            }
            .overlay {
                if isParsingReceipt {
                    receiptParsingOverlay
                }
            }
    }

    private var receiptParsingOverlay: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 14) {
                ProgressView()
                    .controlSize(.large)
                Text("Reading receipt…")
                    .font(.subheadline.weight(.medium))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 22)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .fill(.ultraThinMaterial)
            )
        }
    }
}

// MARK: - Модальное окно создания и редактирования
struct CreateTransactionModal: View {
    @Binding var isPresented: Bool
    var editingTransaction: Transaction? = nil // Поддержка режима редактирования
    /// Optional starting tab for create mode (ignored when editing). Lets
    /// empty-state CTAs land directly in `.split` instead of forcing the
    /// user to flip the segmented control after the modal opens.
    var initialTab: TransactionTab? = nil
    /// Friend IDs to pre-select as split participants when `initialTab`
    /// is `.split`. Used by the friend-screen CTA so "you + this friend"
    /// is wired up before the modal renders.
    var prefilledFriendIDs: [String] = []

    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    @StateObject private var vm = CreateTransactionViewModel()

    @State private var showNoteTagsModal: Bool = false
    @State private var showCategoryModal: Bool = false
    @State private var showDateModal: Bool = false
    @State private var showFriendPicker: Bool = false
    @State private var showSplitModePicker: Bool = false
    @State private var showFriendForm: Bool = false
    @State private var showWhoPaid: Bool = false
    // @State private var showWhoPays: Bool = false  // WhoPaysPicker — preserved for future
    @State private var selectedTab: TransactionTab = .expense
    @State private var youIncludedInSplit: Bool = true  // whether "You" is selected as split participant
    @State private var amountShakeOffset: CGFloat = 0
    @State private var payerConflict: Bool = false
    @State private var payerConflictHapticFired: Bool = false
    @State private var subtitleShakeOffset: CGFloat = 0
    @State private var skipNextAmountConflictCheck: Bool = false
    /// Pending replacement Transaction when editing a recurring parent — drives
    /// the "Replace reminder?" confirmation alert.
    @State private var pendingRecurringReplacement: Transaction? = nil
    @State private var showRecurringReplaceAlert: Bool = false

    // MARK: - Receipt Scan Flow
    //
    // The scan-receipt feature is **temporarily hidden** from the UI while
    // we re-evaluate the parsing approach. State and helpers below stay so
    // the wiring can be re-enabled by flipping `scanFeatureEnabled` to true.
    private static let scanFeatureEnabled = false
    @State private var showReceiptSourceDialog: Bool = false
    @State private var showDocumentScanner: Bool = false
    @State private var photosPickerItem: PhotosPickerItem? = nil
    @State private var showPhotosPicker: Bool = false
    @State private var pickedReceiptImage: UIImage? = nil
    @State private var isParsingReceipt: Bool = false
    @State private var parsedReceiptResult: HybridReceiptParser.Result? = nil
    @State private var receiptParseError: String? = nil
    @State private var showReceiptParseError: Bool = false
    /// Identifiable wrapper used to drive the review sheet (sheet(item:)
    /// requires Identifiable).
    @State private var reviewPayload: ReceiptReviewPayload? = nil

    private let hybridParser = HybridReceiptParser()

    /// Shake the payer subtitle and fire a warning haptic (used when save is blocked by payer conflict).
    private func shakeSubtitleWithHaptic() {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.warning)
        withAnimation(.default) {
            subtitleShakeOffset = 10
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) {
                subtitleShakeOffset = 0
            }
        }
    }

    /// Attempts to save.
    private func trySave() {
        guard vm.isAmountValid else { return }

        // If split has only "You" and no outside payers — no real split, save as regular expense
        let hasNonMePayer = vm.payers.contains { $0.id != "me" }
        if vm.isSplitMode && vm.selectedFriends.isEmpty && youIncludedInSplit && !hasNonMePayer {
            vm.isSplitMode = false
            vm.payers = []
            commitTransaction()
            return
        }

        // Update single-payer amount to current total before saving
        if vm.isSplitMode && vm.payers.count == 1 {
            vm.payers[0].amount = vm.parsedAmount
        }
        commitTransaction()
    }

    private func commitTransaction() {
        // When editing a recurring parent, show a confirmation first — we
        // replace the parent instead of updating it so past auto-created
        // children stay while the new schedule starts from now.
        //
        // We carry the existing `syncID` forward (`syncID: existing.syncID`)
        // so any open sheets bound to the OLD transaction can resolve
        // to the new replacement on lookup — without this the split-
        // breakdown card stacked over the reminder renders empty after
        // the user confirms Replace, because both `id` and `syncID` would
        // rotate at once.
        if let existing = editingTransaction, existing.isRecurringParent {
            guard let replacement = vm.buildTransaction(
                editingId: nil,
                syncID: existing.syncID
            ) else { return }
            pendingRecurringReplacement = replacement
            showRecurringReplaceAlert = true
            return
        }

        guard let tx = vm.buildTransaction(editingId: editingTransaction?.id) else { return }
        let pendingItems = vm.pendingReceiptItems

        if editingTransaction != nil {
            transactionStore.update(tx)
            // For an in-place edit we already know the row id, so save items
            // immediately if a fresh scan happened during this edit.
            if !pendingItems.isEmpty {
                Task {
                    await receiptItemStore.saveItems(pendingItems, for: tx.id)
                }
            }
            isPresented = false
            return
        }

        if pendingItems.isEmpty {
            // Fast path — no scan, keep the original fire-and-forget add to
            // preserve existing behavior on devices without camera/AI.
            transactionStore.add(tx)
            isPresented = false
            return
        }

        // New transaction WITH a receipt scan: we need the autoincrement ID
        // before we can link the items. Run async, dismiss after both rows
        // are written so the create modal doesn't close before the data
        // settles.
        Task {
            if let newID = await transactionStore.addAndReturnID(tx) {
                await receiptItemStore.saveItems(pendingItems, for: newID)
            }
            await MainActor.run { isPresented = false }
        }
    }

    private func confirmRecurringReplacement() {
        guard let replacement = pendingRecurringReplacement,
              let existing = editingTransaction else { return }
        transactionStore.delete(id: existing.id)
        transactionStore.add(replacement)
        pendingRecurringReplacement = nil
        showRecurringReplaceAlert = false
        isPresented = false
    }

    // MARK: - Receipt Scan Flow Handlers

    /// Kicks off OCR + LLM parsing for a captured/picked image. On success
    /// presents the review sheet; on failure shows an alert.
    private func handleScannedImage(_ image: UIImage) {
        pickedReceiptImage = image
        isParsingReceipt = true
        Task {
            do {
                let result = try await hybridParser.parse(image: image)
                await MainActor.run {
                    isParsingReceipt = false
                    if result.parsedReceipt.items.isEmpty {
                        receiptParseError = "No items detected. Try a clearer photo or enter the amount manually."
                        showReceiptParseError = true
                        pickedReceiptImage = nil
                    } else {
                        reviewPayload = ReceiptReviewPayload(result: result, image: image)
                    }
                }
            } catch {
                await MainActor.run {
                    isParsingReceipt = false
                    receiptParseError = error.localizedDescription
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                }
            }
        }
    }

    /// Toolbar action button: confirm (checkmark) when an amount has been
    /// entered, otherwise the scan-receipt entry point. Pulled out of the
    /// toolbar block because the type-checker can't handle the inline
    /// conditional when it's mixed with the rest of `body`.
    ///
    /// The scan-receipt branch (shown when amount = 0) is currently hidden
    /// behind `Self.scanFeatureEnabled`. We always render the confirm
    /// button — disabled until the amount is valid — until the receipt
    /// scanning feature is re-enabled.
    @ViewBuilder
    private var primaryToolbarAction: some View {
        if Self.scanFeatureEnabled, vm.parsedAmount == 0 {
            Button(action: { showReceiptSourceDialog = true }) {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "doc.viewfinder")
                        .font(AppFonts.bodySmallEmphasized)
                    Text("Scan")
                        .font(.subheadline.weight(.semibold))
                }
            }
        } else {
            Button(action: {
                if payerConflict {
                    shakeSubtitleWithHaptic()
                } else if vm.isAmountValid {
                    let generator = UINotificationFeedbackGenerator()
                    generator.notificationOccurred(.success)
                    trySave()
                }
            }) {
                Image(systemName: "checkmark")
                    .font(AppFonts.bodyEmphasized)
            }
            .disabled(!vm.isAmountValid && !payerConflict)
        }
    }


    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColors.backgroundPrimary.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    Spacer().frame(height: 60)

                    // Title area — tappable, opens Notes screen
                    Button(action: { showNoteTagsModal = true }) {
                        let trimmedTitle = vm.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        let fallbackTitle = "My \(vm.selectedCategory?.title ?? (vm.isIncome ? "Income" : "Expense"))"
                        let hasExtra = !vm.note.isEmpty

                        if trimmedTitle.isEmpty {
                            // Empty state: fallback + pencil
                            HStack(spacing: AppSpacing.sm) {
                                Text(fallbackTitle)
                                    .font(AppFonts.displayLarge)
                                    .foregroundColor(AppColors.textDisabled)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                Image(systemName: "pencil")
                                    .font(.system(size: 30, weight: .medium))
                                    .foregroundColor(AppColors.textDisabled)
                            }
                            .padding(.horizontal, AppSpacing.xl)
                        } else {
                            // Has title
                            VStack(spacing: AppSpacing.xs) {
                                Text(trimmedTitle)
                                    .font(.system(size: vm.titleDisplayFontSize, weight: .bold))
                                    .foregroundColor(AppColors.textPrimary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal, AppSpacing.xl)
                                if hasExtra {
                                    // Match the placeholder zero's
                                    // `textQuaternary` tone so the
                                    // caption sits as a quiet hint
                                    // below the title rather than a
                                    // secondary call-to-action.
                                    Text("View all notes")
                                        .font(AppFonts.labelCaption)
                                        .foregroundColor(AppColors.textQuaternary)
                                }
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .frame(height: 90)
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    
                    Spacer().frame(height: 16)

                    // Блок суммы с кнопкой стирания — fixed height to prevent layout jumps
                    ZStack {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                            let parts = vm.formattedAmountGrouped.split(separator: ".", omittingEmptySubsequences: false)
                            Text(String(parts.first ?? "0"))
                                .font(.system(size: vm.amountFontSize, weight: .bold))
                                .foregroundColor(vm.amount.isEmpty ? AppColors.textQuaternary : AppColors.textPrimary)
                                // Faint placeholder zero — `textQuaternary`
                                // alone reads as filled-in on the warm
                                // cream background; halving alpha pushes
                                // it into clear "placeholder" territory
                                // without losing the warm hue.
                                .opacity(vm.amount.isEmpty ? 0.5 : 1)
                            if parts.count > 1 {
                                Text("." + (parts.count > 1 ? String(parts[1]) : "00"))
                                    .font(.system(size: vm.amountFontSize * 0.5, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary)
                            }
                            // Sets the transaction draft's currency
                            // (NOT the global base). When user opens
                            // "More currencies" from the dropdown,
                            // `CurrencyRatesSheet` enters its
                            // callback-driven mode via the shared
                            // `onSelect` so the chosen code commits
                            // here too — without that forwarding the
                            // sheet would silently change `selectedCurrency`
                            // on the store, which is the wrong target
                            // for this surface.
                            CurrencyDropdownButton(
                                selected: vm.selectedCurrency,
                                onSelect: { code in vm.selectedCurrency = code }
                            ) {
                                Text(vm.selectedCurrency)
                                    .font(.system(size: vm.amountFontSize * 0.5, weight: .semibold))
                                    .foregroundColor(AppColors.balanceCurrency)
                                    .padding(.leading, AppSpacing.xs)
                            }
                        }
                        .padding(.horizontal, 56)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                        .animation(.easeInOut(duration: 0.15), value: vm.amountFontSize)
                        
                        // Кнопка Backspace
                        HStack {
                            Spacer()
                            Button(action: { vm.handleBackspace() }) {
                                Image(systemName: "delete.left.fill")
                                    .font(.system(size: 28, weight: .regular))
                                    .foregroundColor(AppColors.textQuaternary)
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .padding(.trailing, 24)
                            .opacity(vm.amount.isEmpty ? 0 : 1)
                            .animation(.easeInOut(duration: 0.2), value: vm.amount.isEmpty)
                        }
                    }
                    .frame(height: 80)
                    .padding(.bottom, 0)
                    .offset(x: amountShakeOffset)

                    // Dynamic payer subtitle for split mode
                    if vm.isSplitMode && (!vm.selectedFriends.isEmpty || youIncludedInSplit) && !vm.payers.isEmpty {
                        // Payers are set — show dynamic subtitle
                        Button(action: {
                            if vm.parsedAmount < 0.01 {
                                // Shake the amount block + haptic
                                let generator = UINotificationFeedbackGenerator()
                                generator.notificationOccurred(.warning)
                                withAnimation(.default) {
                                    amountShakeOffset = 12
                                }
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                                    withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) {
                                        amountShakeOffset = 0
                                    }
                                }
                            } else {
                                showWhoPaid = true
                            }
                        }) {
                            HStack(spacing: AppSpacing.xxs) {
                                payerSubtitle
                                if vm.parsedAmount >= 0.01 {
                                    Image(systemName: "chevron.right")
                                        .font(AppFonts.iconSmall)
                                        .foregroundColor(payerConflict ? AppColors.warning : AppColors.textTertiary)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .offset(x: subtitleShakeOffset)
                        .padding(.bottom, AppSpacing.lg)
                    } else {
                        Spacer().frame(height: 4)
                    }

                    // Category button
                    HStack(spacing: AppSpacing.sm) {
                        Button(action: { showCategoryModal = true }) {
                            HStack(spacing: 6) {
                                Text(vm.selectedCategory?.emoji ?? "🍔")
                                Text(vm.selectedCategory?.title ?? "Food")
                            }
                            .font(.system(size: 20, weight: .medium))
                            .foregroundColor(AppColors.textPrimary)
                            .padding(.vertical, AppSpacing.sm)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .background(AppColors.backgroundElevated)
                            .cornerRadius(AppRadius.fab)
                        }
                    }
                    .padding(.bottom, AppSpacing.sm)

                    Spacer(minLength: 0)

                    // Date row — directly above keyboard
                    HStack(spacing: AppSpacing.md) {
                        Button(action: { showDateModal = true }) {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar")
                                    .font(AppFonts.labelPrimary)
                                Text(dateButtonText)
                                    .font(AppFonts.labelPrimary)
                                if let interval = vm.repeatInterval {
                                    HStack(spacing: 3) {
                                        Image(systemName: "repeat")
                                            .font(AppFonts.iconSmall)
                                        Text(interval.badgeLabel)
                                            .font(AppFonts.metaText)
                                    }
                                    .foregroundColor(AppColors.reminderAccent)
                                    .padding(.leading, 2)
                                }
                            }
                            .foregroundColor(AppColors.textPrimary)
                            .padding(.vertical, AppSpacing.sm)
                            .padding(.horizontal, 14)
                            .background(AppColors.backgroundElevated)
                            .cornerRadius(AppRadius.xlarge)
                        }

                        Spacer()
                    }
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.bottom, 10)

                    // Клавиатура (Numpad)
                    VStack(spacing: AppSpacing.md) {
                        ForEach([["1","2","3"],["4","5","6"],["7","8","9"],[".","0","✔︎"]], id: \.self) { row in
                            HStack(spacing: AppSpacing.md) {
                                ForEach(row, id: \.self) { key in
                                    Button(action: {
                                        if key == "✔︎" && payerConflict {
                                            shakeSubtitleWithHaptic()
                                        } else {
                                            vm.handleKeyPress(key, onSave: trySave)
                                        }
                                    }) {
                                        ZStack {
                                            RoundedRectangle(cornerRadius: AppRadius.medium)
                                                .fill(AppColors.backgroundElevated)
                                            if key == "✔︎" {
                                                Image(systemName: "checkmark")
                                                    .font(AppFonts.fabIcon)
                                                    .foregroundColor(vm.isAmountValid && !payerConflict ? AppColors.textPrimary : AppColors.textDisabled)
                                            } else {
                                                Text(key)
                                                    .font(.system(size: 28, weight: .medium))
                                                    .foregroundColor(AppColors.textPrimary)
                                            }
                                        }
                                        .frame(height: 56)
                                    }
                                    .disabled(key == "✔︎" && !vm.isAmountValid && !payerConflict)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, AppSpacing.md)
                }

                // Friends block — overlays on top of content, doesn't affect layout
                if vm.isSplitMode && (!vm.selectedFriends.isEmpty || youIncludedInSplit) {
                    VStack {
                        splitFriendsBlock
                        Spacer()
                    }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { isPresented = false }) {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItem(placement: .principal) {
                    Picker("Type", selection: $selectedTab.animation(.easeInOut(duration: 0.25))) {
                        Text("Expense").tag(TransactionTab.expense)
                        Text("Income").tag(TransactionTab.income)
                        Text("Split").tag(TransactionTab.split)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.mini)
                    .frame(width: 250)
                }
                ToolbarItem(placement: .confirmationAction) {
                    primaryToolbarAction
                }
            }
            .toolbarTitleDisplayMode(.inline)
            // Sheets
            .sheet(isPresented: $showNoteTagsModal) {
                NoteTagsModal(
                    isPresented: $showNoteTagsModal,
                    title: $vm.title,
                    note: $vm.note,
                    placeholderTitle: "My \(vm.selectedCategory?.title ?? (vm.isIncome ? "Income" : "Expense"))"
                )
            }
            .sheet(isPresented: $showCategoryModal) {
                CategoriesSheetView_Select(
                    isPresented: $showCategoryModal,
                    categoryStore: categoryStore,
                    onSelect: { cat in
                        vm.selectedCategory = cat
                        vm.userHasManuallySelectedCategory = true
                        showCategoryModal = false
                    }
                )
            }
            .sheet(isPresented: $showDateModal) {
                DatePickerModal(
                    isPresented: $showDateModal,
                    date: $vm.date,
                    repeatInterval: $vm.repeatInterval
                )
            }
            .sheet(isPresented: $showFriendPicker, onDismiss: {
                // If picker dismissed with no friends selected, ensure "You" is included
                if vm.selectedFriends.isEmpty {
                    youIncludedInSplit = true
                    vm.youIncludedInSplit = true
                    // Only set default payer if none configured yet
                    if vm.payers.isEmpty {
                        vm.setDefaultPayer()
                    }
                }
            }) {
                FriendPickerView(
                    initialSelection: vm.selectedFriends,
                    includeYou: true,
                    youSelected: youIncludedInSplit
                ) { friends, youSelected in
                    youIncludedInSplit = youSelected
                    vm.youIncludedInSplit = youSelected
                    vm.selectFriendsAndResolveSplitMode(friends)
                    // Only set default payer if no payers configured yet
                    if vm.payers.isEmpty {
                        vm.setDefaultPayer()
                    }
                }
                .environmentObject(friendStore)
            }
            .sheet(isPresented: $showFriendForm, onDismiss: {
                // If friend form dismissed with no friends selected, revert to expense
                if vm.selectedFriends.isEmpty {
                    selectedTab = .expense
                    vm.isSplitMode = false
                }
            }) {
                FriendFormView(existingGroups: friendStore.allGroups, isCompact: true) { newFriend in
                    Task {
                        await friendStore.add(newFriend)
                        vm.selectFriendsAndResolveSplitMode([newFriend])
                    }
                }
            }
            .sheet(isPresented: $showSplitModePicker) {
                SplitModePickerView(selectedMode: $vm.splitMode, friendCount: vm.selectedFriends.count, youIncluded: youIncludedInSplit, onSelect: {
                    vm.persistLastUsedSplitMode()
                })
            }
            // WhoPaysPicker — commented out, preserved for future
            // .sheet(isPresented: $showWhoPays) {
            //     WhoPaysPicker(
            //         friends: vm.selectedFriends,
            //         totalAmount: vm.formattedAmountGrouped,
            //         currency: vm.selectedCurrency
            //     ) { payerName in
            //         showWhoPays = false
            //         commitTransaction(payerName: payerName)
            //     }
            // }
            .sheet(isPresented: $showWhoPaid) {
                WhoPaidPickerView(
                    participants: whoPaidParticipants,
                    totalAmount: vm.parsedAmount,
                    currency: vm.selectedCurrency,
                    initialPayers: vm.payers,
                    onConfirm: { confirmedPayers in
                        vm.payers = confirmedPayers
                        payerConflict = false
                        payerConflictHapticFired = false
                    },
                    onConfirmWithNewTotal: { confirmedPayers, newTotal in
                        vm.payers = confirmedPayers
                        payerConflict = false
                        payerConflictHapticFired = false
                        // Skip the next onChange(amount) so it doesn't re-trigger conflict
                        skipNextAmountConflictCheck = true
                        // Update the amount to the new total (exceed scenario)
                        vm.amount = Self.formatAmountForInput(newTotal)
                    }
                )
                .environmentObject(friendStore)
            }
            // Tab switching logic
            .onChange(of: selectedTab) { newTab in
                switch newTab {
                case .expense:
                    vm.isIncome = false
                    vm.isSplitMode = false
                case .income:
                    vm.isIncome = true
                    vm.isSplitMode = false
                case .split:
                    vm.isIncome = false
                    vm.isSplitMode = true
                    // Auto-fill frequent friends or open the picker whenever
                    // no friends are selected — including when the user flips
                    // an existing expense into a split during edit. Splits
                    // with friends already populated don't re-open the picker
                    // because `selectedFriends.isEmpty` guards that.
                    if vm.selectedFriends.isEmpty {
                        if let frequentIDs = CreateTransactionViewModel.mostFrequentSplitFriendIDs(from: transactionStore.transactions) {
                            let resolved = frequentIDs.compactMap { id in friendStore.friend(byID: id) }
                            if !resolved.isEmpty && resolved.count == frequentIDs.count {
                                // All friends still exist — auto-fill
                                youIncludedInSplit = true
                                vm.youIncludedInSplit = true
                                vm.selectFriendsAndResolveSplitMode(resolved)
                                vm.setDefaultPayer()
                            } else {
                                // Some friends were deleted — open picker
                                showFriendPicker = true
                            }
                        } else {
                            // No past splits — open picker
                            showFriendPicker = true
                        }
                    }
                }
            }
            // Логика инициализации и переключения типа
            .onAppear {
                if let tx = editingTransaction {
                    vm.populate(
                        from: tx,
                        categories: categoryStore.categories,
                        friendResolver: { friendStore.friend(byID: $0) }
                    )
                    // Set the correct tab for the transaction type
                    if tx.splitInfo != nil {
                        selectedTab = .split
                        youIncludedInSplit = vm.youIncludedInSplit
                    } else if tx.isIncome {
                        selectedTab = .income
                    } else {
                        selectedTab = .expense
                    }
                } else {
                    vm.selectedCurrency = currencyStore.selectedCurrency
                    if vm.selectedCategory == nil {
                        vm.updateCategoryForCurrentType(
                            transactions: transactionStore.transactions,
                            categories: categoryStore.categories
                        )
                    }
                    // Apply CTA-driven prefill: pre-populate split participants
                    // BEFORE flipping `selectedTab` so the onChange handler's
                    // empty-friends auto-fill branch is skipped (otherwise it
                    // would either auto-pick frequent friends or open the
                    // picker, both of which fight the explicit prefill).
                    if let initialTab = initialTab {
                        if initialTab == .split && !prefilledFriendIDs.isEmpty {
                            let resolved = prefilledFriendIDs.compactMap {
                                friendStore.friend(byID: $0)
                            }
                            if !resolved.isEmpty {
                                youIncludedInSplit = true
                                vm.youIncludedInSplit = true
                                vm.selectFriendsAndResolveSplitMode(resolved)
                                vm.setDefaultPayer()
                            }
                        }
                        selectedTab = initialTab
                    }
                }
            }
            .alert("Replace reminder?", isPresented: $showRecurringReplaceAlert) {
                Button("Replace", role: .destructive) {
                    confirmRecurringReplacement()
                }
                Button("Cancel", role: .cancel) {
                    pendingRecurringReplacement = nil
                }
            } message: {
                Text("The current reminder will be deleted. Transactions already created from it will remain. A new reminder will start from now with your changes.")
            }
            .modifier(ReceiptScanFlowModifier(
                showSourceDialog: $showReceiptSourceDialog,
                showDocumentScanner: $showDocumentScanner,
                showPhotosPicker: $showPhotosPicker,
                photosPickerItem: $photosPickerItem,
                reviewPayload: $reviewPayload,
                receiptParseError: $receiptParseError,
                showReceiptParseError: $showReceiptParseError,
                isParsingReceipt: $isParsingReceipt,
                onScannedImage: handleScannedImage,
                onReviewConfirm: { items, total, currency in
                    vm.applyReceiptItems(items, total: total, currency: currency)
                    reviewPayload = nil
                    pickedReceiptImage = nil
                },
                onReviewCancel: {
                    reviewPayload = nil
                    pickedReceiptImage = nil
                }
            ))
            .onChange(of: vm.isIncome) { _ in
                // Only auto-select category if user hasn't manually picked one
                if editingTransaction == nil && !vm.userHasManuallySelectedCategory {
                    vm.updateCategoryForCurrentType(
                        transactions: transactionStore.transactions,
                        categories: categoryStore.categories
                    )
                }
            }
            .onChange(of: vm.amount) { _ in
                // When amount changes with multiple payers, flag conflict
                guard vm.isSplitMode && vm.payers.count > 1 else { return }
                if skipNextAmountConflictCheck {
                    skipNextAmountConflictCheck = false
                    return
                }
                // Check if the new amount matches payer sum — conflict resolved
                let payerSum = vm.payers.reduce(0) { $0 + $1.amount }
                if abs(vm.parsedAmount - payerSum) < 0.001 {
                    if payerConflict {
                        payerConflict = false
                        payerConflictHapticFired = false
                    }
                    return
                }
                if !payerConflict {
                    payerConflict = true
                    // One-time haptic on first change
                    if !payerConflictHapticFired {
                        payerConflictHapticFired = true
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.warning)
                    }
                    // Shake subtitle
                    withAnimation(.default) {
                        subtitleShakeOffset = 10
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                        withAnimation(.interpolatingSpring(stiffness: 600, damping: 12)) {
                            subtitleShakeOffset = 0
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Split Friends Block

extension CreateTransactionModal {
    private var splitModeLabel: String {
        guard let mode = vm.splitMode else { return "Evenly" }
        if mode == .fiftyFifty {
            return vm.selectedFriends.count == 1 ? "50/50" : "Evenly"
        }
        return mode.displayLabel
    }

    var splitFriendsBlock: some View {
        HStack(spacing: 6) {
            // Split mode icon + label — tappable to change mode
            Button(action: { showSplitModePicker = true }) {
                HStack(spacing: AppSpacing.xs) {
                    SplitModeIcon(mode: vm.splitMode ?? .fiftyFifty, size: 18)
                    Text(splitModeLabel)
                        .font(AppFonts.footnote)
                        .foregroundColor(AppColors.textPrimary)
                        .lineLimit(1)
                }
                .padding(.vertical, AppSpacing.xs)
                .padding(.horizontal, AppSpacing.sm)
                .background(AppColors.backgroundChip)
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

            Text("between")
                .font(AppFonts.metaText)
                .foregroundColor(AppColors.textSecondary)
                .lineLimit(1)

            // Participant chips — tappable to re-edit
            Button {
                showFriendPicker = true
            } label: {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AppSpacing.xs) {
                        // "You" chip — only if You is included
                        if youIncludedInSplit {
                            HStack(spacing: AppSpacing.xs) {
                                PixelCatView(id: UserIDService.currentID(), size: 16, blackAndWhite: false)
                                    .clipShape(Circle())
                                Text("You")
                                    .font(AppFonts.metaText)
                                    .foregroundColor(AppColors.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, AppSpacing.xs)
                            .padding(.leading, AppSpacing.xs)
                            .padding(.trailing, AppSpacing.sm)
                            .background(AppColors.backgroundChip)
                            .clipShape(Capsule())
                        }

                        ForEach(vm.selectedFriends) { friend in
                            HStack(spacing: AppSpacing.xs) {
                                // Colored when the friend is a real
                                // user (`isConnected == true`),
                                // grayscale for manually-typed
                                // contacts. Same rule everywhere we
                                // render an avatar.
                                PixelCatView(id: friend.id, size: 16, blackAndWhite: !friend.isConnected)
                                    .clipShape(Circle())
                                Text(friend.name)
                                    .font(AppFonts.metaText)
                                    .foregroundColor(AppColors.textPrimary)
                                    .lineLimit(1)
                            }
                            .padding(.vertical, AppSpacing.xs)
                            .padding(.leading, AppSpacing.xs)
                            .padding(.trailing, AppSpacing.sm)
                            .background(AppColors.backgroundChip)
                            .clipShape(Capsule())
                        }

                        // "+" chip — visible only when just "You" is selected
                        if vm.selectedFriends.isEmpty && youIncludedInSplit {
                            Image(systemName: "plus")
                                .font(AppFonts.captionSmallStrong)
                                .foregroundColor(AppColors.textTertiary)
                                .frame(width: 24, height: 24)
                                .background(AppColors.backgroundChip)
                                .clipShape(Circle())
                        }
                    }
                    .padding(.trailing, 20)
                }
                .mask(
                    HStack(spacing: 0) {
                        Color.black
                        LinearGradient(
                            colors: [.black, .clear],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        .frame(width: 24)
                    }
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, AppSpacing.xs)
        .padding(.trailing, AppSpacing.xs)
        .padding(.vertical, AppSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, AppSpacing.xs)
        .padding(.bottom, AppSpacing.xxs)
    }
}

// MARK: - Who Paid Participants

extension CreateTransactionModal {
    /// Build participant list for WhoPaidPickerView (always includes You + selected friends).
    /// Payers are independent of split participants — you can pay even if not splitting.
    var whoPaidParticipants: [WhoPaidParticipant] {
        var list: [WhoPaidParticipant] = [WhoPaidParticipant(id: "me", name: "You")]
        list += vm.selectedFriends.map { WhoPaidParticipant(id: $0.id, name: $0.name) }
        return list
    }
}

// MARK: - Payer Subtitle

extension CreateTransactionModal {
    private var subtitleSecondaryColor: Color {
        payerConflict ? AppColors.warning : AppColors.textSecondary
    }
    private var subtitlePrimaryColor: Color {
        payerConflict ? AppColors.warning : AppColors.textPrimary
    }

    @ViewBuilder
    var payerSubtitle: some View {
        let lent = vm.netLentAmount
        let absLent = abs(lent)
        let absFormatted = vm.netLentAmountFormatted
        let isZero = absLent < 0.01

        if vm.payers.count == 1 && vm.payers[0].id == "me" {
            HStack(spacing: AppSpacing.xs) {
                PixelCatView(id: UserIDService.currentID(), size: 18, blackAndWhite: false)
                    .clipShape(Circle())
                if isZero {
                    Text("You pay")
                        .font(AppFonts.captionEmphasized)
                        .foregroundColor(subtitleSecondaryColor)
                } else {
                    Text("You pay ")
                        .font(AppFonts.captionEmphasized)
                        .foregroundColor(subtitleSecondaryColor)
                    + Text("and \(lent < 0 ? "owe" : "lend") ")
                        .font(AppFonts.captionEmphasized)
                        .foregroundColor(subtitleSecondaryColor)
                    + Text("\(absFormatted) \(vm.selectedCurrency)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(subtitlePrimaryColor)
                }
            }
        } else if vm.payers.count == 1 {
            let payerId = vm.payers[0].id
            let payerName = vm.payers[0].name.count > 10 ? String(vm.payers[0].name.prefix(10)) + "…" : vm.payers[0].name
            // Look up the payer's connection status from FriendStore.
            // Falls back to grayscale (`true` → B&W) when the friend
            // record can't be found — defensive, shouldn't happen in
            // a valid split.
            let payerIsConnected = friendStore.friend(byID: payerId)?.isConnected ?? false
            HStack(spacing: AppSpacing.xs) {
                PixelCatView(id: payerId, size: 18, blackAndWhite: !payerIsConnected)
                    .clipShape(Circle())
                if isZero {
                    Text("\(payerName) pays")
                        .font(AppFonts.captionEmphasized)
                        .foregroundColor(subtitleSecondaryColor)
                } else {
                    Text("\(payerName) pays ")
                        .font(AppFonts.captionEmphasized)
                        .foregroundColor(subtitleSecondaryColor)
                    + Text("and you borrow ")
                        .font(AppFonts.captionEmphasized)
                        .foregroundColor(subtitleSecondaryColor)
                    + Text("\(absFormatted) \(vm.selectedCurrency)")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(subtitlePrimaryColor)
                }
            }
        } else {
            let isOwe = lent < 0
            if isZero {
                Text("\(vm.payers.count) people pay")
                    .font(AppFonts.captionEmphasized)
                    .foregroundColor(subtitleSecondaryColor)
            } else {
                Text("\(vm.payers.count) people pay ")
                    .font(AppFonts.captionEmphasized)
                    .foregroundColor(subtitleSecondaryColor)
                + Text("and you \(isOwe ? "owe" : "lend") ")
                    .font(AppFonts.captionEmphasized)
                    .foregroundColor(subtitleSecondaryColor)
                + Text("\(absFormatted) \(vm.selectedCurrency)")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(subtitlePrimaryColor)
            }
        }
    }
}

// MARK: - Amount Formatting Helpers

extension CreateTransactionModal {
    /// Convert a Double to the raw input string format used by vm.amount
    static func formatAmountForInput(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

// MARK: - Date Button Text

extension CreateTransactionModal {
    var dateButtonText: String {
        let calendar = Calendar.current
        let now = Date()
        let isToday = calendar.isDate(vm.date, inSameDayAs: now)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"
        if isToday {
            return "At " + timeFormatter.string(from: vm.date)
        } else {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "MMM d, yyyy"
            return dateFormatter.string(from: vm.date) + " at " + timeFormatter.string(from: vm.date)
        }
    }
}

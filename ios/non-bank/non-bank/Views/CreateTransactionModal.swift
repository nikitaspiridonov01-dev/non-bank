import SwiftUI
import PhotosUI
import UIKit

// MARK: - Transaction Tab
//
// Split is no longer a top-level tab — the orchestrator (Phase 4.4)
// handles the entire split flow via a chip + subtitle entry under
// expense/income. External callers that previously opened the modal
// pre-flipped to `.split` now pass `autoOpenSplitFlow: true` instead;
// the modal lands on `.expense` and presents the orchestrator on top.

enum TransactionTab: Int, CaseIterable {
    case expense, income
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
    @Binding var showCamera: Bool
    @Binding var showPhotosPicker: Bool
    @Binding var photosPickerItems: [PhotosPickerItem]
    @Binding var reviewPayload: ReceiptReviewPayload?
    @Binding var receiptParseError: String?
    @Binding var showReceiptParseError: Bool
    @Binding var isParsingReceipt: Bool

    let onScannedImage: (UIImage) -> Void
    /// Gallery callback. Always called with at least one image, max 3.
    /// Single-image picks are forwarded to `onScannedImage` for source
    /// parity with the camera path.
    let onScannedImages: ([UIImage]) -> Void
    let onReviewConfirm: ([ReceiptItem], Double, String?, String?) -> Void
    let onReviewCancel: () -> Void
    /// Fires whenever the scan flow ends in cancel before review
    /// confirm: source dialog Cancel, scanner Cancel, scanner error,
    /// or photos picker dismissed without picking an image. Used by
    /// the parent to release any state that was waiting on a
    /// successful review (e.g. the `byItems`-after-scan latch).
    var onScanCancelled: () -> Void = {}

    func body(content: Content) -> some View {
        content
            // Replaces the legacy `.confirmationDialog` system alert
            // with a full-screen styled picker matching the rest of
            // the transaction flow (see `ReceiptSourcePickerView`).
            // Used only by the toolbar scan button (amount = 0) —
            // the byItems-without-receipt path inside the
            // orchestrator now runs the same picker as a push step
            // in its own NavigationStack and never reaches here.
            .sheet(isPresented: $showSourceDialog) {
                ReceiptSourcePickerView(
                    wrapInNavigationStack: true,
                    onPickCamera: {
                        showSourceDialog = false
                        // Guard the simulator / no-camera-device case —
                        // `UIImagePickerController` crashes if presented
                        // with `sourceType = .camera` on a device that
                        // doesn't have one. The receipt flow falls back
                        // to the source picker's other option (Photos)
                        // implicitly: the picker has already dismissed,
                        // so the user re-taps the scan button and picks
                        // Library instead.
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            showCamera = true
                        } else {
                            onScanCancelled()
                        }
                    },
                    onPickLibrary: {
                        showSourceDialog = false
                        showPhotosPicker = true
                    },
                    onCancel: { onScanCancelled() }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .fullScreenCover(isPresented: $showCamera) {
                PlainCameraView(
                    onScan: { image in
                        showCamera = false
                        onScannedImage(image)
                    },
                    onCancel: {
                        showCamera = false
                        onScanCancelled()
                    },
                    onError: { error in
                        showCamera = false
                        receiptParseError = error.localizedDescription
                        showReceiptParseError = true
                        onScanCancelled()
                    }
                )
                .ignoresSafeArea()
            }
            .photosPicker(
                isPresented: $showPhotosPicker,
                selection: $photosPickerItems,
                maxSelectionCount: CreateTransactionModal.maxReceiptPhotos,
                selectionBehavior: .ordered,
                matching: .images,
                photoLibrary: .shared()
            )
            .onChange(of: photosPickerItems) { newItems in
                guard !newItems.isEmpty else { return }
                Task {
                    // Load each picked asset in order. Bad/unreadable
                    // items are silently dropped — partial success is
                    // better than failing the whole batch.
                    var images: [UIImage] = []
                    for item in newItems {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            images.append(image)
                        }
                    }
                    photosPickerItems = []
                    guard !images.isEmpty else {
                        onScanCancelled()
                        return
                    }
                    if images.count == 1 {
                        // Source-parity with the camera path so the
                        // existing single-image pipeline (and its
                        // metrics / state handling) stays untouched.
                        onScannedImage(images[0])
                    } else {
                        onScannedImages(images)
                    }
                }
            }
            // Detect "picker dismissed without selection" — selection
            // sets `photosPickerItems` to non-empty before
            // `showPhotosPicker` flips to false, so checking the array
            // state at dismiss time distinguishes cancel from select.
            .onChange(of: showPhotosPicker) { presenting in
                if !presenting && photosPickerItems.isEmpty {
                    onScanCancelled()
                }
            }
            .sheet(item: $reviewPayload) { payload in
                ReceiptReviewView(
                    parseResult: payload.result,
                    sourceImage: payload.image,
                    onConfirm: { items, total, currency in
                        // Use the currency the review screen surfaced
                        // (which the editor's picker may have corrected)
                        // rather than the raw parser output — otherwise
                        // a user fix to a wrong AI guess silently rolls
                        // back here.
                        onReviewConfirm(
                            items,
                            total,
                            currency,
                            payload.result.parsedReceipt.suggestedCategory
                        )
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
                    // Parser errors fire from the parent's
                    // `handleScannedImage` (post-OCR), which can't
                    // reach `onScanCancelled` directly — clear here
                    // so the parse-failure path is also treated as a
                    // cancel. Scanner-side errors already cleared the
                    // latch in `onError` above; the duplicate clear
                    // is a no-op.
                    onScanCancelled()
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
            // Opaque backdrop — fully blocks the modal underneath so the
            // scan flow reads as a discrete "doing magic" beat, not a
            // semi-transparent inconvenience.
            AppColors.backgroundPrimary.ignoresSafeArea()
            VStack(spacing: AppSpacing.xl) {
                ReceiptScanLoader()
                Text("Reading receipt…")
                    .font(AppFonts.body.weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                Text("Hang on a second")
                    .font(.subheadline)
                    .foregroundColor(AppColors.textTertiary)
            }
        }
    }
}

// MARK: - Модальное окно создания и редактирования
struct CreateTransactionModal: View {

    /// Format a numeric amount for `CreateTransactionViewModel.amount`
    /// (which holds the user's keypad input as a string). Trims the
    /// `.00` tail so a clean integer like `15` displays as `15` rather
    /// than `15.00`, but keeps two decimals for everything else so the
    /// keypad shows the same precision the debt summary displayed.
    static func formatPrefillAmount(_ amount: Double) -> String {
        let rounded = (amount * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }

    /// Canonical SwiftUI dismiss handle. Replaces the legacy
    /// `@Binding var isPresented` parameter: setting an external
    /// binding to `false` while the modal's containing `NavigationStack`
    /// is mid-render produced a brief blank/gray sheet because the
    /// dismiss animation raced with the synchronous store mutation
    /// that precedes it. `dismiss()` is queued through SwiftUI's own
    /// dismissal coordinator and stays in sync with the sheet's
    /// transition, regardless of whether the parent used
    /// `.sheet(isPresented:)` or `.sheet(item:)`.
    @Environment(\.dismiss) private var dismiss

    var editingTransaction: Transaction? = nil // Поддержка режима редактирования
    /// Optional starting tab for create mode (ignored when editing). Lets
    /// empty-state CTAs land directly in `.split` instead of forcing the
    /// user to flip the segmented control after the modal opens.
    /// Optional tab override for the create flow. Pass `.expense` or
    /// `.income` to land on something other than the default expense.
    /// `.split` was removed in Phase 4.3 — external callers wanting to
    /// open in split mode now pass `autoOpenSplitFlow: true` instead,
    /// which lands on `.expense` and presents the orchestrator.
    var initialTab: TransactionTab? = nil
    /// When true, the modal auto-presents the split-mode orchestrator
    /// once it appears. Used by friend-scoped CTAs ("Add split with
    /// Michael") to skip the chip / subtitle tap. Combined with
    /// `prefilledFriendIDs` so the participants are already populated.
    var autoOpenSplitFlow: Bool = false
    /// When true, the modal pops the receipt-source picker (Camera /
    /// Photo Library) right after appearing. Used by the Home and
    /// Debts toolbar scan buttons so the user lands one tap away
    /// from capture.
    var autoOpenScanFlow: Bool = false
    /// When true, the modal pre-arms `byItems` split mode: any
    /// `prefilledFriendIDs` (plus the user) are selected as
    /// participants and `splitMode` is set to `.byItems`. After the
    /// receipt scan finishes the user lands directly on the item-
    /// assignment step. Used by the Debts and Friend scan buttons.
    var autoSplitByItems: Bool = false
    /// Friend IDs to pre-select as split participants. Used by the
    /// friend-screen CTA so "you + this friend"
    /// is wired up before the modal renders.
    var prefilledFriendIDs: [String] = []
    /// Receipt images the user already picked/captured before the modal
    /// opened (Home gallery-first scan). When non-empty, the modal skips
    /// the source picker and parses them immediately on appear — the
    /// "Reading receipt…" overlay covers the form so it never flashes.
    var pendingScanImages: [UIImage] = []
    /// Pre-configure the modal as a settle-up transaction (one payer
    /// fully covers the other side's share). Used by the Friend
    /// detail's "Settle up" CTA so the user lands on a transaction
    /// that already balances the existing debt — they just confirm
    /// and save. Amount + currency + payer side + category come from
    /// this struct.
    var settleUpPrefill: SettleUpPrefill? = nil

    /// Description of a debt to settle. The CTA caller computes this
    /// from `SplitDebtService.simplifiedDebts(...)` and passes it in.
    /// `Identifiable` so callers can drive `sheet(item:)` directly.
    struct SettleUpPrefill: Equatable, Identifiable {
        let friendID: String
        let amount: Double
        let currency: String
        let direction: Direction
        // Identity key includes amount + direction so an updated
        // prefill (e.g. the user came back, more debt accrued, tapped
        // the button again) re-presents the sheet instead of dedup'ing
        // against the prior identical id.
        var id: String { "\(friendID)|\(direction)|\(amount)" }

        enum Direction: Equatable {
            /// I owe the friend money — this transaction has *me* paying.
            case iPayFriend
            /// The friend owes me money — this transaction has *them* paying.
            case friendPaysMe
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.analytics) private var analytics
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    /// Used to raise the post-save share prompt for newly-created
    /// split transactions. Injected by the parent (always available
    /// from the app root).
    @EnvironmentObject var router: NavigationRouter

    @StateObject private var vm = CreateTransactionViewModel()

    @State private var showNoteTagsModal: Bool = false
    @State private var showCategoryModal: Bool = false
    @State private var showDateModal: Bool = false
    @State private var showFriendPicker: Bool = false
    /// Phase 4.4 orchestrator presentation handle. Using `.sheet(item:)`
    /// rather than `.sheet(isPresented:)` so every open gets a fresh
    /// `id` — SwiftUI was preserving `TransactionModeFlowSheet.@State`
    /// across presentations on the isPresented path, which meant
    /// `_path = State(initialValue:)` was being ignored on second-and-
    /// later opens and the user kept landing on the mode picker even
    /// when re-entering with a mode already configured. The `startStep`
    /// disambiguates fresh-start (state 2 chip tap, "Pay for yourself"
    /// users picking a mode) from re-entry (state 3/4 chip/subtitle
    /// tap with a mode already configured — orchestrator opens at the
    /// "specific step" for that mode).
    @State private var modeFlowPresentation: ModeFlowPresentation? = nil

    /// Identifiable wrapper so `.sheet(item:)` creates a fresh view
    /// identity per open. The UUID's only job is forcing identity to
    /// change — it doesn't carry any meaning.
    struct ModeFlowPresentation: Identifiable {
        let id = UUID()
        let startStep: TransactionModeFlowSheet.StartStep
    }

    /// While the orchestrator sheet is open, the chip + subtitle render
    /// off this snapshot instead of the live VM. The orchestrator
    /// writes `vm.splitMode` / `vm.selectedFriends` / `vm.payers` /
    /// `vm.youIncludedInSplit` directly during its steps so its own
    /// downstream routing (the friend picker, calc, etc.) can read them
    /// — those writes propagate up to this modal via `@ObservedObject`,
    /// which without this freeze caused a visible flash: the chip and
    /// subtitle would flip to the in-flight mode while the sheet was
    /// up, then revert when `.onDisappear` rolled back. Freezing the
    /// display source keeps the modal showing the pre-open state for
    /// the entire sheet lifetime; we clear it from `.sheet(onDismiss:)`
    /// AFTER the sheet animation completes so any committed state
    /// surfaces cleanly without a mid-animation snap.
    @State private var chipDisplaySnapshot: ChipDisplaySnapshot? = nil

    struct ChipDisplaySnapshot {
        let splitMode: SplitMode?
        let isSplitMode: Bool
        let selectedFriends: [Friend]
        let youIncludedInSplit: Bool
        let payers: [Payer]
    }
    @State private var showFriendForm: Bool = false
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
    private static let scanFeatureEnabled = true
    @State private var showReceiptSourceDialog: Bool = false
    @State private var showCamera: Bool = false
    // Multi-image gallery picker: the user can grab up to 3 photos of
    // a single receipt at once (e.g. the back of a long restaurant
    // tape that didn't fit in one shot). One pick = original behaviour;
    // multi-pick fans out through `handleScannedImages` which merges
    // the per-image parse results into a single review payload.
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var showPhotosPicker: Bool = false
    @State private var pickedReceiptImage: UIImage? = nil
    @State private var isParsingReceipt: Bool = false
    @State private var parsedReceiptResult: HybridReceiptParser.Result? = nil
    @State private var receiptParseError: String? = nil
    @State private var showReceiptParseError: Bool = false
    /// Hard cap on how many gallery photos can be merged into one
    /// receipt scan. 3 is enough to cover most long-tape restaurant
    /// receipts without blowing past sensible token usage on the
    /// upstream AI provider.
    static let maxReceiptPhotos = 3
    /// Identifiable wrapper used to drive the review sheet (sheet(item:)
    /// requires Identifiable).
    @State private var reviewPayload: ReceiptReviewPayload? = nil
    /// One-shot guard so the gallery-first pending-scan parse fires at
    /// most once even if `onAppear` runs again.
    @State private var didStartPendingScan: Bool = false

    // (Items pill no longer opens the editor directly. It now drives the
    // same `reviewPayload` flow as a fresh scan, so the user always lands
    // on the read-only review sheet first and can drill into the editor
    // from there. The previous `showItemsEditor` state was removed.)

    /// True when the transaction's amount is locked to the sum of scanned/
    /// edited receipt items. In this state the numpad is replaced by a
    /// blurred overlay routing the user to the items editor — typing a
    /// digit would silently break the items↔total invariant.
    private var isReceiptLocked: Bool {
        !vm.pendingReceiptItems.isEmpty
    }

    /// The "target total" the items editor measures against. Starts as
    /// the parser-detected receipt total after a scan; gets overwritten
    /// every time the editor commits — so once the user accepts a
    /// divergent total via "Save total as X", subsequent re-opens of the
    /// editor treat X as the new authoritative target instead of nagging
    /// about the original receipt.
    @State private var acceptedReceiptTotal: Double? = nil

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
            guard var replacement = vm.buildTransaction(
                editingId: nil,
                syncID: existing.syncID
            ) else { return }
            // Same preservation rule as below — the recurring-replace
            // path also rebuilds the transaction from scratch and
            // must carry the existing exclude flag forward.
            if existing.excludedFromInsights {
                replacement = replacement.settingExcludedFromInsights(true)
            }
            pendingRecurringReplacement = replacement
            showRecurringReplaceAlert = true
            return
        }

        guard var tx = vm.buildTransaction(editingId: editingTransaction?.id) else { return }
        // Editing an existing transaction must preserve the user's
        // include/exclude-from-insights choice — the build step starts
        // from `vm` state, which doesn't carry that flag, so the row
        // would otherwise quietly flip back to "counted" on every edit.
        if let existing = editingTransaction, existing.excludedFromInsights {
            tx = tx.settingExcludedFromInsights(true)
        }
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
            trackTransactionSaved(tx, isEdit: true)
            dismiss()
            return
        }

        if pendingItems.isEmpty {
            // Fast path — no scan, keep the original fire-and-forget add to
            // preserve existing behavior on devices without camera/AI.
            transactionStore.add(tx)
            trackTransactionSaved(tx, isEdit: false)
            dismiss()
            promptShareIfSplit(tx)
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
            await MainActor.run {
                trackTransactionSaved(tx, isEdit: false)
                dismiss()
                promptShareIfSplit(tx)
            }
        }
    }

    /// Fire `transaction_created` (or `transaction_edited`) with all
    /// the per-event params derived from the just-committed tx. Also
    /// records first-use + activation milestones so a single helper
    /// covers every save path. Called from `commitTransaction` after
    /// the store write but before dismiss; safe to call multiple
    /// times within one commit because the activation/feature gates
    /// are idempotent (UserDefaults-backed).
    private func trackTransactionSaved(_ tx: Transaction, isEdit: Bool) {
        if isEdit {
            // Field-level diffing would need the original tx; we
            // don't track which specific field changed in this pass.
            // `.other` keeps the funnel intact until a richer diff
            // lands.
            analytics.track(.transactionEdited(fieldChanged: .other))
            return
        }

        let source: TransactionCreationSource = {
            if settleUpPrefill != nil { return .settleUp }
            if !vm.pendingReceiptItems.isEmpty || autoOpenScanFlow { return .scan }
            return .manual
        }()

        // For scan-derived creates: was the final category the
        // parser's suggestion? `parsedReceiptResult` carries the
        // last successful parse for this modal mount, including the
        // suggestedCategory. `nil` on non-scan creates.
        let categoryAutoMatched: Bool? = {
            guard source == .scan,
                  let suggested = parsedReceiptResult?.parsedReceipt.suggestedCategory else {
                return nil
            }
            return tx.category.compare(suggested, options: .caseInsensitive) == .orderedSame
        }()

        analytics.track(.transactionCreated(
            type: tx.isIncome ? .income : .expense,
            hasSplit: tx.isSplit,
            hasReceiptItems: !vm.pendingReceiptItems.isEmpty,
            isRecurring: tx.repeatInterval != nil,
            currency: tx.currency,
            amountBucket: AnalyticsBuckets.amount(tx.amount),
            category: tx.category,
            source: source,
            hasDescription: !(tx.description?.isEmpty ?? true),
            wasCategoryAutoMatched: categoryAutoMatched
        ))

        // Feature-first-use + activation milestones — both helpers
        // gate on UserDefaults so calling on every save is fine.
        analytics.recordActivationFirstTransactionIfNeeded()
        if source == .manual {
            analytics.recordFeatureUseIfFirst(.transactionCreateManual)
        }
        if tx.isSplit {
            analytics.recordFeatureUseIfFirst(.split)
            analytics.recordActivationFirstSplitIfNeeded()
        }
        if tx.repeatInterval != nil {
            analytics.recordFeatureUseIfFirst(.recurring)
        }
    }

    /// Post-create hook: if the saved transaction is a split, raise
    /// the share-prompt overlay so the user gets a nudge to send the
    /// link before they forget. The receiver opens the same modal we
    /// already use on the transaction-detail share path.
    private func promptShareIfSplit(_ tx: Transaction) {
        guard tx.isSplit else { return }
        // Defer a beat so the create-modal dismissal animation finishes
        // before the share prompt presents on top of MainTabView. iOS
        // drops the second sheet otherwise.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            router.promptSplitShare(syncID: tx.syncID)
        }
    }

    private func confirmRecurringReplacement() {
        guard let replacement = pendingRecurringReplacement,
              let existing = editingTransaction else { return }
        transactionStore.delete(id: existing.id)
        transactionStore.add(replacement)
        // Replace-reminder is a recurring-edit special case: the user
        // intentionally rotates the row. Track as an edit so reminder
        // churn doesn't inflate the "creates" funnel.
        trackTransactionSaved(replacement, isEdit: true)
        pendingRecurringReplacement = nil
        showRecurringReplaceAlert = false
        dismiss()
    }

    // MARK: - Receipt Scan Flow Handlers

    /// Kicks off OCR + LLM parsing for a captured/picked image. On success
    /// presents the review sheet; on failure shows an alert.
    /// Holds the parse-result branch back until at least
    /// `Self.minimumLoaderSeconds` have elapsed since the loader appeared.
    /// Cloud round-trips can be sub-second on cached prompts; without this
    /// gate the pixel-art loader would flash for ~300ms and read as a bug
    /// rather than a deliberate "scanning" beat.
    private static let minimumLoaderSeconds: Double = 5.0

    /// Shared so the orchestrator's byItems-without-receipt scan flow
    /// (which runs parsing inside its own NavigationStack) can use
    /// the same min-loader-time floor as the toolbar scan path —
    /// keeps "Reading receipt…" from blinking past too fast and
    /// reading as a stutter instead of a deliberate beat.
    static func enforceMinimumLoaderTime(startedAt: Date) async {
        let elapsed = Date().timeIntervalSince(startedAt)
        let remaining = minimumLoaderSeconds - elapsed
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    /// Sits on top of the (already-blurred) numpad when receipt items
    /// drive the amount. Just a subtle backplate for legibility +
    /// centred copy — the blur effect itself lives on the numpad
    /// (`.blur(radius:)` modifier), so this overlay never expands the
    /// host's frame. Tap routed via `.onTapGesture` (not `Button`) so
    /// iOS doesn't apply the press-fade animation that would briefly
    /// thin the layer and flash the numpad on touch.
    private var receiptLockedNumpadOverlay: some View {
        let count = vm.pendingReceiptItems.count
        let itemsWord = count == 1 ? "item" : "items"
        // Per-theme tint, both routed through the page colour for a
        // unified look:
        //   • Dark mode: 0.8α — backgroundPrimary is near-black, so this
        //     reads as a darker recess against the surrounding modal.
        //   • Light mode: 0.45α — backgroundPrimary is cream, washing
        //     the blurred (slightly-darker) numpad keys back toward the
        //     page tone. A touch less cream coverage than 0.6 lets the
        //     beige keys show through more, so the locked area sits a
        //     hair lower visually instead of disappearing into the page.
        let tintFill: Color = colorScheme == .dark
            ? AppColors.backgroundPrimary.opacity(0.8)
            : AppColors.backgroundPrimary.opacity(0.45)
        return ZStack {
            RoundedRectangle(cornerRadius: AppRadius.fab)
                .fill(tintFill)

            VStack(spacing: AppSpacing.sm) {
                Text("The amount is calculated from the receipt (\(count) \(itemsWord)).")
                    .font(AppFonts.body.weight(.semibold))
                    .foregroundColor(AppColors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Tap to edit items")
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.accentColor)
            }
            .padding(.horizontal, AppSpacing.xxl)
        }
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.fab))
        .onTapGesture { openItemsReview() }
    }

    /// Re-open the post-scan review sheet from the inline "N items" pill,
    /// driving the same `reviewPayload` machinery the scan flow uses. We
    /// build a synthetic `HybridReceiptParser.Result` from current state so
    /// the review sheet renders the user's already-committed items + the
    /// last-known store name / date / source info. Confidence is forced
    /// to `.high` so the spurious "Quick scan" / "Totals don't match"
    /// banners don't fire on a re-open — those copy lines are scoped to
    /// the original parse, not subsequent edits.
    private func openItemsReview() {
        let parsed = ParsedReceipt(
            storeName: parsedReceiptResult?.parsedReceipt.storeName,
            date: parsedReceiptResult?.parsedReceipt.date,
            items: vm.pendingReceiptItems,
            totalAmount: acceptedReceiptTotal,
            currency: vm.selectedCurrency,
            suggestedCategory: parsedReceiptResult?.parsedReceipt.suggestedCategory
        )
        let result = HybridReceiptParser.Result(
            parsedReceipt: parsed,
            confidence: .high,
            totalsMatch: true,
            source: parsedReceiptResult?.source ?? .ocrFallback,
            // Synthetic Result construction (rebuilt from in-VM
            // items for a re-open) — preserve the original attempts
            // when we have a prior cloud parse, otherwise 1.
            attemptedProvidersCount: parsedReceiptResult?.attemptedProvidersCount ?? 1
        )
        reviewPayload = ReceiptReviewPayload(result: result, image: pickedReceiptImage)
    }

    private func handleScannedImage(_ image: UIImage) {
        pickedReceiptImage = image
        isParsingReceipt = true
        // Analytics: scan_started fires up front so we can compute
        // started-vs-succeeded conversion funnels. `source` is unknown
        // here (camera vs library is upstream); assume `.camera` —
        // the user just took or picked a photo and we can't tell
        // which path without plumbing it through.
        analytics.track(.receiptScanStarted(source: .camera, numPhotos: 1))
        analytics.recordFeatureUseIfFirst(.receiptScan)
        // Build the cloud config on the main actor *before* hopping into the
        // task — `categoryStore` and `AISettings` are main-actor-bound, and
        // the resulting `Sendable` value is then safe to capture by the actor.
        let cloudConfig = HybridReceiptParser.CloudParseConfig.current(
            categoryStore: categoryStore
        )
        let scanStartedAt = Date()
        Task {
            do {
                let result = try await hybridParser.parse(
                    image: image,
                    cloudConfig: cloudConfig
                )
                await Self.enforceMinimumLoaderTime(startedAt: scanStartedAt)
                // Image bytes computed off the main thread so the
                // size-bucket reflects what the cloud actually
                // uploaded. ~0.9 quality matches `CloudReceiptParser
                // .prepareImage` first-pass.
                let imageBytes = image.jpegData(compressionQuality: 0.9)?.count ?? 0
                let durationSec = Date().timeIntervalSince(scanStartedAt)
                await MainActor.run {
                    isParsingReceipt = false
                    if result.parsedReceipt.items.isEmpty {
                        analytics.track(.receiptScanFailed(errorType: result.emptyScanErrorType, source: .camera))
                        analytics.recordActivationFirstReceiptScannedIfNeeded(outcome: .fail)
                        receiptParseError = "No items detected. Try a clearer photo or enter the amount manually."
                        showReceiptParseError = true
                        pickedReceiptImage = nil
                    } else {
                        analytics.trackReceiptScanSucceeded(result, imageBytes: imageBytes, durationSeconds: durationSec)
                        analytics.recordActivationFirstReceiptScannedIfNeeded(outcome: .success)
                        parsedReceiptResult = result
                        acceptedReceiptTotal = result.parsedReceipt.totalAmount
                        reviewPayload = ReceiptReviewPayload(result: result, image: image)
                    }
                }
            } catch {
                await Self.enforceMinimumLoaderTime(startedAt: scanStartedAt)
                await MainActor.run {
                    isParsingReceipt = false
                    // Bucket the error by class — network vs timeout
                    // vs parse-error need different fixes.
                    let kind: ScanErrorType = {
                        let desc = error.localizedDescription.lowercased()
                        if desc.contains("timed out") || desc.contains("timeout") { return .timeout }
                        if desc.contains("network") || desc.contains("connection") || desc.contains("offline") { return .network }
                        return .parseError
                    }()
                    analytics.track(.receiptScanFailed(errorType: kind, source: .camera))
                    analytics.recordActivationFirstReceiptScannedIfNeeded(outcome: .fail)
                    receiptParseError = error.localizedDescription
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                }
            }
        }
    }

    /// Multi-image gallery scan. Each photo runs through the hybrid
    /// parser independently, then we stitch the per-image results into
    /// a single `ParsedReceipt`:
    ///   - items: concatenated in the order the user picked the photos
    ///   - totalAmount: sum of per-image totals (best the parser could
    ///     do for each strip); the review screen lets the user correct
    ///   - storeName / date / suggestedCategory: first non-nil wins
    ///   - confidence: lowest seen across the batch (a single low-conf
    ///     strip should drag the whole receipt down)
    ///   - source: cloud if any image went through cloud, OCR otherwise
    ///
    /// If every image fails we surface the error from the first one —
    /// partial success (e.g. 2 of 3 succeeded) still continues to the
    /// review screen with whatever items we did get.
    private func handleScannedImages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        pickedReceiptImage = images.first
        isParsingReceipt = true
        let cloudConfig = HybridReceiptParser.CloudParseConfig.current(
            categoryStore: categoryStore
        )
        let scanStartedAt = Date()
        Task {
            var perImageResults: [HybridReceiptParser.Result] = []
            var firstError: Error?
            for image in images {
                do {
                    let result = try await hybridParser.parse(
                        image: image,
                        cloudConfig: cloudConfig
                    )
                    perImageResults.append(result)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            await Self.enforceMinimumLoaderTime(startedAt: scanStartedAt)
            await MainActor.run {
                isParsingReceipt = false
                guard !perImageResults.isEmpty else {
                    receiptParseError = firstError?.localizedDescription
                        ?? "No items detected across the picked photos."
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                    return
                }
                let merged = Self.mergeScanResults(perImageResults)
                guard !merged.parsedReceipt.items.isEmpty else {
                    receiptParseError = "No items detected. Try clearer photos or enter the amount manually."
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                    return
                }
                parsedReceiptResult = merged
                acceptedReceiptTotal = merged.parsedReceipt.totalAmount
                // Show the first picked image in the review header —
                // it's the closest proxy we have to "this scan" when
                // the parse spanned multiple photos.
                reviewPayload = ReceiptReviewPayload(result: merged, image: images.first)
            }
        }
    }

    /// Stitch N per-photo parse results into one consolidated
    /// `HybridReceiptParser.Result`. Pulled out as a static so it
    /// stays unit-testable without instantiating the modal.
    static func mergeScanResults(_ results: [HybridReceiptParser.Result]) -> HybridReceiptParser.Result {
        precondition(!results.isEmpty, "Caller must pass at least one result")
        if results.count == 1 { return results[0] }

        let allItems = results.flatMap { $0.parsedReceipt.items }
        let totalSum = results.compactMap { $0.parsedReceipt.totalAmount }.reduce(0, +)
        let firstStoreName = results.compactMap { $0.parsedReceipt.storeName }.first
        let firstDate = results.compactMap { $0.parsedReceipt.date }.first
        let firstCurrency = results.compactMap { $0.parsedReceipt.currency }.first
        let firstCategory = results.compactMap { $0.parsedReceipt.suggestedCategory }.first
        let lowestConfidence = results.map { $0.confidence }.min(by: { confidenceRank($0) < confidenceRank($1) })
            ?? .low
        let anyCloud = results.contains { result in
            if case .cloud = result.source { return true }
            return false
        }
        let mergedSource: HybridReceiptParser.Source
        if anyCloud {
            // Pick the first cloud source so the review screen surfaces
            // a real provider string instead of an aggregated fake one.
            mergedSource = results.first(where: { result in
                if case .cloud = result.source { return true }
                return false
            })?.source ?? .ocrFallback
        } else {
            mergedSource = .ocrFallback
        }

        let parsed = ParsedReceipt(
            storeName: firstStoreName,
            date: firstDate,
            items: allItems,
            totalAmount: totalSum > 0 ? totalSum : nil,
            currency: firstCurrency,
            suggestedCategory: firstCategory
        )
        return HybridReceiptParser.Result(
            parsedReceipt: parsed,
            confidence: lowestConfidence,
            // Totals are heuristic on multi-image stitches; flag a
            // mismatch so the review screen tells the user to double
            // check rather than silently committing the sum.
            totalsMatch: false,
            source: mergedSource,
            // For multi-image stitches the attempts-count is the
            // worst across the batch — surfaces the messiest cloud
            // run rather than averaging it away.
            attemptedProvidersCount: results.map { $0.attemptedProvidersCount }.max() ?? 1
        )
    }

    /// Ranking helper for `Confidence` so the multi-image merger can
    /// pick the lowest value across a batch. Higher number = higher
    /// confidence — pure ordering, never persisted.
    static func confidenceRank(_ c: HybridReceiptParser.Confidence) -> Int {
        switch c {
        case .low:    return 0
        case .medium: return 1
        case .high:   return 2
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
            // Icon-only scan trigger. `viewfinder` (without the doc
            // inside) reads as the universal "scan / capture" glyph and
            // matches the weight of the cancel `xmark` on the other
            // side of the toolbar — keeps the bar visually balanced.
            Button(action: { showReceiptSourceDialog = true }) {
                Image(systemName: "viewfinder")
                    .font(AppFonts.bodyEmphasized)
            }
            .accessibilityLabel("Scan receipt")
        } else {
            Button(action: {
                if payerConflict || splitHasUnresolvedConflict {
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
            .disabled(!vm.isAmountValid && !payerConflict && !splitHasUnresolvedConflict)
        }
    }


    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                AppColors.backgroundPrimary.ignoresSafeArea()
                
                VStack(spacing: 0) {
                    // No explicit top Spacer here — the chip slot's
                    // invisible top hit padding (`chipHitPaddingVertical`)
                    // already provides the 8pt breathing room between
                    // the toolbar and the visible chip, while widening
                    // the tap target into that zone.
                    //
                    // Top mode-entry chip (Phase 4.4) — sits right
                    // under the toolbar tabs. Hidden in income mode
                    // (income transactions don't have split modes).
                    // The chip itself maintains a stable height across
                    // its three states so the title / amount below
                    // don't jump as the chip morphs.
                    if !vm.isIncome {
                        modeEntryChip
                            .frame(height: Self.chipReservedHeight)
                    } else {
                        // Reserve the same vertical slot so flipping
                        // expense → income doesn't ripple the layout
                        // (tab toggle reads as content swap, not a
                        // shift).
                        Spacer().frame(height: Self.chipReservedHeight)
                    }

                    // Reduced from 12pt — the chip slot's invisible
                    // bottom hit padding eats 8pt, so 4pt here brings
                    // the visible gap above the title back to the
                    // original ~12pt rhythm.
                    Spacer().frame(height: 4)

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
                                    // Use `textDisabled` to match the
                                    // notes-editor "Write a note…"
                                    // placeholder. `textQuaternary`
                                    // (the previous tone) maps to
                                    // `UIColor.quaternaryLabel` in
                                    // dark mode, which renders much
                                    // fainter than `placeholderText`
                                    // — the two empty hints ended up
                                    // visibly mismatched on dark
                                    // even though they read the same
                                    // on light. Sharing one token
                                    // gives parity in both themes.
                                    Text("View all notes")
                                        .font(AppFonts.labelCaption)
                                        .foregroundColor(AppColors.textDisabled)
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
                                // Empty state shares the **same**
                                // `textDisabled` warm light grey as the
                                // title-field placeholder ("My Food")
                                // and the notes "Write a note…"
                                // placeholder so all three empty
                                // affordances on the create screen
                                // read as one unified "tap to fill"
                                // rhythm instead of three subtly
                                // different greys.
                                .foregroundColor(vm.amount.isEmpty ? AppColors.textDisabled : AppColors.textPrimary)
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
                        // Long-press the amount → native iOS context menu
                        // with Paste / Copy / Clear. The numpad isn't a
                        // TextField, so without this affordance there's
                        // no way to drop a number in from the clipboard
                        // — and copy-pasting from a bank statement /
                        // chat is the single most common ask. The
                        // `contentShape` makes the whole horizontal
                        // stripe a hit-target instead of just the
                        // digit glyphs. The menu is suppressed while
                        // a receipt scan owns the amount (`isReceiptLocked`)
                        // because mutating the displayed total would
                        // silently break the items↔total invariant
                        // that locks the keypad in the first place.
                        .contentShape(Rectangle())
                        .contextMenu {
                            if !isReceiptLocked {
                                Button {
                                    if let pasted = UIPasteboard.general.string {
                                        vm.pasteAmount(pasted)
                                    }
                                } label: {
                                    Label("Paste", systemImage: "doc.on.clipboard")
                                }
                                if !vm.amount.isEmpty {
                                    Button {
                                        UIPasteboard.general.string =
                                            "\(vm.amount) \(vm.selectedCurrency)"
                                    } label: {
                                        Label("Copy", systemImage: "doc.on.doc")
                                    }
                                    Button(role: .destructive) {
                                        vm.clearAmount()
                                    } label: {
                                        Label("Clear", systemImage: "xmark.circle")
                                    }
                                }
                            }
                        }

                        // Кнопка Backspace — also hidden while the amount
                        // is driven by scanned receipt items, since the
                        // user can't edit the digits anyway.
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
                            .opacity((vm.amount.isEmpty || isReceiptLocked) ? 0 : 1)
                            .disabled(isReceiptLocked)
                            .animation(.easeInOut(duration: 0.2), value: vm.amount.isEmpty)
                            .animation(.easeInOut(duration: 0.2), value: isReceiptLocked)
                        }
                    }
                    .frame(height: 80)
                    .padding(.bottom, 0)
                    .offset(x: amountShakeOffset)

                    // Mode subtitle (Phase 4.4) — replaces the old
                    // payerSubtitle. Visible when a mode is set; tap
                    // opens the orchestrator at the relevant step
                    // (same target as the top chip).
                    modeSubtitle

                    // Category button — items pill removed when receipt
                    // is locked because the numpad overlay (below) already
                    // surfaces "N items / tap to edit", and duplicating it
                    // up here adds visual noise without new info.
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
                        if !isReceiptLocked {
                            ItemsBadgePill(
                                count: vm.pendingReceiptItems.count,
                                style: .categoryMatched,
                                action: { openItemsReview() }
                            )
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

                    // Клавиатура (Numpad) + receipt-locked overlay
                    //
                    // The numpad is always laid out (so the modal's vertical
                    // rhythm doesn't jump when items appear/disappear), and
                    // when locked we drop a frosted card on top via
                    // `.overlay { ... }`. That modifier sizes the overlay
                    // to the numpad's exact frame — without it, a sibling
                    // ZStack child would size to its own intrinsic content
                    // and could grow taller than the numpad. Material
                    // needs visible content behind it to blur, so the
                    // numpad stays drawn (just non-interactive) underneath.
                    VStack(spacing: AppSpacing.md) {
                        ForEach([["1","2","3"],["4","5","6"],["7","8","9"],[".","0","✔︎"]], id: \.self) { row in
                            HStack(spacing: AppSpacing.md) {
                                ForEach(row, id: \.self) { key in
                                    Button(action: {
                                        if key == "✔︎" && (payerConflict || splitHasUnresolvedConflict) {
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
                                                    .foregroundColor(vm.isAmountValid && !payerConflict && !splitHasUnresolvedConflict ? AppColors.textPrimary : AppColors.textDisabled)
                                            } else {
                                                Text(key)
                                                    .font(.system(size: 28, weight: .medium))
                                                    .foregroundColor(AppColors.textPrimary)
                                            }
                                        }
                                        .frame(height: 56)
                                    }
                                    .disabled(
                                        (key == "✔︎" && !vm.isAmountValid && !payerConflict && !splitHasUnresolvedConflict)
                                        // Block all keys except the
                                        // confirm checkmark while the
                                        // amount is locked to receipt
                                        // items — the user has to go
                                        // through the editor to change
                                        // any digit.
                                        || (isReceiptLocked && key != "✔︎")
                                    )
                                }
                            }
                        }
                    }
                    // `.fixedSize(vertical: true)` pins the VStack to its
                    // intrinsic height (4 × 56 + 3 × 12 = 260pt) so the
                    // overlay never tugs the layout taller. `.blur(...)`
                    // applied directly on the numpad gives a controlled,
                    // tunable softness without Material's tendency to
                    // grow with the host. 8pt radius lands in the sweet
                    // spot — clearly defocused but the digit silhouettes
                    // still suggest "there's a numpad behind".
                    //
                    // `clipShape(RoundedRectangle…)` is critical when the
                    // numpad is blurred: `.blur` lets the rendered pixels
                    // bleed outward by ~radius points, producing halos
                    // around the bounding rect. We clip with the same
                    // rounded-corner shape the overlay uses so the blurred
                    // content lines up exactly with the rounded card —
                    // a plain `.clipped()` would leave visible rectangular
                    // corners poking out of the rounded overlay.
                    .fixedSize(horizontal: false, vertical: true)
                    .blur(radius: isReceiptLocked ? 8 : 0)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.fab))
                    .allowsHitTesting(!isReceiptLocked)
                    .overlay {
                        if isReceiptLocked {
                            receiptLockedNumpadOverlay
                        }
                    }
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, AppSpacing.md)
                }

                // Friends block previously rendered here as an overlay
                // (`splitFriendsBlock`) — replaced by `modeEntryChip`
                // up above, in the body's main VStack flow rather than
                // an overlay. Removed in Phase 4.4 layout reshuffle.
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                    }
                    .accessibilityLabel("Close")
                }
                // Hide the type segmented picker + the right-hand
                // confirm button while the parsing loader is up — both
                // are interactive controls that don't apply during the
                // "reading receipt…" beat. Only the cancel `xmark`
                // stays so the user always has a visible escape hatch
                // even if the parse hangs.
                if !isParsingReceipt {
                    ToolbarItem(placement: .principal) {
                        Picker("Type", selection: $selectedTab.animation(.easeInOut(duration: 0.25))) {
                            Text("Expense").tag(TransactionTab.expense)
                            Text("Income").tag(TransactionTab.income)
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.mini)
                        .frame(width: 250)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        primaryToolbarAction
                    }
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
            .sheet(
                item: $modeFlowPresentation,
                // Clear the chip's display freeze AFTER the dismissal
                // animation completes (that's when `onDismiss` fires
                // on `.sheet(item:)`). Clearing earlier would let the
                // chip snap from the frozen state to the live VM
                // mid-animation; deferring it means the new committed
                // state surfaces in a single clean transition once
                // the sheet is fully off-screen. For the back-out
                // case the orchestrator's own snapshot-restore has
                // already reverted the VM, so unfreezing reveals
                // the original state with no visible change.
                onDismiss: { chipDisplaySnapshot = nil }
            ) { presentation in
                TransactionModeFlowSheet(
                    vm: vm,
                    startStep: presentation.startStep,
                    currency: vm.selectedCurrency,
                    onDone: { /* chunk 4 will hook chip refresh here */ }
                )
                .environmentObject(friendStore)
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
            }
            // The legacy `showWhoPaid` standalone sheet was removed in
            // Phase 4.3 cleanup — who-paid is now a step inside the
            // orchestrator (`TransactionModeFlowSheet.whoPayStep`),
            // with the exceed-confirm "bump the total" plumbing wired
            // through `whoPayMultiCalcStep.onConfirmWithNewTotal`.
            // Tab switching logic. Split is no longer a tab — the
            // expense/income flip just toggles `isIncome` and clears
            // any in-progress split state. Existing split transactions
            // opened in income mode are an edge case (income + split is
            // unusual but legal); flipping back from edit drops the
            // split data on save, mirroring the old `.split` → other
            // tab transition.
            .onChange(of: selectedTab) { newTab in
                switch newTab {
                case .expense:
                    vm.isIncome = false
                case .income:
                    vm.isIncome = true
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
                    // Hydrate any previously-saved receipt items so the pill
                    // appears + the editor pre-populates. Synchronous read
                    // off the in-memory `ReceiptItemStore` cache, no async
                    // hop needed.
                    let existingItems = receiptItemStore.items(forTransactionID: tx.id)
                    if !existingItems.isEmpty {
                        vm.pendingReceiptItems = existingItems
                        // Editing an existing transaction — there's no
                        // "original receipt total" to compare against, so
                        // start the editor at the items sum (i.e. balanced).
                        // Any divergence the user introduces by editing
                        // shows up as "over by" / "X left" against the
                        // committed total they're working from.
                        acceptedReceiptTotal = existingItems.reduce(0) { $0 + $1.lineTotal }
                    }
                    // Pick tab from the underlying expense/income flag.
                    // Split-ness is no longer a tab — it's reflected in
                    // the orchestrator chip/subtitle once the modal is
                    // up. `youIncludedInSplit` still hydrates so the
                    // chip shows the right participant set.
                    if tx.splitInfo != nil {
                        youIncludedInSplit = vm.youIncludedInSplit
                    }
                    selectedTab = tx.isIncome ? .income : .expense
                } else {
                    vm.selectedCurrency = currencyStore.selectedCurrency
                    if vm.selectedCategory == nil {
                        vm.updateCategoryForCurrentType(
                            transactions: transactionStore.transactions,
                            categories: categoryStore.categories
                        )
                    }
                    // CTA-driven prefill: pre-populate the split
                    // participants (and flip the modal into split
                    // mode) when `autoOpenSplitFlow` is set. The
                    // orchestrator additionally auto-presents on top
                    // so the user lands directly inside the flow at
                    // the picker — friend prefill already populated,
                    // they just have to confirm or tweak.
                    if autoOpenSplitFlow {
                        if !prefilledFriendIDs.isEmpty {
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
                        // Defer the auto-open until after the modal's
                        // own appear animation settles — iOS drops
                        // the second sheet otherwise.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            presentModeFlow(startStep: .modePicker)
                        }
                    }
                    // Auto-arm `byItems` split mode for the Debts /
                    // Friend scan CTAs. Friend prefill (when present)
                    // populates participants up front; an empty
                    // prefill (Debts toolbar scan) just sets the mode,
                    // user picks participants after the scan.
                    if autoSplitByItems {
                        if !prefilledFriendIDs.isEmpty {
                            let resolved = prefilledFriendIDs.compactMap {
                                friendStore.friend(byID: $0)
                            }
                            if !resolved.isEmpty {
                                youIncludedInSplit = true
                                vm.youIncludedInSplit = true
                                vm.selectedFriends = resolved
                                vm.isSplitMode = true
                                vm.setDefaultPayer()
                            }
                        }
                        vm.splitMode = .byItems
                    }
                    // Gallery-first scan (Home icon): the images were
                    // already picked/captured before the modal opened, so
                    // skip the source picker entirely. Raise the parsing
                    // overlay immediately (the empty form never flashes)
                    // and run the existing parse pipeline straight away.
                    if !pendingScanImages.isEmpty {
                        if !didStartPendingScan {
                            didStartPendingScan = true
                            isParsingReceipt = true
                            let images = pendingScanImages
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if images.count == 1 {
                                    handleScannedImage(images[0])
                                } else {
                                    handleScannedImages(images)
                                }
                            }
                        }
                    }
                    // Auto-open the receipt source picker. Used by the
                    // Debts / Friend scan CTAs (which open the modal first,
                    // then scan). Same 0.5 s defer as `autoOpenSplitFlow`
                    // so the modal's present animation finishes before the
                    // picker stacks on top — iOS drops it otherwise.
                    else if autoOpenScanFlow {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            showReceiptSourceDialog = true
                        }
                    }
                    // Settle-up prefill: jam every field the user would
                    // normally set by hand — amount, currency, category,
                    // who paid — straight onto the VM so the modal opens
                    // on a transaction that already zeros out the
                    // existing debt. The user only has to tap Save.
                    if let prefill = settleUpPrefill,
                       let friend = friendStore.friend(byID: prefill.friendID) {
                        selectedTab = .expense
                        vm.selectedCurrency = prefill.currency
                        vm.amount = Self.formatPrefillAmount(prefill.amount)
                        youIncludedInSplit = true
                        vm.youIncludedInSplit = true
                        vm.selectFriendsAndResolveSplitMode([friend])
                        vm.splitMode = .settleUp
                        // "General" is reserved and always present —
                        // safe to look up by title without a fallback.
                        if let general = categoryStore.findCategory(byTitle: CategoryStore.uncategorized.title) {
                            vm.selectedCategory = general
                        }
                        // Single payer covers the entire amount; the
                        // other side is owed 100 %. Direction picks
                        // which of {me, friend} is the payer.
                        switch prefill.direction {
                        case .iPayFriend:
                            vm.payers = [Payer(id: "me", name: "You", amount: prefill.amount)]
                        case .friendPaysMe:
                            vm.payers = [Payer(id: friend.id, name: friend.name, amount: prefill.amount)]
                        }
                    }
                    if let initialTab = initialTab {
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
                showCamera: $showCamera,
                showPhotosPicker: $showPhotosPicker,
                photosPickerItems: $photosPickerItems,
                reviewPayload: $reviewPayload,
                receiptParseError: $receiptParseError,
                showReceiptParseError: $showReceiptParseError,
                isParsingReceipt: $isParsingReceipt,
                onScannedImage: handleScannedImage,
                onScannedImages: handleScannedImages,
                onReviewConfirm: { items, total, currency, suggestedCategory in
                    // Detect whether the items array actually changed
                    // before we apply — count + per-line sum picks up
                    // adds / deletes / value edits without false
                    // positives from re-opens that didn't touch the
                    // list. Used below to decide whether to auto-chain
                    // into the calculations step.
                    let oldItemsCount = vm.pendingReceiptItems.count
                    let oldItemsSum = vm.pendingReceiptItems.reduce(0.0) { $0 + $1.lineTotal }
                    let newItemsSum = items.reduce(0.0) { $0 + $1.lineTotal }
                    let itemsActuallyChanged = oldItemsCount != items.count
                        || abs(oldItemsSum - newItemsSum) > 0.001

                    // Analytics: per-field edit breakdown against the
                    // ORIGINAL parser output (not the latest committed
                    // state), so re-opens that don't actually touch
                    // anything report zero edits. Matching by index
                    // is approximate — adds/deletes shift positions —
                    // but it's the cheapest defensible heuristic for
                    // "did the user have to correct text vs digits."
                    if itemsActuallyChanged {
                        let original = parsedReceiptResult?.parsedReceipt.items ?? []
                        let added = max(0, items.count - original.count)
                        let deleted = max(0, original.count - items.count)
                        let pairs = zip(original, items)
                        let nameEdits = pairs.filter { $0.0.name != $0.1.name }.count
                        let priceEdits = pairs.filter { abs(($0.0.total ?? 0) - ($0.1.total ?? 0)) > 0.001 }.count
                        let quantityEdits = pairs.filter { ($0.0.quantity ?? 0) != ($0.1.quantity ?? 0) }.count
                        let totalChanged = abs((parsedReceiptResult?.parsedReceipt.totalAmount ?? newItemsSum) - total) > 0.001
                        analytics.track(.receiptItemsEditedInReview(
                            itemsAdded: added,
                            itemsDeleted: deleted,
                            nameEdits: nameEdits,
                            priceEdits: priceEdits,
                            quantityEdits: quantityEdits,
                            totalChanged: totalChanged
                        ))
                    }

                    vm.applyReceiptItems(
                        items,
                        total: total,
                        currency: currency,
                        suggestedCategory: suggestedCategory,
                        // Receipt-scan suggestion is matched against
                        // the reserved set only — that's the stable
                        // baseline (General + 18 defaults) every user
                        // has on first launch. Cuts down on false
                        // positives where the LLM lands on a niche
                        // user-created category by coincidence; the
                        // user's own "most frequent" logic continues
                        // to drive the manual-flow default elsewhere.
                        availableCategories: categoryStore.reservedCategories
                    )
                    // Auto-fill the transaction title with the parsed
                    // store name on first review-commit — but only when
                    // the user hasn't typed anything in the title yet,
                    // so re-scans can't overwrite a manual edit.
                    let currentTitle = vm.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    if currentTitle.isEmpty,
                       let storeName = parsedReceiptResult?.parsedReceipt.storeName?
                            .trimmingCharacters(in: .whitespacesAndNewlines),
                       !storeName.isEmpty {
                        vm.title = storeName
                    }
                    // Persist the new authoritative target so re-opens
                    // of the editor stop nagging about a stale receipt
                    // total the user already overrode.
                    acceptedReceiptTotal = total
                    reviewPayload = nil
                    pickedReceiptImage = nil

                    // Phase 4.6 auto-chain: items mutating under a
                    // share-derived mode invalidates the calc — push
                    // the orchestrator at the appropriate "specific
                    // step" so the user re-balances right away
                    // instead of finding out at save time. Skipped
                    // for evenly (calc is mechanical) and settle-up
                    // (100/0 is fixed by the mode itself).
                    let modeNeedsRebalance = vm.splitMode == .byAmount
                        || vm.splitMode == .byItems
                    if itemsActuallyChanged && modeNeedsRebalance {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            openModeFlow()
                        }
                    }
                },
                onReviewCancel: {
                    reviewPayload = nil
                    pickedReceiptImage = nil
                },
                onScanCancelled: {}
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
        .trackScreen(editingTransaction == nil ? "CreateTransactionModal" : "EditTransactionModal")
    }
}


// MARK: - Mode entry chip + subtitle (Phase 4.4)

extension CreateTransactionModal {

    // MARK: - Display-source accessors
    //
    // Every chip/subtitle helper below reads through these instead of
    // touching `vm.*` directly. While the orchestrator sheet is open,
    // `chipDisplaySnapshot` holds the pre-open VM state and the chip
    // shows that frozen value — so the orchestrator's in-flight writes
    // to the VM (which it needs for its own routing) don't leak into
    // the modal's chip / subtitle and produce the flash the user
    // reported. Once the sheet finishes dismissing,
    // `.sheet(onDismiss:)` clears the snapshot and these fall back to
    // the live VM, which by then holds either the committed new state
    // or the rolled-back original.
    private var displaySplitMode: SplitMode? {
        chipDisplaySnapshot?.splitMode ?? vm.splitMode
    }
    private var displayIsSplitMode: Bool {
        chipDisplaySnapshot?.isSplitMode ?? vm.isSplitMode
    }
    private var displaySelectedFriends: [Friend] {
        chipDisplaySnapshot?.selectedFriends ?? vm.selectedFriends
    }
    private var displayYouIncludedInSplit: Bool {
        chipDisplaySnapshot?.youIncludedInSplit ?? vm.youIncludedInSplit
    }
    private var displayPayers: [Payer] {
        chipDisplaySnapshot?.payers ?? vm.payers
    }

    /// True once the user committed to a non-default mode (any split
    /// or settle-up). Drives both the top chip's "active" appearance
    /// and the subtitle's visibility — when false, only the empty
    /// "Add friends to this purchase" affordance is shown.
    private var modeIsConfigured: Bool {
        displayIsSplitMode && (displayYouIncludedInSplit || !displaySelectedFriends.isEmpty)
    }

    /// True when the modal has a non-zero amount AND mode is set.
    /// State 3/4 from the prototype — drives the orange-warning
    /// rendering when the amount is later cleared.
    private var amountReadyForSplit: Bool {
        vm.parsedAmount > 0.001
    }

    /// byItems with a populated receipt but no per-participant
    /// assignments yet — either the user just edited the items
    /// (which strips `assignedParticipantIDs` via the editor) and
    /// abandoned the re-walk, or they never finished the initial
    /// assignment flow. In both cases the subtitle's "split the
    /// receipt between N people" claim is misleading until the walk
    /// is completed, so the caption renders orange the same way
    /// amount=0-with-mode-set does.
    private var byItemsNeedsAssignments: Bool {
        modeIsConfigured
            && vm.splitMode == .byItems
            && !vm.pendingReceiptItems.isEmpty
            && !vm.byItemsHasAssignments
    }

    /// byAmount with shares entered upstream but no longer summing
    /// to `parsedAmount` (most common cause: user edited the amount
    /// on the keypad after entering shares — leaving them stale —
    /// or an exceed-confirm in the multi-payer numpad bumped the
    /// total without the shares being re-balanced). Treated as an
    /// unresolved conflict the same way `byItemsNeedsAssignments` is:
    /// orange caption + save shake until the user re-walks the share
    /// picker.
    private var byAmountSharesStale: Bool {
        modeIsConfigured
            && vm.splitMode == .byAmount
            && !vm.byAmountShares.isEmpty
            && !vm.byAmountSharesBalanced
    }

    /// Multi-payer split where the per-payer amounts no longer sum
    /// to `parsedAmount`. Independent of split mode — fires whenever
    /// the user has more than one payer configured and their sum
    /// drifted (manual amount edit, or evenly/byItems mode where
    /// payers were committed against an older total). Mirrors the
    /// `payerConflict` @State guard, but as a current-state computed
    /// check so it stays accurate even when the conflict was reached
    /// without crossing the `.onChange(of: vm.amount)` observer
    /// (e.g., payers changed without an amount edit).
    private var payerSumMismatch: Bool {
        guard modeIsConfigured else { return false }
        guard vm.payers.count > 1 else { return false }
        let sum = vm.payers.reduce(0) { $0 + $1.amount }
        return abs(sum - vm.parsedAmount) > 0.001
    }

    /// Union of all "split is currently unresolved" predicates —
    /// used by both the orange-caption rendering and the save
    /// blockers. Centralised so the chip, the subtitle, the toolbar
    /// confirm, and the keypad ✔︎ stay in lockstep.
    private var splitHasUnresolvedConflict: Bool {
        byItemsNeedsAssignments || byAmountSharesStale || payerSumMismatch
    }

    /// The orchestrator entry point: opens at the mode picker for
    /// fresh starts, jumps to the "specific step" for re-entries when
    /// a mode is already configured. State 2 (no mode set yet) → mode
    /// picker so the user makes their first choice.
    ///
    /// The byItems-but-items-vanished re-entry case (user nuked items
    /// via the badge after configuring the mode) is handled inside
    /// the orchestrator: `seedPathForStartStep` lands on the
    /// `.scanSource` step in that shape and the unified scan flow
    /// rebuilds the items list without bailing back out to the modal.
    func openModeFlow() {
        presentModeFlow(
            startStep: modeIsConfigured ? .specificStep : .modePicker
        )
    }

    /// Single chokepoint for opening the orchestrator. Captures the
    /// chip+subtitle's display snapshot first so the underlying modal
    /// renders the pre-open state for the entire sheet lifetime,
    /// THEN flips `modeFlowPresentation` to present the sheet. Two
    /// entry points use this: the user-tap `openModeFlow()` and the
    /// auto-arm `asyncAfter` path that fires after a friend prefill.
    func presentModeFlow(startStep: TransactionModeFlowSheet.StartStep) {
        chipDisplaySnapshot = ChipDisplaySnapshot(
            splitMode: vm.splitMode,
            isSplitMode: vm.isSplitMode,
            selectedFriends: vm.selectedFriends,
            youIncludedInSplit: vm.youIncludedInSplit,
            payers: vm.payers
        )
        modeFlowPresentation = ModeFlowPresentation(startStep: startStep)
    }

    /// Top chip below the toolbar — single tap target for the entire
    /// mode flow, with a satellite close button when a mode is set.
    /// Two layout shapes:
    ///
    /// - **Default** (no split mode configured): 22pt circle showing
    ///   the user's own avatar — a one-tap hint that this chip is
    ///   "who's involved" rather than a generic split icon.
    /// - **Mode set**: pill containing the overlapping avatar stack of
    ///   every participant + payer. No text label, no close button —
    ///   the user enters/leaves split mode via the mode-picker, not
    ///   via a one-tap reset on the chip.
    ///
    /// Animations are spring-driven so the morph between circle and
    /// pill reads as a fluid expansion rather than a step change.
    var modeEntryChip: some View {
        let isOrange = modeIsConfigured && (!amountReadyForSplit || splitHasUnresolvedConflict)
        // The chip stays a circle until the user picks a real split
        // mode; once configured, it expands into a pill that hugs the
        // overlapping avatar stack on both sides.
        let isCircle = !modeIsConfigured
        // Tap-on-zero shake nudge stays — dim the circle so the
        // un-actionable state is visually obvious.
        let isUnactionable = !amountReadyForSplit && !modeIsConfigured

        return Button(action: {
            if !amountReadyForSplit {
                triggerAmountShake()
            } else {
                openModeFlow()
            }
        }) {
            chipContent(orange: isOrange)
                // Symmetric padding on both sides so the avatar pile
                // sits centred in the pill — matches the left/right
                // breathing room. Circle state ignores both via the
                // forced square frame. Slightly looser than xxs (2pt)
                // so a faint halo of the capsule is visible around
                // the avatars, reading as "these are inside a chip"
                // instead of "these are bare circles".
                .padding(.leading, isCircle ? 0 : Self.chipHorizontalPadding)
                .padding(.trailing, isCircle ? 0 : Self.chipHorizontalPadding)
                .frame(
                    width: isCircle ? Self.chipVisibleHeight : nil,
                    height: Self.chipVisibleHeight
                )
                .background(
                    Capsule().fill(
                        isOrange
                            ? AppColors.warning.opacity(0.15)
                            : AppColors.backgroundElevated
                    )
                )
                .opacity(isUnactionable ? 0.4 : 1)
                // Hit-area extension — invisible padding around the
                // visible chip makes the tap target larger than the
                // pill itself. The Button label's bounds grow with
                // this padding, so the parent VStack reserves
                // `chipReservedHeight` (= visible + 2 × vertical hit
                // padding) instead of the old 22pt. Surrounding
                // spacers were trimmed by the same delta so overall
                // vertical rhythm of the modal stays put.
                .padding(.vertical, Self.chipHitPaddingVertical)
                .padding(.horizontal, Self.chipHitPaddingHorizontal)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: amountReadyForSplit)
        .animation(.spring(response: 0.42, dampingFraction: 0.78), value: modeIsConfigured)
    }

    /// Visible height of the chip pill. Bumped from the original 22pt
    /// so a thin halo of the capsule fill shows above and below the
    /// 20pt avatars — readable as "the avatars are inside a chip".
    static let chipVisibleHeight: CGFloat = 26
    /// Horizontal padding inside the chip's capsule. With a 20pt
    /// avatar pile, 4pt on each side keeps the disc edges flush
    /// without bleeding into the pill rim.
    static let chipHorizontalPadding: CGFloat = 4
    /// Invisible padding added AROUND the visible chip to expand the
    /// tap target. Decoupled from `chipReservedHeight` (below) so the
    /// hit zone can be larger than the layout slot — the Button's
    /// content renders at `visible + 2 × hit-pad` and overflows the
    /// outer `.frame(height: chipReservedHeight)` by a few pt in each
    /// direction. SwiftUI hit-tests the rendered bounds, not the
    /// layout slot, so taps land on the overflow region too. The
    /// vertical overflow fills the 4pt gap before the title and the
    /// invisible margin above the toolbar — those zones are otherwise
    /// dead space, so absorbing them into the chip's tap target costs
    /// nothing visually. Horizontal overflow goes into the empty
    /// margin to either side of the centered chip and is the safest
    /// dimension to inflate aggressively.
    static let chipHitPaddingVertical: CGFloat = 12
    static let chipHitPaddingHorizontal: CGFloat = 24
    /// Layout footprint the parent VStack reserves for the chip slot.
    /// Locked to the ORIGINAL 8pt vertical hit padding so the title
    /// below doesn't move when the actual hit padding grows. The
    /// Button's content can extend past this height; hit testing
    /// includes the overflow.
    static let chipReservedHeight: CGFloat = chipVisibleHeight + 2 * 8

    /// Chip body — avatars only, no text. Keeping the structure stable
    /// (single HStack with the avatar pile as the only child) lets
    /// SwiftUI spring-animate the size change as the participant list
    /// grows from one (default user avatar) to N participants.
    private func chipContent(orange: Bool) -> some View {
        HStack(spacing: AppSpacing.xs) {
            chipLeadingVisual(orange: orange)
        }
    }

    /// Avatars all the time:
    ///   - Mode set: the full participant pile from
    ///     `modeChipAvatars`, capped at 10 visible with a "+N" pill
    ///     for overflow.
    ///   - Default state: a single 20pt cat — the current user — at
    ///     the same size as the mode-configured pile so the chip
    ///     doesn't visually shrink between states. Earlier this was
    ///     14pt and read as a different family of avatars from the
    ///     mode-set pile next to it.
    @ViewBuilder
    private func chipLeadingVisual(orange: Bool) -> some View {
        if modeIsConfigured {
            modeChipAvatars
        } else {
            OverlappingAvatarStack(
                participants: [OverlappingAvatarStack.Participant(
                    id: UserIDService.currentID(),
                    isConnected: true
                )],
                avatarSize: 20,
                strokeColor: AppColors.backgroundElevated,
                strokeWidth: 1,
                maxVisible: 1
            )
        }
    }

    /// Pixel-cat pile sized for the chip — same `OverlappingAvatarStack`
    /// layout the Home `DebtBadgeView` uses, matched at 20pt for
    /// visual consistency across screens (earlier 14pt diverged from
    /// home and read as a different family of avatars). Stroke uses
    /// `backgroundElevated` so adjacent discs blend into the chip
    /// surface rather than ringing visibly.
    private var modeChipAvatars: some View {
        let participants = chipParticipantPreview.map {
            OverlappingAvatarStack.Participant(id: $0.id, isConnected: $0.coloredAvatar)
        }
        // Show every participant up to 10; beyond that an "+N" pill
        // signals the overflow. 10 is high enough that real-world
        // splits land within the visible cap, low enough that the
        // chip width stays comfortable on standard screens (10 × 20pt
        // with 50% overlap ≈ 110pt of avatars).
        let maxVisible = 10
        let overflow = max(0, allChipParticipants.count - maxVisible)
        return OverlappingAvatarStack(
            participants: participants,
            avatarSize: 20,
            strokeColor: AppColors.backgroundElevated,
            strokeWidth: 1,
            maxVisible: maxVisible,
            overflowCount: overflow
        )
    }

    /// Every party with a role on the transaction — split participants
    /// AND payers, deduped, ordered "you first, then split members,
    /// then payer-only friends". Drives both the avatar pile and the
    /// trailing count text so the two never disagree (an earlier
    /// version derived the count from `selectedFriends + youIncluded`,
    /// which silently dropped paid-upfront friends who weren't in the
    /// split — the chip would say "1 person" while the underlying
    /// transaction had two real participants).
    private var allChipParticipants: [(id: String, coloredAvatar: Bool)] {
        var result: [(String, Bool)] = []
        var seen = Set<String>()

        // Self appears if you're in the split or you're a payer.
        let payers = displayPayers
        let friends = displaySelectedFriends
        let youIsPayer = payers.contains(where: { $0.id == "me" })
        if displayYouIncludedInSplit || youIsPayer {
            result.append((UserIDService.currentID(), true))
            seen.insert("me")
        }

        // Split members.
        for friend in friends {
            guard !seen.contains(friend.id) else { continue }
            seen.insert(friend.id)
            result.append((friend.id, friend.isConnected))
        }

        // Payers who aren't in the split — typical in paidUpfront
        // where someone covers the bill but isn't a participant.
        for payer in payers {
            guard payer.id != "me", !seen.contains(payer.id) else { continue }
            seen.insert(payer.id)
            let isConnected = friendStore.friend(byID: payer.id)?.isConnected ?? false
            result.append((payer.id, isConnected))
        }

        return result
    }

    /// Avatars to render in the chip — same ordering as
    /// `allChipParticipants`, capped for visual fit. The cap matters
    /// for chip width; the count label below uses the uncapped total.
    /// Stays in lockstep with `modeChipAvatars.maxVisible`.
    private var chipParticipantPreview: [(id: String, coloredAvatar: Bool)] {
        Array(allChipParticipants.prefix(10))
    }

    /// Subtitle shown directly under the amount block once a mode is
    /// configured. Hidden in state 1 (amount=0, no mode), state 2
    /// (amount>0, no mode), and the income tab (income transactions
    /// can't be split). Tappable — same orchestrator entry as the
    /// top chip.
    @ViewBuilder
    var modeSubtitle: some View {
        if vm.isIncome {
            Spacer().frame(height: 4)
        } else if modeIsConfigured {
            let isOrange = !amountReadyForSplit || splitHasUnresolvedConflict
            Button(action: {
                if !amountReadyForSplit {
                    triggerAmountShake()
                } else {
                    openModeFlow()
                }
            }) {
                Text(modeSubtitleText)
                    .font(AppFonts.metaText)
                    .foregroundColor(isOrange ? AppColors.warning : AppColors.textSecondary)
                    .lineLimit(1)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.pageHorizontal)
            }
            .buttonStyle(.plain)
            .offset(x: subtitleShakeOffset)
            .padding(.bottom, AppSpacing.lg)
        } else {
            // State 1/2 — subtitle hidden, but reserve a small spacer
            // so the layout doesn't snap when mode is later configured.
            Spacer().frame(height: 4)
        }
    }

    /// Composed subtitle string per the TZ rules.
    private var modeSubtitleText: String {
        guard let mode = displaySplitMode else { return "" }
        if mode == .settleUp { return settleUpSubtitle }

        let payerPrefix = subtitlePayerPrefix
        let participantCount = (displayYouIncludedInSplit ? 1 : 0) + displaySelectedFriends.count
        let peopleWord = participantCount == 1 ? "person" : "people"

        switch mode {
        case .evenly:
            return "\(payerPrefix) and split evenly with \(participantCount) \(peopleWord)"
        case .byAmount:
            return "\(payerPrefix) and split by amount with \(participantCount) \(peopleWord)"
        case .byItems:
            return "\(payerPrefix) and split the receipt with \(participantCount) \(peopleWord)"
        case .settleUp:
            return settleUpSubtitle
        }
    }

    /// Trims long display names so the subtitle line stays readable
    /// without truncating mid-phrase. "Александр Магомедов pays and
    /// split…" used to chop the trailing "1 person" off entirely
    /// because the name ate the lineLimit budget on narrow screens.
    /// Limit + ellipsis keeps the name recognisable AND the rest of
    /// the sentence intact.
    private static let subtitleNameMaxLength = 10

    private func truncatedSubtitleName(_ name: String) -> String {
        if name.count <= Self.subtitleNameMaxLength { return name }
        let kept = name.prefix(Self.subtitleNameMaxLength - 1)
        return "\(kept)…"
    }

    /// "{X} pay" / "You pay" / "{Name} pays" depending on the payers
    /// array. Falls back to "Someone pays" only in the defensive case
    /// where vm.payers is empty (the create flow always seeds a
    /// default payer, so this should be unreachable).
    private var subtitlePayerPrefix: String {
        let activePayers = displayPayers.filter { $0.amount > 0.001 }
        if activePayers.isEmpty { return "Someone pays" }
        if activePayers.count == 1 {
            let payer = activePayers[0]
            if payer.id == "me" { return "You pay" }
            return "\(truncatedSubtitleName(payer.name)) pays"
        }
        return "\(activePayers.count) people pay"
    }

    /// "You pay for Michael" / "Michael pays for you" / "{A} pays for {B}".
    private var settleUpSubtitle: String {
        let activePayers = displayPayers.filter { $0.amount > 0.001 }
        let payer = activePayers.first
        let isYouPayer = payer?.id == "me"

        if isYouPayer, let firstFriend = displaySelectedFriends.first {
            return "You pay for \(truncatedSubtitleName(firstFriend.name))"
        }
        if let payer, displayYouIncludedInSplit {
            return "\(truncatedSubtitleName(payer.name)) pays for you"
        }
        if let payer, let firstFriend = displaySelectedFriends.first(where: { $0.id != payer.id }) {
            return "\(truncatedSubtitleName(payer.name)) pays for \(truncatedSubtitleName(firstFriend.name))"
        }
        return "Settle up"
    }

    /// Shared shake gesture for amount-not-ready taps on the chip /
    /// subtitle.
    private func triggerAmountShake() {
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

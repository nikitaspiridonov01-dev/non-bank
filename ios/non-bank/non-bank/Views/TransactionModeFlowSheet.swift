import SwiftUI
import UIKit
import PhotosUI

/// Sequential walk-through that owns the entire transaction-mode
/// configuration flow. One sheet, one `NavigationStack`. Each step
/// pushes the next; the system back arrow returns to the previous
/// step (allowing mode change without re-entering the flow), and the
/// sheet itself can't be swiped down — the user either completes the
/// flow or taps Cancel on the first step.
///
/// Steps depend on the mode selected at step 0:
///
/// - **Pay for yourself** — single-tap exit. Clears all split data on
///   the VM and dismisses the sheet (the chip falls back to "Add
///   friends to this purchase").
/// - **Evenly** — `friendPicker` → `whoPay`
/// - **By amount** — `friendPicker` → `calculations` → `whoPay`
/// - **By items in receipt** — `friendPicker` → `calculations` (item
///   assignment) → `whoPay`
/// - **Settle up** — `friendPicker` (single friend) → `settleUpWhoPay`
///   (combined "Who pays / Who gets paid" — no separate calculation
///   step since 100/0 is implicit)
///
/// Entry points pass `startStep`:
///
/// - `.modePicker` — fresh start (chip / subtitle tap when no mode is
///   set yet, or external `autoOpenSplitFlow` CTAs).
/// - `.specificStep` — re-entry from state 3/4 chip/subtitle tap with
///   a mode already configured. The orchestrator computes which step
///   is "the specific step" for the active mode and seeds the path
///   accordingly. The user can swipe back to the picker if they want
///   to switch mode.
struct TransactionModeFlowSheet: View {
    @ObservedObject var vm: CreateTransactionViewModel
    let startStep: StartStep
    let currency: String
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore

    @State private var path: [Step]

    /// Snapshot of every VM field the orchestrator can mutate, captured
    /// on `.onAppear`. Lets us revert all in-flight changes if the user
    /// dismisses the sheet without completing the flow — picking a new
    /// mode in the picker, walking a few steps, then backing out should
    /// leave the underlying transaction exactly as it was before the
    /// sheet opened, not committed to the half-walked new mode.
    ///
    /// Stored as an optional because `@State` can't be initialised from
    /// `init` against an `@ObservedObject` member (the wrapper isn't
    /// resolved yet); we lazily capture on the first `.onAppear`.
    @State private var initialVMSnapshot: VMSnapshot? = nil

    /// Flipped to `true` by `completeFlow()` — the single chokepoint
    /// every real "save and exit" path runs through. When the sheet
    /// disappears with this still `false`, `.onDisappear` rolls the VM
    /// back to `initialVMSnapshot`.
    @State private var didCompleteFlow: Bool = false

    /// Captures mode-related VM state for rollback on
    /// dismiss-without-commit. `pendingReceiptItems`, `amount`,
    /// `selectedCurrency`, and `selectedCategory` are intentionally
    /// NOT snapshotted: once the user has saved a scanned receipt
    /// the items are transaction data, not mode state, and persist
    /// past mode-flow exit (mirroring how a user-entered amount
    /// survives the flow). If you add a new mode-state write inside
    /// this orchestrator, extend this struct AND the restore helper.
    private struct VMSnapshot {
        let splitMode: SplitMode?
        let isSplitMode: Bool
        let selectedFriends: [Friend]
        let youIncludedInSplit: Bool
        let byAmountShares: [String: Double]
        let payers: [Payer]
    }

    /// Compute the initial NavigationStack path eagerly in `init`
    /// rather than seeding it from `.onAppear`. Two reasons:
    ///   1. `.onAppear` fires AFTER the NavigationStack has already
    ///      rendered with the empty default path, which produced a
    ///      brief flash of the mode picker before the user got
    ///      auto-pushed to the mid-flow step. The user reads that
    ///      flash as "I always land on 'How to track this expense?'
    ///      first" — the original bug.
    ///   2. Initialising `@State` from `init` lets us use the same
    ///      `startStep + vm` snapshot the caller computed, with no
    ///      window where the path could read stale state.
    init(
        vm: CreateTransactionViewModel,
        startStep: StartStep,
        currency: String,
        onDone: @escaping () -> Void
    ) {
        self.vm = vm
        self.startStep = startStep
        self.currency = currency
        self.onDone = onDone
        self._path = State(initialValue: Self.computeInitialPath(startStep: startStep, vm: vm))
    }

    enum StartStep {
        case modePicker
        case specificStep
    }

    /// Concrete step identifiers used as `NavigationStack` destinations.
    /// Equatable + Hashable for `path: [Step]`.
    ///
    /// `itemAssignment(index)` is per-participant — the byItems flow
    /// pushes one step per participant rather than running an internal
    /// walk-through so swipe-back in the parent NavigationStack
    /// naturally lands on the previous participant rather than
    /// skipping all the way back to the friend picker.
    ///
    /// `whoPay` is the single-payer compact picker. Its "More options"
    /// affordance pushes `whoPayMultiPicker` (friend selection for
    /// multiple payers) and from there `whoPayMultiCalc` (per-payer
    /// numpad). Swipe-back from the multi flow lands on the compact
    /// picker — one extra swipe takes the user back to the prior
    /// orchestrator step. An earlier attempt removed `whoPay` from
    /// history after the push so the compact step would be skipped on
    /// swipe-back, but `NavigationStack` remounts the top destination
    /// whenever a path element below it is dropped (the element shifts
    /// position, which the stack treats as a fresh mount), and the
    /// remount surfaced as the multi-picker push animating a second
    /// time ~half a second after the real transition. Keeping the
    /// compact step in history is the lesser UX trade-off.
    enum Step: Hashable {
        case scanSource            // byItems-without-receipt: pick camera or library
        case receiptReview         // byItems-without-receipt: review parsed items
        case friendPicker
        case calculations          // byAmount: shares picker
        case itemAssignment(Int)   // byItems: participant at index
        case itemAssignmentReview  // byItems: final summary
        case whoPay                // paidUpfront compact (single payer)
        case whoPayMultiPicker     // friend picker for multiple payers
        case whoPayMultiCalc       // multi-select numpad with per-payer amounts
        case settleUpPayer         // settle-up: who's paying (single select)
        case settleUpRecipient     // settle-up: who's being paid (single select)
    }

    // MARK: - byItems walk-through state

    /// Per-participant item selections accumulated as the user walks
    /// through `itemAssignment` steps. Keyed by participant ID, valued
    /// by the in-memory `ReceiptItem.id` set selected for that
    /// participant. Initialised lazily on first `itemAssignment(0)`
    /// entry from each item's existing `assignedParticipantIDs`, so
    /// re-entering an existing byItems transaction starts where the
    /// previous walk left off.
    @State private var byItemsSelections: [String: Set<UUID>] = [:]

    /// Payers picked in the `whoPayMultiPicker` step. Carries the
    /// selection forward into `whoPayMultiCalc` (which seeds its
    /// numpad with these as zero-amount initial entries). Cleared
    /// when the orchestrator opens fresh.
    @State private var pendingMultiPayers: [Payer] = []

    /// True while the user is inside the "re-entered multi-payer via
    /// Review the split → Confirm" sub-flow. Set when Confirm pushes
    /// the per-payer numpad with a retained `vm.payers` (so backing
    /// out to Review and re-confirming lands on the numpad with the
    /// original amounts intact). While true, the compact `.whoPay`
    /// and the More-options multi-picker show fresh defaults — even
    /// though `vm.payers` still holds the retained multi config —
    /// so backing out from the numpad to the compact picker looks
    /// unaffected and More-options reads as a fresh start. Cleared
    /// on mode change at the root picker (new intent); commits go
    /// through `completeFlow` which dismisses the sheet and resets
    /// `@State` on next open.
    @State private var multiPayerCalcInFlight: Bool = false

    /// Settle-up: party chosen in the payer step (`"me"` or a
    /// `Friend.id`). Carried forward into the recipient step where
    /// the picker disables the same id and the commit handler uses
    /// it to derive `vm.payers` + `vm.youIncludedInSplit`.
    @State private var pendingSettleUpPayerID: String? = nil

    // MARK: - byItems-without-receipt scan flow state
    //
    // When the user picks `.byItems` with no receipt loaded, the
    // orchestrator pushes a `.scanSource` step → optional camera /
    // library overlay → `.receiptReview` step → on confirm, items are
    // applied to the VM and `.friendPicker` is pushed. All scan
    // bookkeeping (image, parse output, loader / error flags, picker
    // bindings) lives on the orchestrator so the flow reads as one
    // continuous push-stack from the user's point of view, instead
    // of the previous dismiss-and-reopen handoff to the modal's
    // `ReceiptScanFlowModifier`.

    @State private var pickedReceiptImage: UIImage? = nil
    @State private var parsedReceiptResult: HybridReceiptParser.Result? = nil
    @State private var isParsingReceipt: Bool = false
    @State private var receiptParseError: String? = nil
    @State private var showReceiptParseError: Bool = false
    @State private var showCamera: Bool = false
    @State private var showPhotosPicker: Bool = false
    /// Multi-image gallery picker — same 3-photo cap as the parent
    /// modal so a long receipt that didn't fit in one shot can still
    /// be assembled in one scan.
    @State private var photosPickerItems: [PhotosPickerItem] = []

    /// Lazily-created parser. Cheap to instantiate but kept on the
    /// orchestrator so successive scans share whatever per-instance
    /// state the parser sets up (HTTP session, cache). Mirrors the
    /// `CreateTransactionModal.hybridParser` pattern.
    private let hybridParser = HybridReceiptParser()

    var body: some View {
        NavigationStack(path: $path) {
            rootStep
                .navigationDestination(for: Step.self) { step in
                    destinationView(for: step)
                }
        }
        // Only block interactive dismiss once the user has pushed past
        // the mode picker — root step (mode picker) is essentially a
        // bottom-sheet menu and benefits from native swipe-to-dismiss.
        // Once they've committed to a mode and are walking the steps,
        // the swipe is disabled to prevent accidental data loss
        // mid-flow.
        .interactiveDismissDisabled(!path.isEmpty)
        // Initial path is computed in `init` so it's correct on
        // first render; .onAppear here seeds the byItems selections
        // (`byItemsSelections`) for the re-entry case (those depend
        // on the actual `pendingReceiptItems` and can't go into a
        // static helper without making it depend on `@State` of this
        // very view), and captures the VM snapshot so a back-out
        // anywhere along the flow can roll back to the pre-open
        // state. Capture is idempotent on the snapshot's `nil` guard,
        // so re-firing `.onAppear` (backgrounding the app and
        // resuming the sheet) doesn't overwrite the original
        // snapshot with already-mutated in-flight state.
        .onAppear {
            captureVMSnapshotIfNeeded()
            seedByItemsSelectionsForReentryIfNeeded()
        }
        // Roll the VM back to its pre-open state when the user
        // dismisses without going through `completeFlow()` (chevron
        // back at root, swipe-down at root, scan-flow Cancel, X
        // close button). `completeFlow()` sets `didCompleteFlow =
        // true` first so the legitimate save-and-exit paths bypass
        // this restore. Without the restore, picking a new mode in
        // the picker silently overwrote `vm.splitMode` the moment
        // the user tapped a row — even backing out before finishing
        // the new flow left the transaction in the half-configured
        // state, which the user reported as "I changed my mind but
        // the mode already switched".
        .onDisappear(perform: restoreVMSnapshotIfNotCommitted)
        // byItems-without-receipt scan flow overlays. Mounted at the
        // NavigationStack root so the scanner / photos picker stay
        // out of any individual step's view tree — they replace the
        // orchestrator visually during capture and tear back down to
        // the same step on dismissal regardless of where the user
        // launched them from.
        .fullScreenCover(isPresented: $showCamera) {
            PlainCameraView(
                onScan: { image in
                    showCamera = false
                    handleScannedImage(image)
                },
                onCancel: {
                    // Cancel anywhere in the scan flow closes the
                    // whole orchestrator (option (a) from the spec).
                    showCamera = false
                    dismiss()
                },
                onError: { error in
                    showCamera = false
                    receiptParseError = error.localizedDescription
                    showReceiptParseError = true
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
                var images: [UIImage] = []
                for item in newItems {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        images.append(image)
                    }
                }
                photosPickerItems = []
                guard !images.isEmpty else { return }
                if images.count == 1 {
                    handleScannedImage(images[0])
                } else {
                    handleScannedImages(images)
                }
            }
        }
        // Detect photos-picker-dismissed-without-selection — selection
        // assigns `photosPickerItems` first, then flips `showPhotosPicker`
        // to false, so checking the array state at dismiss-time
        // distinguishes cancel from select. Cancel collapses the whole
        // orchestrator to match the rest of the scan-flow cancel rule.
        .onChange(of: showPhotosPicker) { presenting in
            if !presenting && photosPickerItems.isEmpty {
                dismiss()
            }
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

    /// Full-bleed loader shown while `HybridReceiptParser` runs.
    /// Mirrors `CreateTransactionModal.receiptParsingOverlay` — opaque
    /// backdrop + animated loader + "Reading receipt…" so the parse
    /// step reads as a discrete "doing magic" beat rather than a
    /// semi-transparent inconvenience.
    private var receiptParsingOverlay: some View {
        ZStack {
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

    /// Kicked off when the scanner or photos picker hands back an
    /// image. Runs the `HybridReceiptParser` on a background task and
    /// — on success with non-empty items — stashes the result and
    /// pushes the `.receiptReview` step. Parse errors / empty
    /// receipts route through the same alert path the modal uses so
    /// the user gets identical messaging.
    private func handleScannedImage(_ image: UIImage) {
        pickedReceiptImage = image
        isParsingReceipt = true
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
                await CreateTransactionModal.enforceMinimumLoaderTime(startedAt: scanStartedAt)
                await MainActor.run {
                    isParsingReceipt = false
                    if result.parsedReceipt.items.isEmpty {
                        receiptParseError = "No items detected. Try a clearer photo or enter the amount manually."
                        showReceiptParseError = true
                        pickedReceiptImage = nil
                    } else {
                        parsedReceiptResult = result
                        path.append(.receiptReview)
                    }
                }
            } catch {
                await CreateTransactionModal.enforceMinimumLoaderTime(startedAt: scanStartedAt)
                await MainActor.run {
                    isParsingReceipt = false
                    receiptParseError = error.localizedDescription
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                }
            }
        }
    }

    /// Multi-image gallery scan in the byItems orchestrator. Mirrors
    /// `CreateTransactionModal.handleScannedImages` — parse each
    /// picked photo independently, then merge the per-image results
    /// into one `parsedReceiptResult` and push the review step.
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
            await CreateTransactionModal.enforceMinimumLoaderTime(startedAt: scanStartedAt)
            await MainActor.run {
                isParsingReceipt = false
                guard !perImageResults.isEmpty else {
                    receiptParseError = firstError?.localizedDescription
                        ?? "No items detected across the picked photos."
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                    return
                }
                let merged = CreateTransactionModal.mergeScanResults(perImageResults)
                guard !merged.parsedReceipt.items.isEmpty else {
                    receiptParseError = "No items detected. Try clearer photos or enter the amount manually."
                    showReceiptParseError = true
                    pickedReceiptImage = nil
                    return
                }
                parsedReceiptResult = merged
                path.append(.receiptReview)
            }
        }
    }

    /// Apply the reviewed receipt items to the VM, commit the
    /// `.byItems` mode (deferred until now so a Cancel anywhere along
    /// the scan path leaves `splitMode` exactly as the user left it),
    /// and continue into the friend picker. The scan steps are
    /// dropped from `path` so swipe-back from the friend picker
    /// lands on the mode picker, not on a stale review screen.
    private func applyParsedReceiptAndContinue(
        items: [ReceiptItem],
        total: Double,
        currency: String
    ) {
        vm.applyReceiptItems(
            items,
            total: total,
            currency: currency,
            suggestedCategory: parsedReceiptResult?.parsedReceipt.suggestedCategory,
            // Match suggestions against the reserved baseline only —
            // see CreateTransactionModal for the rationale.
            availableCategories: categoryStore.reservedCategories
        )
        vm.splitMode = .byItems
        vm.isSplitMode = true
        // `persistLastUsedSplitMode()` is deferred to `completeFlow()`
        // so a back-out from the byItems walk after a scan rolls the
        // "last used mode" preference back along with the VM state.
        // Drop `.scanSource` and `.receiptReview` so the back stack
        // reads as mode picker → byItems flow, not mode picker →
        // scan → review → byItems flow. The scan was a means to an
        // end; the user shouldn't revisit it from the byItems flow.
        //
        // Two shapes:
        // - Re-entry case (friends already configured): seed the full
        //   byItems re-entry path so the user lands on the assignment
        //   review they're presumably here to re-verify.
        // - Fresh pick (no friends yet): land on the friend picker
        //   and walk the natural forward flow.
        //
        // `parsedReceiptResult` / `pickedReceiptImage` are intentionally
        // left set: clearing them mid-transition would re-evaluate the
        // soon-to-be-popped `receiptReview` body with a nil payload
        // and flash an empty view during the pop animation. They tear
        // down with the orchestrator when the sheet dismisses.
        if vm.selectedFriends.isEmpty {
            path = [.friendPicker]
        } else {
            seedByItemsSelections()
            var seeded: [Step] = [.friendPicker]
            if vm.byItemsHasAssignments {
                for index in 0..<byItemsParticipants.count {
                    seeded.append(.itemAssignment(index))
                }
                seeded.append(.itemAssignmentReview)
            } else {
                // Fresh items (post-scan or post-edit) — assignments
                // need to be re-walked from the first participant
                // rather than dropping the user on a zero-amount review.
                seeded.append(.itemAssignment(0))
            }
            path = seeded
        }
    }

    // MARK: - Step routing

    /// The view at `path == []`. When the entry asks for the mode
    /// picker we render it directly; for `.specificStep` entries the
    /// picker still sits at the root (so swipe-back lands here) but we
    /// pre-push the relevant follow-on step in `seedPathForStartStep`.
    private var rootStep: some View {
        ModePickerStep(
            selectedMode: vm.splitMode,
            hasUsableReceipt: vm.pendingReceiptItems.count > 1,
            amount: vm.parsedAmount,
            currency: currency,
            onSelect: handleModeSelection
        )
        .navigationTitle("How to track")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: true) }
    }

    @ViewBuilder
    private func destinationView(for step: Step) -> some View {
        switch step {
        case .scanSource:
            scanSourceStep
        case .receiptReview:
            receiptReviewStep
        case .friendPicker:
            friendPickerStep
        case .calculations:
            byAmountCalcStep
        case .itemAssignment(let index):
            itemAssignmentStep(at: index)
        case .itemAssignmentReview:
            itemAssignmentReviewStep
        case .whoPay:
            whoPayStep
        case .whoPayMultiPicker:
            whoPayMultiPickerStep
        case .whoPayMultiCalc:
            whoPayMultiCalcStep
        case .settleUpPayer:
            settleUpPayerStep
        case .settleUpRecipient:
            settleUpRecipientStep
        }
    }

    // MARK: - Settle-up flow (payer → recipient)

    /// First settle-up step — single-select friend picker for the
    /// party who paid (or transferred the money). User picks
    /// exactly one of "You" or a friend.
    private var settleUpPayerStep: some View {
        let prefilledPayerFriend = vm.selectedFriends.first { friend in
            pendingSettleUpPayerID == friend.id
        }
        return FriendPickerView(
            title: "Who pays",
            subtitle: "Select who's paying for the purchase or transferring money.",
            initialSelection: prefilledPayerFriend.map { [$0] } ?? [],
            includeYou: true,
            youSelected: pendingSettleUpPayerID == "me",
            wrapInNavigationStack: false,
            singleSelect: true,
            onConfirm: { friends, youSelected in
                if youSelected {
                    pendingSettleUpPayerID = "me"
                } else if let friend = friends.first {
                    pendingSettleUpPayerID = friend.id
                } else {
                    return
                }
                path.append(.settleUpRecipient)
            }
        )
        .navigationTitle("Who pays")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Second settle-up step — single-select friend picker for the
    /// recipient (or transfer target). Commits the full settle-up
    /// configuration to the VM on save (payer, recipient, who's in
    /// the split) — this is the final step before the orchestrator
    /// dismisses.
    private var settleUpRecipientStep: some View {
        // Pre-fill from the existing settle-up data, if any. The
        // recipient is the side that BEARS the share — `myShare > 0`
        // means "you" was recipient; otherwise the first friend with
        // a positive share.
        let prefilledRecipientID: String? = {
            if let payerID = pendingSettleUpPayerID, payerID != "me" {
                // Payer is a friend → check whether "you" is the
                // share-bearer.
                if vm.youIncludedInSplit { return "me" }
            }
            return vm.selectedFriends.first { f in
                f.id != pendingSettleUpPayerID
            }?.id
        }()
        let prefilledRecipientFriend = vm.selectedFriends.first { $0.id == prefilledRecipientID }
        return FriendPickerView(
            title: "Who is paid",
            subtitle: "Select who is being paid or who the money is being transferred to.",
            initialSelection: prefilledRecipientFriend.map { [$0] } ?? [],
            includeYou: true,
            youSelected: prefilledRecipientID == "me",
            wrapInNavigationStack: false,
            singleSelect: true,
            // Hide whoever was just picked as payer — tapping the same
            // party as recipient hits the same-party guard and silently
            // returns, which the user reads as "lag" (highlight changes,
            // no transition). Filtering removes the dead row entirely.
            excludeID: pendingSettleUpPayerID,
            onConfirm: { friends, youSelected in
                let recipientID: String
                if youSelected {
                    recipientID = "me"
                } else if let friend = friends.first {
                    recipientID = friend.id
                } else {
                    return
                }
                // Guard against same-party settle-up (payer ==
                // recipient). The picker doesn't currently disable
                // the payer row, so we silently no-op here if the
                // user picked themselves as both — letting Save
                // remain a confirmation step rather than commit a
                // nonsensical state.
                guard let payerID = pendingSettleUpPayerID,
                      payerID != recipientID else { return }
                commitSettleUp(payerID: payerID, recipientID: recipientID)
                completeFlow()
            }
        )
        .navigationTitle("Who is paid")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Materialises payer + recipient into the VM's split-info
    /// shape (`payers` + `selectedFriends` + `youIncludedInSplit`).
    /// Covers the three cases — me→friend, friend→me, friend→friend
    /// — that the picker pair can produce.
    private func commitSettleUp(payerID: String, recipientID: String) {
        let total = vm.parsedAmount

        if payerID == "me" {
            // Me pays friend.
            guard let friend = friendStore.friend(byID: recipientID) else { return }
            vm.payers = [Payer(id: "me", name: "You", amount: total)]
            vm.selectedFriends = [friend]
            vm.youIncludedInSplit = false
        } else if recipientID == "me" {
            // Friend pays me.
            guard let friend = friendStore.friend(byID: payerID) else { return }
            vm.payers = [Payer(id: friend.id, name: friend.name, amount: total)]
            vm.selectedFriends = [friend]
            vm.youIncludedInSplit = true
        } else {
            // Friend → friend. Both stay in `selectedFriends`; the
            // payer appears in `vm.payers`. Settle-up coercion in
            // `buildTransaction` still detects 1-payer-1-receiver
            // shape and tags the saved mode as `.settleUp`.
            guard let payerFriend = friendStore.friend(byID: payerID),
                  let recipientFriend = friendStore.friend(byID: recipientID) else { return }
            vm.payers = [Payer(id: payerFriend.id, name: payerFriend.name, amount: total)]
            vm.selectedFriends = [payerFriend, recipientFriend]
            vm.youIncludedInSplit = false
        }

        vm.isSplitMode = true
        vm.splitMode = .settleUp
    }

    // MARK: - byItems-without-receipt scan steps

    /// First step of the byItems-without-receipt flow. Picking a row
    /// flips the scanner / photos picker overlay (mounted on the
    /// NavigationStack root); the X toolbar button closes the whole
    /// orchestrator, matching the answer the user gave when we
    /// scoped the unified flow.
    private var scanSourceStep: some View {
        ReceiptSourcePickerView(
            wrapInNavigationStack: false,
            onPickCamera: {
                // Simulator / no-camera guard — same as the
                // top-of-modal scan path. `UIImagePickerController`
                // crashes if `.camera` source isn't available; the
                // user can pick Library from the same picker instead.
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    showCamera = true
                }
            },
            onPickLibrary: {
                showPhotosPicker = true
            }
        )
        .navigationTitle("Scan receipt")
        .toolbarTitleDisplayMode(.inline)
        // The native back arrow would pop to the mode picker, which
        // is the "swap modes" affordance — but the user picked
        // option (a) "Cancel = close the whole orchestrator" when we
        // scoped this. Hide the back arrow and render the X close
        // button instead so there's exactly one escape path.
        .navigationBarBackButtonHidden(true)
        .toolbar { scanFlowCancelToolbar }
    }

    /// Push-step variant of `ReceiptReviewView`. Cancel closes the
    /// whole orchestrator (same as `scanSource`); Save commits items
    /// + the byItems mode and continues into the friend picker. The
    /// review's own Save/Cancel toolbar items show up in the
    /// orchestrator's NavigationBar because the view's `.toolbar`
    /// modifier attaches to the nearest enclosing stack — that's why
    /// the X close button has to live in its own `scanFlowCancelToolbar`
    /// placement (`.cancellationAction`) to avoid colliding with
    /// `ReceiptReviewView`'s Cancel item.
    @ViewBuilder
    private var receiptReviewStep: some View {
        if let parseResult = parsedReceiptResult {
            ReceiptReviewView(
                parseResult: parseResult,
                sourceImage: pickedReceiptImage,
                onConfirm: { items, total, currency in
                    applyParsedReceiptAndContinue(
                        items: items,
                        total: total,
                        currency: currency
                    )
                },
                onCancel: {
                    // User picked option (a) — Cancel anywhere in
                    // the scan flow closes the orchestrator.
                    dismiss()
                },
                wrapInNavigationStack: false
            )
            // `ReceiptReviewView` carries its own Cancel + Save in a
            // `.toolbar { ... }` modifier; SwiftUI attaches that to
            // the orchestrator's NavigationStack, which is what we
            // want. Don't add a separate `commonToolbar` here or
            // both Cancel buttons collide in `.cancellationAction`.
            .navigationBarBackButtonHidden(true)
        }
    }

    /// Shared X-button toolbar for the scan-flow steps that don't
    /// already supply their own (`scanSource`). One placement
    /// (`.cancellationAction`), one action (`dismiss()`) — matches
    /// the "Cancel = close whole orchestrator" rule.
    @ToolbarContentBuilder
    private var scanFlowCancelToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
            }
            .accessibilityLabel("Close")
        }
        // Match `commonToolbar` — empty principal so the visible
        // title stays clean while `.navigationTitle(...)` still drives
        // the back-history menu.
        ToolbarItem(placement: .principal) {
            EmptyView()
        }
    }

    /// Embedded `WhoPaidPickerView` in `.splitShares` mode, wrapped in
    /// the orchestrator's NavigationStack. The picker's own Save action
    /// fires `onConfirm` here, which writes shares back to the VM and
    /// pushes the next step. The "Cancel" toolbar inside the picker is
    /// suppressed by `wrapInNavigationStack: false` — the orchestrator
    /// supplies its own back arrow as the parent NavigationStack's
    /// cancellation slot.
    private var byAmountCalcStep: some View {
        WhoPaidPickerView(
            participants: byAmountParticipants,
            totalAmount: vm.parsedAmount,
            currency: currency,
            initialPayers: byAmountInitialShares,
            purpose: .splitShares,
            wrapInNavigationStack: false,
            onConfirm: { confirmed in
                var dict: [String: Double] = [:]
                for p in confirmed {
                    dict[p.id] = p.amount
                }
                vm.byAmountShares = dict
                if isMultiPayerConfigured {
                    // Multi-payer already configured upstream — jump
                    // straight to the per-payer numpad seeded with the
                    // current amounts (same multi-in-flight pattern as
                    // the byItems review). `vm.payers` stays intact so
                    // back → back → forward (numpad → whoPay → shares
                    // → save) re-enters the numpad with the same
                    // amounts. The compact whoPay underneath shows
                    // fresh defaults until the user actually commits.
                    pendingMultiPayers = vm.payers
                    multiPayerCalcInFlight = true
                    path.append(contentsOf: [.whoPay, .whoPayMultiCalc])
                } else {
                    path.append(.whoPay)
                }
            }
        )
        .navigationTitle("Set shares")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Participants for the byAmount picker, filtering "You" out when
    /// the user opted out of the split. Mirrors the helper on the
    /// modal extension.
    private var byAmountParticipants: [WhoPaidParticipant] {
        var list: [WhoPaidParticipant] = []
        if vm.youIncludedInSplit {
            list.append(WhoPaidParticipant(id: "me", name: "You"))
        }
        list += vm.selectedFriends.map { friend in
            WhoPaidParticipant(id: friend.id, name: friend.name)
        }
        return list
    }

    /// Initial shares for the picker — saved values when re-entering
    /// the calc step, all zeros otherwise. Equal split as a starter
    /// felt convenient on paper but turned out misleading: users
    /// read pre-filled values as "the app picked these for me, I
    /// just confirm" and accidentally committed evenly-split numbers
    /// when they meant to assign custom shares. Zeros surface the
    /// expectation "you have to enter each one" and the "X left"
    /// counter shows progress against the target total.
    private var byAmountInitialShares: [Payer] {
        let participants = byAmountParticipants
        guard !participants.isEmpty else { return [] }
        if !vm.byAmountShares.isEmpty {
            return participants.map { p in
                Payer(id: p.id, name: p.name, amount: vm.byAmountShares[p.id] ?? 0)
            }
        }
        return participants.map { p in
            Payer(id: p.id, name: p.name, amount: 0)
        }
    }

    /// Wraps `FriendPickerView` in `wrapInNavigationStack: false` mode
    /// so the orchestrator's NavigationStack owns the chrome. Confirm
    /// commits selection (and the `you` opt-in) to the VM and pushes
    /// the next step (which depends on mode — see `pushAfterFriendPicker`).
    ///
    /// "You" is shown across every mode for UI consistency. Settle-up
    /// internally clamps to a single friend on save and forces "You"
    /// in regardless of the picker's checkbox — the row is decorative
    /// in that case but matches the rhythm of the other flows.
    private var friendPickerStep: some View {
        let isSettleUp = vm.splitMode == .settleUp
        return FriendPickerView(
            title: isSettleUp ? "Who to settle with" : "Who to split with",
            subtitle: isSettleUp
                ? "Pick the one person you're settling up with."
                : "Based on the number of people, we'll calculate how much each person owes.",
            initialSelection: vm.selectedFriends,
            includeYou: true,
            youSelected: vm.youIncludedInSplit,
            wrapInNavigationStack: false,
            onConfirm: { friends, youSelected in
                // Settle-up clamps to a single friend; if more were
                // selected we keep just the first to satisfy the
                // 1:1 invariant.
                let resolved = isSettleUp
                    ? Array(friends.prefix(1))
                    : friends
                // Settle-up always implies the user is in the split
                // (it's a 1:1 thing) — we set youIncluded true
                // regardless of the picker's youSelected (which is
                // hidden in that flow).
                vm.youIncludedInSplit = isSettleUp ? true : youSelected
                // Set friends + flip into split mode WITHOUT going
                // through `selectFriendsAndResolveSplitMode`. That
                // helper re-derives `splitMode` via the resolver
                // (which intentionally skips `.byAmount` because
                // byAmount can't be a system default) — but inside
                // the orchestrator the user has *just* picked the
                // mode in step 0, so the resolver would override
                // their explicit pick (the "byAmount silently
                // becomes evenly" bug surfaced by the user).
                vm.selectedFriends = resolved
                vm.isSplitMode = true
                if vm.payers.isEmpty {
                    vm.setDefaultPayer()
                }
                pushAfterFriendPicker()
            }
        )
        .navigationTitle(isSettleUp ? "Who to settle with" : "Who to split with")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    // MARK: - byItems step (per-participant)

    /// One participant's item-selection screen. Reuses the same
    /// `ItemAssignmentStep` visuals from Phase 4.2 — the orchestrator
    /// just owns the multi-step state so swipe-back lands on the
    /// previous participant rather than the friend picker.
    private func itemAssignmentStep(at index: Int) -> some View {
        let participants = byItemsParticipants
        // Defensive: out-of-range index can't happen via push, but
        // could appear if the orchestrator is replayed against a
        // different participant set. Show an empty placeholder rather
        // than crash.
        if index >= participants.count {
            return AnyView(placeholder(title: "Done", nextStep: .whoPay))
        }
        let participant = participants[index]
        let assignableItems = vm.pendingReceiptItems.filter { $0.kind == .item }
        let isLastStep = index == participants.count - 1

        // For each item, the OTHER participants (i.e. not the one
        // we're currently looking at) who've already claimed it.
        // Powers the small avatar stack next to each row + the
        // tap-through "Already assigned to" sheet so the user can
        // see at a glance whether they're picking from a fresh row
        // or one that's already shared. Computed inline rather than
        // cached on `byItemsSelections` because the dict mutates
        // per-tap and SwiftUI re-evaluates this builder anyway.
        let otherClaimants: [UUID: [ItemAssignmentParticipant]] = {
            var result: [UUID: [ItemAssignmentParticipant]] = [:]
            for (idx, p) in participants.enumerated() where idx != index {
                guard let selection = byItemsSelections[p.id], !selection.isEmpty else {
                    continue
                }
                let entry = ItemAssignmentParticipant(
                    id: p.id,
                    name: p.name,
                    isMe: p.id == ReceiptItem.selfParticipantID,
                    isConnected: p.isConnected
                )
                for itemID in selection {
                    result[itemID, default: []].append(entry)
                }
            }
            return result
        }()

        return AnyView(
            ItemAssignmentStep(
                participant: ItemAssignmentParticipant(
                    id: participant.id,
                    name: participant.name,
                    isMe: participant.id == ReceiptItem.selfParticipantID,
                    isConnected: participant.isConnected
                ),
                stepNumber: index + 1,
                totalSteps: participants.count,
                items: assignableItems,
                currency: currency,
                selection: Binding(
                    get: { byItemsSelections[participant.id] ?? [] },
                    set: { byItemsSelections[participant.id] = $0 }
                ),
                isLastStep: isLastStep,
                // Only meaningful on the last step — the warning UI
                // is gated on `isLastStep` inside the view. Computed
                // each render so live edits (toggle on the current
                // step, back-navigate and edit prior steps) reflect
                // immediately.
                globallyOrphanedItemIDs: isLastStep
                    ? orphanedAssignableItemIDs
                    : [],
                otherClaimants: otherClaimants,
                onContinue: {
                    if index + 1 < participants.count {
                        path.append(.itemAssignment(index + 1))
                    } else {
                        path.append(.itemAssignmentReview)
                    }
                }
            )
            .navigationTitle("Assign items")
            .toolbarTitleDisplayMode(.inline)
            .toolbar { commonToolbar(includeBack: false) }
        )
    }

    /// IDs of `.item`-kind receipt rows that aren't selected by
    /// anyone across `byItemsSelections`. Used on the last
    /// assignment step to block Continue + flag the rows visually —
    /// "every item must end up on someone" is the byItems contract,
    /// so reaching the review step with floaters would corrupt the
    /// share-calculator's inputs (an item assigned to no one is
    /// treated as a free-for-everyone discount, which is rarely the
    /// user's intent).
    private var orphanedAssignableItemIDs: Set<UUID> {
        let assignedAnywhere: Set<UUID> = byItemsSelections.values
            .reduce(into: []) { acc, set in acc.formUnion(set) }
        let assignable = vm.pendingReceiptItems
            .filter { $0.kind == .item }
            .map(\.id)
        return Set(assignable).subtracting(assignedAnywhere)
    }

    /// Final review screen for the byItems walk. Save commits all
    /// selections back to the items array and pushes to who-pay.
    /// When multi-payer is already configured (typical re-entry via
    /// the caption / chip), Save jumps straight to the per-payer
    /// numpad seeded with the current amounts — otherwise the user
    /// would land on the compact single-payer picker and lose their
    /// payer split silently.
    private var itemAssignmentReviewStep: some View {
        let participants = byItemsParticipants.map { p in
            ItemAssignmentParticipant(
                id: p.id,
                name: p.name,
                isMe: p.id == ReceiptItem.selfParticipantID,
                isConnected: p.isConnected
            )
        }
        return ItemAssignmentReview(
            items: vm.pendingReceiptItems,
            participants: participants,
            selections: byItemsSelections,
            currency: currency,
            onSave: {
                commitByItemsSelections()
                if isMultiPayerConfigured {
                    // Snapshot the multi-payer config into
                    // pendingMultiPayers so the numpad opens with
                    // current amounts. `vm.payers` stays intact —
                    // backing out through whoPay to review and
                    // re-confirming re-pushes the numpad with the
                    // same amounts. multiPayerCalcInFlight overrides
                    // the in-between whoPay / More-options pickers
                    // to show defaults regardless of the retained
                    // multi state; the retention is released only
                    // when the user actually commits.
                    pendingMultiPayers = vm.payers
                    multiPayerCalcInFlight = true
                    path.append(contentsOf: [.whoPay, .whoPayMultiCalc])
                } else {
                    path.append(.whoPay)
                }
            }
        )
        .navigationTitle("Review split")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Materialises the in-memory selection sets back onto each item's
    /// `assignedParticipantIDs`. Items not classified as `.item` keep
    /// their existing assignments (always empty in practice — fees /
    /// tax / tip / discount aren't user-assigned).
    private func commitByItemsSelections() {
        for index in vm.pendingReceiptItems.indices {
            let item = vm.pendingReceiptItems[index]
            guard item.kind == .item else { continue }
            var assignees: [String] = []
            for p in byItemsParticipants {
                if byItemsSelections[p.id]?.contains(item.id) == true {
                    assignees.append(p.id)
                }
            }
            vm.pendingReceiptItems[index].assignedParticipantIDs = assignees
        }
    }

    /// byItems participants use `ReceiptItem.selfParticipantID` (`__me__`)
    /// for the user — items store assignments under that key and the
    /// calculator expects the same. `isConnected` mirrors `Friend.isConnected`
    /// so the item-assignment screens can colour avatars consistently with
    /// the rest of the app (connected = full colour, ghost = B&W).
    private var byItemsParticipants: [(id: String, name: String, isConnected: Bool)] {
        var list: [(String, String, Bool)] = []
        if vm.youIncludedInSplit {
            list.append((ReceiptItem.selfParticipantID, "You", true))
        }
        list += vm.selectedFriends.map { ($0.id, $0.name, $0.isConnected) }
        return list
    }

    // MARK: - whoPay step (compact, single payer)

    /// Compact `WhoPaidPickerView` in `.paidUpfront` mode. Tap on a
    /// row commits a single payer and dismisses the orchestrator.
    /// "More options" tap routes through the orchestrator's path
    /// (`whoPayMultiPicker` → `whoPayMultiCalc`) instead of the
    /// picker's legacy nested-sheet flow, so the back-stack stays
    /// consistent.
    private var whoPayStep: some View {
        WhoPaidPickerView(
            participants: whoPayParticipants,
            totalAmount: vm.parsedAmount,
            currency: currency,
            // Always pass exactly one initial payer so the picker
            // starts in compact mode (its `shouldStartInMultiSelect`
            // gate is `initialPayers.count > 1`). When the upstream
            // VM has > 1 payers (re-entering an existing multi-payer
            // transaction), `seedPathForStartStep` lands on
            // `whoPayMultiCalc` directly so this step is bypassed.
            initialPayers: compactInitialPayer,
            purpose: .paidUpfront,
            wrapInNavigationStack: false,
            onMoreOptionsTapped: { handleMoreOptionsForPaidUpfront() },
            onConfirm: { confirmedPayers in
                vm.payers = confirmedPayers
                completeFlow()
            }
        )
        .navigationTitle("Who paid")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Plain forward push of `whoPayMultiPicker` — no path
    /// manipulation under the top. See the Step enum doc-comment for
    /// the history of why this is a one-liner.
    private func handleMoreOptionsForPaidUpfront() {
        path.append(.whoPayMultiPicker)
    }

    /// Single-entry initial payer for the compact step. Re-uses the
    /// existing default payer on the VM if present (typically "You"
    /// after `setDefaultPayer`); otherwise synthesises one from
    /// "you" so the picker has a row to highlight on first open.
    /// Inside the multi-payer-from-review sub-flow (`multiPayerCalcInFlight`),
    /// `vm.payers` is intentionally retained so back-navigation
    /// doesn't lose the user's amounts. Show a fresh single-payer
    /// default here so the compact picker reads as untouched — a
    /// tap on any row replaces vm.payers with the single choice
    /// (`whoPayStep.onConfirm`), releasing the retained multi.
    private var compactInitialPayer: [Payer] {
        if multiPayerCalcInFlight {
            return [Payer(id: "me", name: "You", amount: vm.parsedAmount)]
        }
        if let existing = vm.payers.first {
            return [existing]
        }
        return [Payer(id: "me", name: "You", amount: vm.parsedAmount)]
    }

    /// Always includes "You" + selected friends — payers are
    /// independent of split participants (you can pay even if you
    /// opted out of the split itself).
    private var whoPayParticipants: [WhoPaidParticipant] {
        var list: [WhoPaidParticipant] = [WhoPaidParticipant(id: "me", name: "You")]
        list += vm.selectedFriends.map { friend in
            WhoPaidParticipant(id: friend.id, name: friend.name)
        }
        return list
    }

    // MARK: - whoPay multi-payer flow (More options path)

    /// Friend picker for selecting multiple payers — replaces the
    /// nested-sheet that the standalone WhoPaidPickerView shows from
    /// its compact "More options" affordance, but as a real
    /// orchestrator step so swipe-back navigation behaves naturally.
    /// On confirm, builds zero-amount initial payers and pushes the
    /// numpad step where the user enters amounts.
    private var whoPayMultiPickerStep: some View {
        FriendPickerView(
            title: "More options to choose who pay",
            subtitle: "Pick everyone who paid upfront for the purchase. They'll owe less since they already covered part of the cost.",
            // Inside the multi-payer-from-review sub-flow the retained
            // vm.payers would surface as a stale preselect — show fresh
            // defaults here (no friends preselected, You selected) so
            // the picker reads as a clean re-entry. Confirming on this
            // step builds a brand-new payer set and pushes the numpad
            // (or short-circuits to single via the totalSelected == 1
            // branch in onConfirm), both of which replace vm.payers.
            initialSelection: multiPayerCalcInFlight
                ? []
                : vm.selectedFriends.filter { friend in
                    vm.payers.contains(where: { $0.id == friend.id })
                },
            includeYou: true,
            youSelected: multiPayerCalcInFlight
                ? true
                : vm.payers.contains(where: { $0.id == "me" }),
            wrapInNavigationStack: false,
            onConfirm: { friends, youSelected in
                let totalSelected = friends.count + (youSelected ? 1 : 0)

                // Exactly one payer means they cover the whole
                // purchase — there's no per-payer split to enter, so
                // the numpad step would just show a single row at
                // 100%. Commit straight to the VM with the full
                // amount and close the flow. Mirrors what the compact
                // `whoPayStep` does for a single-tap commit.
                if totalSelected == 1 {
                    let payer: Payer
                    if youSelected {
                        payer = Payer(id: "me", name: "You", amount: vm.parsedAmount)
                    } else if let friend = friends.first {
                        payer = Payer(id: friend.id, name: friend.name, amount: vm.parsedAmount)
                    } else {
                        return  // Unreachable: totalSelected == 1 requires one side.
                    }
                    vm.payers = [payer]
                    completeFlow()
                    return
                }

                var payers: [Payer] = []
                if youSelected {
                    payers.append(Payer(id: "me", name: "You", amount: 0))
                }
                payers += friends.map { Payer(id: $0.id, name: $0.name, amount: 0) }
                pendingMultiPayers = payers
                path.append(.whoPayMultiCalc)
            }
        )
        .navigationTitle("Add payers")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Multi-select numpad — user enters per-payer amounts. Initial
    /// payers come from the picker step's selection, so the numpad
    /// opens with each chosen party shown as a zero-amount row ready
    /// to receive input.
    ///
    /// Two commit paths:
    /// - `onConfirm` — sum is at or under the receipt total, just
    ///   write payers and exit.
    /// - `onConfirmWithNewTotal` — user crossed the receipt total and
    ///   chose "Yes, set total to X" in the exceed sheet. We bump
    ///   `vm.amount` to the new total alongside the payer commit so
    ///   downstream balance checks (`byAmountSharesBalanced`, the
    ///   chip's exceed badge, the orange subtitle for amount/calc
    ///   mismatch) recompute against the new figure. Without this
    ///   hook the picker falls back to plain `onConfirm`, which
    ///   silently drops the new-total request — the bug that surfaced
    ///   when this picker moved into the orchestrator.
    private var whoPayMultiCalcStep: some View {
        WhoPaidPickerView(
            participants: pendingMultiPayers.map {
                WhoPaidParticipant(id: $0.id, name: $0.name)
            },
            totalAmount: vm.parsedAmount,
            currency: currency,
            initialPayers: pendingMultiPayers,
            purpose: .paidUpfront,
            wrapInNavigationStack: false,
            onConfirm: { confirmedPayers in
                vm.payers = confirmedPayers
                completeFlow()
            },
            onConfirmWithNewTotal: { confirmedPayers, newTotal, exceedingPayer in
                vm.payers = confirmedPayers
                vm.amount = Self.formatAmountString(newTotal)
                // When a receipt is loaded, attribute the overage to
                // the exceeding payer by upserting a "{name}'s extra"
                // / "Extra" placeholder line so the items still sum to
                // the new total. `reconcilePaidExtra` no-ops when
                // there's no receipt, so no external guard needed.
                if let payer = exceedingPayer {
                    vm.reconcilePaidExtra(payerName: payer.name, newTotal: newTotal)
                }
                completeFlow()
            }
        )
        .navigationTitle("Payer amounts")
        .toolbarTitleDisplayMode(.inline)
        .toolbar { commonToolbar(includeBack: false) }
    }

    /// Same Double→String shape that `CreateTransactionViewModel`
    /// uses when restoring `amount` from a saved transaction — integer
    /// values come out without a trailing ".0", decimals keep their
    /// native string form. Keeping the conversion local rather than
    /// adding a VM method since this is the only orchestrator-side
    /// caller; if a third site appears, promote it to the VM.
    private static func formatAmountString(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(value)
    }

    /// Temporary placeholder used by chunk-2 skeleton. Real step views
    /// (FriendPickerView wrap, calc step, who-pay step) replace these
    /// in chunk 3.
    private func placeholder(title: String, nextStep: Step?) -> some View {
        VStack(spacing: AppSpacing.lg) {
            Spacer()
            Text(title)
                .font(AppFonts.heading)
                .foregroundColor(AppColors.textPrimary)
            Text("Step content goes here.")
                .font(AppFonts.bodySmallRegular)
                .foregroundColor(AppColors.textTertiary)
            Spacer()
            Button {
                if let nextStep {
                    path.append(nextStep)
                } else {
                    completeFlow()
                }
            } label: {
                Text(nextStep == nil ? "Save" : "Continue")
                    .font(AppFonts.bodyEmphasized)
                    .foregroundColor(AppColors.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.lg)
                    .background(AppColors.backgroundElevated)
                    .cornerRadius(AppRadius.xlarge)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, AppSpacing.pageHorizontal)
        }
        .padding(.bottom, AppSpacing.lg)
        .background(AppColors.backgroundPrimary.ignoresSafeArea())
        .navigationTitle(title)
        .toolbarTitleDisplayMode(.inline)
    }

    // MARK: - Common toolbar

    /// Toolbar content shared by every step. Only adds an explicit
    /// chevron-back at the root — pushed steps rely on the platform
    /// `NavigationStack` auto-back, which renders the same chevron
    /// icon natively. Adding our own `cancellationAction` on pushed
    /// steps stacked alongside the auto-back, producing the
    /// double-chevron the user reported.
    ///
    /// `topBarLeading` (instead of `cancellationAction`) avoids a
    /// SwiftUI quirk where the cancellation slot at a navigation-
    /// stack root with no parent route can swallow the first tap or
    /// two before the bound action fires (the user reported 3-4 taps
    /// needed to close from the mode picker). The explicit 44pt
    /// frame guarantees a comfortable hit target right against the
    /// screen edge.
    /// Single chokepoint for "this is the last action of the mode
    /// flow — commit and return to the create screen". Fires a
    /// medium-impact haptic so the user feels the transition land —
    /// distinguishable from the `.light` row-taps that happen
    /// throughout the picker steps, lighter than the `.success`
    /// notification reserved for the actual transaction save. Used by
    /// every mode that closes the flow: Pay for yourself, Evenly,
    /// By amount, By items, Settle up, and the multi-payer numpad
    /// branch.
    private func completeFlow() {
        // Single source of truth for "the user confirmed this flow":
        //   - Marks the snapshot as committed so `.onDisappear` skips
        //     the roll-back.
        //   - Persists the last-used mode preference now that we know
        //     the user actually stuck with the choice (the picker tap
        //     and the receipt-review confirm used to persist eagerly,
        //     which leaked the mode change into UserDefaults even
        //     when the user backed out before completing).
        didCompleteFlow = true
        vm.persistLastUsedSplitMode()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onDone()
        dismiss()
    }

    @ToolbarContentBuilder
    private func commonToolbar(includeBack: Bool) -> some ToolbarContent {
        if includeBack {
            ToolbarItem(placement: .topBarLeading) {
                // Plain `Image` inside a `Button` — iOS 26 toolbar
                // wraps it in the same circular Liquid-Glass chrome
                // it auto-applies to system back arrows on every
                // other step of this flow. Earlier attempts that
                // pinned an explicit `frame` + `glassEffect` ended
                // up doubled-up against the toolbar's own button
                // chrome, which read as a rectangular sublayer
                // around the disc; letting the toolbar own the
                // styling is what makes this back button match the
                // pushed-step back arrows.
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.backward")
                }
                .accessibilityLabel("Close")
            }
        }
        // Empty principal slot suppresses the visible inline title in
        // the navigation bar. We still set `.navigationTitle(...)` per
        // step — that value drives the long-press back-history menu on
        // the system back button, so each row in the menu reads as the
        // step's name. Earlier the navigation title was `""` on every
        // step, which made the back-history menu render blank rows
        // that looked broken.
        ToolbarItem(placement: .principal) {
            EmptyView()
        }
    }

    // MARK: - Step transitions

    /// What follows the friend-picker step depends on the mode. Evenly
    /// has no calculation — straight to who-pay. Settle-up has its own
    /// combined "who pays / who gets paid" sheet (no calculation step
    /// because 100/0 is implicit). byItems pushes the first participant
    /// step and seeds the selection dictionary so subsequent steps
    /// have something to bind into.
    private func pushAfterFriendPicker() {
        switch vm.splitMode {
        case .evenly?:
            // Evenly has no calc step — Save on friend picker goes
            // straight to who-pay. When a multi-payer config was set
            // upstream, take the same multi-in-flight detour as the
            // byItems / byAmount Save paths: push the numpad with the
            // retained amounts (via pendingMultiPayers) and keep
            // `whoPay` underneath so back-pop lands on a defaults-only
            // compact picker.
            if isMultiPayerConfigured {
                pendingMultiPayers = vm.payers
                multiPayerCalcInFlight = true
                path.append(contentsOf: [.whoPay, .whoPayMultiCalc])
            } else {
                path.append(.whoPay)
            }
        case .byAmount?:
            path.append(.calculations)
        case .byItems?:
            seedByItemsSelections()
            if byItemsParticipants.isEmpty {
                // Defensive — friend picker enforces ≥1 participant
                // and the orchestrator excludes "you" only when the
                // user opted out, so this should be unreachable. Fall
                // through to who-pay rather than push an empty step.
                path.append(.whoPay)
            } else {
                path.append(.itemAssignment(0))
            }
        case .settleUp?:
            // Should be unreachable — settle-up never pushes
            // `.friendPicker` (mode picker routes it straight to
            // `.settleUpPayer`). Fall back to who-pay defensively.
            path.append(.whoPay)
        case .none:
            path.append(.whoPay)
        }
    }

    /// Hydrates `byItemsSelections` from each item's saved
    /// `assignedParticipantIDs`. Called once per orchestrator open;
    /// subsequent participant-step pushes just read/write the existing
    /// dictionary.
    private func seedByItemsSelections() {
        guard byItemsSelections.isEmpty else { return }
        for participant in byItemsParticipants {
            var set = Set<UUID>()
            for item in vm.pendingReceiptItems where item.kind == .item {
                if item.assignedParticipantIDs.contains(participant.id) {
                    set.insert(item.id)
                }
            }
            byItemsSelections[participant.id] = set
        }
    }

    private func handleModeSelection(_ mode: ModePickerStep.Choice) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        // Mode change at the root picker means the previous in-flight
        // multi-payer sub-flow (if any) belongs to a stale intent. Drop
        // the flag so the next walk uses normal vm.payers-driven
        // defaults instead of forcing the fresh-You preselect.
        multiPayerCalcInFlight = false
        switch mode {
        case .payForYourself:
            // Wipe every shred of split state — TZ explicitly: "все
            // split-данные очищаются". Receipt items themselves stay
            // (they're a separate concept from split), but their
            // per-participant assignments are dropped so a later
            // re-entry into byItems starts from a clean slate.
            vm.isSplitMode = false
            vm.splitMode = nil
            vm.selectedFriends = []
            vm.byAmountShares = [:]
            vm.payers = []
            for index in vm.pendingReceiptItems.indices {
                vm.pendingReceiptItems[index].assignedParticipantIDs = []
            }
            completeFlow()
        case .splitMode(let m):
            // `.byItems` with no receipt loaded needs a scan first —
            // the assignment screens are meaningless without items.
            // The scan is run inside this same orchestrator
            // (`scanSource` → camera/library overlay → `receiptReview`
            // step) so the user reads it as one continuous push-stack
            // rather than a dismiss-and-reopen handoff. The mode
            // commit itself happens after review confirm (see
            // `applyParsedReceiptAndContinue`); a Cancel anywhere
            // before that closes the whole orchestrator and leaves
            // `splitMode` untouched.
            if m == .byItems && vm.pendingReceiptItems.isEmpty {
                path.append(.scanSource)
                return
            }

            vm.splitMode = m
            vm.isSplitMode = true
            // `persistLastUsedSplitMode()` is deferred to
            // `completeFlow()` — a back-out from anywhere in the new
            // mode's flow rolls the VM (via the snapshot) AND the
            // "last used" preference back to the pre-tap state.
            // Settle-up has its own 2-step single-select picker
            // sequence (payer → recipient). Other modes go through
            // the regular multi-select friend picker for split
            // participants first.
            if m == .settleUp {
                pendingSettleUpPayerID = nil
                path.append(.settleUpPayer)
            } else {
                path.append(.friendPicker)
            }
        }
    }

    /// Number of distinct active payers — drives whether re-entry
    /// lands on the compact who-pay (single payer) or the multi
    /// numpad (more than one payer chipped in).
    private var isMultiPayerConfigured: Bool {
        vm.payers.filter { $0.amount > 0.001 }.count > 1
    }

    /// Pre-compute the NavigationStack path for re-entry in
    /// `.specificStep` mode. Pure / static so it runs in `init`
    /// before the first render — eliminates the original "always
    /// flashes mode picker" bug that came from doing this seeding
    /// via `.onAppear` (the empty default path rendered first).
    ///
    /// The mode picker stays at index -1 (root) so swipe-back from
    /// the seeded step always lands there, letting the user switch
    /// modes mid-edit. Concrete focal step per mode is documented
    /// inline below.
    static func computeInitialPath(
        startStep: StartStep,
        vm: CreateTransactionViewModel
    ) -> [Step] {
        guard startStep == .specificStep else { return [] }
        // Mode resolution: prefer the explicitly-set `splitMode`.
        // When the user is in split mode but the mode field is nil
        // (legacy data, or a mid-flight state from before the mode
        // was committed), fall back to whatever `resolvedSplitMode`
        // would default to so seeding still works — this was the
        // root cause of the "I have to pick my mode once before
        // re-entry behaves" report.
        let mode: SplitMode
        if let explicit = vm.splitMode {
            mode = explicit
        } else if vm.isSplitMode {
            mode = vm.resolvedSplitMode()
        } else {
            return []
        }

        switch mode {
        case .evenly:
            // Re-entering an existing evenly split lands on the
            // friend picker — same as every other mode's re-entry
            // shape, which is what the user expects when tapping the
            // chip / subtitle. Earlier the non-multi branch went
            // straight to `.whoPay` on the premise that "who paid the
            // bill" was the most common edit intent, but that broke
            // the mental model: evenly was the only mode that skipped
            // the "who's in the split" step on re-entry, and the user
            // reported it as inconsistent (the multi-payer branch
            // already landed on the friend picker, which the user
            // flagged as the correct behaviour). Save on the friend
            // picker pushes the next step normally — `.whoPay` for
            // the single-payer case, or the multi numpad via the
            // multi-in-flight branch in `pushAfterFriendPicker` when
            // multiple payers are configured.
            return [.friendPicker]
        case .byAmount:
            // Calculations is the focal point — the user tapped
            // because they want to fix shares, not swap participants.
            // They can still swipe back through the friend picker →
            // mode picker if they need to.
            return [.friendPicker, .calculations]
        case .byItems:
            // Three re-entry shapes documented in the original
            // imperative version — preserved here verbatim:
            //
            // - byItems committed but items vanished → user nuked
            //   them via the items badge after configuring the mode,
            //   or restored a transaction whose receipt rows didn't
            //   migrate. Land on `.scanSource` so the unified scan
            //   flow rebuilds the items list.
            //
            // - No friends picked yet → fresh post-scan entry.
            //   Drop the user on the friend picker so they walk the
            //   natural forward flow.
            //
            // - Friends + assignments already present →
            //   repeat-entry to verify per-person numbers. Seed all
            //   the way to review.
            //
            // - Friends but no assignments → seed up to
            //   `.itemAssignment(0)` so the user re-walks.
            if vm.pendingReceiptItems.isEmpty {
                return [.scanSource]
            } else if vm.selectedFriends.isEmpty {
                return [.friendPicker]
            } else {
                let participantCount =
                    (vm.youIncludedInSplit ? 1 : 0) + vm.selectedFriends.count
                var seeded: [Step] = [.friendPicker]
                if vm.byItemsHasAssignments {
                    for index in 0..<participantCount {
                        seeded.append(.itemAssignment(index))
                    }
                    seeded.append(.itemAssignmentReview)
                } else {
                    seeded.append(.itemAssignment(0))
                }
                return seeded
            }
        case .settleUp:
            // Re-entering an already-configured settle-up lands on
            // **Who pays** first; the recipient step is pushed only
            // after the user confirms the payer. The
            // `pendingSettleUpPayerID` carry-over for swipe-back-and-
            // forward is set in `.onAppear` since it's a `@State`
            // mutation that can't live in `init`.
            return [.settleUpPayer]
        }
    }

    /// Captures the VM's current state into `initialVMSnapshot` the
    /// first time the sheet appears. Guarded on `nil` so re-firing
    /// `.onAppear` (backgrounding + resuming) can't overwrite the
    /// original capture with an already-mutated in-flight state.
    private func captureVMSnapshotIfNeeded() {
        guard initialVMSnapshot == nil else { return }
        initialVMSnapshot = VMSnapshot(
            splitMode: vm.splitMode,
            isSplitMode: vm.isSplitMode,
            selectedFriends: vm.selectedFriends,
            youIncludedInSplit: vm.youIncludedInSplit,
            byAmountShares: vm.byAmountShares,
            payers: vm.payers
        )
    }

    /// `.onDisappear` companion to the snapshot capture. Writes every
    /// snapshot field back to the VM IF `completeFlow()` didn't run —
    /// which covers every "user abandoned mid-flow" path: chevron
    /// back at the mode picker, native swipe-down at root, scan-flow
    /// Cancel, the X close button on the scan step. Real completions
    /// (`completeFlow()`) set `didCompleteFlow = true` first so the
    /// restore short-circuits and the new state survives the
    /// dismissal.
    private func restoreVMSnapshotIfNotCommitted() {
        guard !didCompleteFlow, let snapshot = initialVMSnapshot else { return }
        vm.splitMode = snapshot.splitMode
        vm.isSplitMode = snapshot.isSplitMode
        vm.selectedFriends = snapshot.selectedFriends
        vm.youIncludedInSplit = snapshot.youIncludedInSplit
        vm.byAmountShares = snapshot.byAmountShares
        vm.payers = snapshot.payers
    }

    /// `.onAppear` companion to `computeInitialPath`. The static path
    /// computation can't write to view `@State` properties other
    /// than `path` itself, so the two side-effects that ALSO needed
    /// to fire on re-entry (settle-up payer prefill + byItems
    /// selections hydration) get applied here. Idempotent — guards
    /// keep it safe even though `.onAppear` may fire more than once
    /// during a sheet's lifetime (e.g. backgrounding the app and
    /// resuming).
    private func seedByItemsSelectionsForReentryIfNeeded() {
        guard startStep == .specificStep else { return }
        let mode = vm.splitMode ?? (vm.isSplitMode ? vm.resolvedSplitMode() : nil)
        switch mode {
        case .settleUp:
            if pendingSettleUpPayerID == nil {
                pendingSettleUpPayerID = vm.payers.first?.id
            }
        case .byItems:
            if !vm.pendingReceiptItems.isEmpty && !vm.selectedFriends.isEmpty {
                seedByItemsSelections()
            }
        case .evenly, .byAmount, .none:
            break
        }
    }
}

// MARK: - Mode picker step

/// Step 0 of the orchestrator. Lists the four split modes plus the
/// "Pay for yourself" exit (which dismisses the flow entirely and
/// wipes any in-progress split state on the VM). Renders inline as a
/// pushable view rather than a sheet detent — the sheet wrapping is
/// the orchestrator's job, not this view's.
struct ModePickerStep: View {
    let selectedMode: SplitMode?
    let hasUsableReceipt: Bool
    let amount: Double
    let currency: String
    let onSelect: (Choice) -> Void

    /// Tap result. `payForYourself` is a sentinel because the option
    /// isn't a `SplitMode` case (split is OFF when picked); using a
    /// dedicated case keeps the call site exhaustive without leaking
    /// "off" semantics back into the enum.
    enum Choice {
        case payForYourself
        case splitMode(SplitMode)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, AppSpacing.xxl)
                VStack(spacing: AppSpacing.xs) {
                    payForYourselfRow
                    ForEach(SplitMode.allCases) { mode in
                        splitModeRow(mode)
                    }
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            // Same 48pt back-button → title gap the other orchestrator
            // steps use (FriendPickerContent's header listRowInsets).
            .padding(.top, 48)
        }
        .background(AppColors.backgroundPrimary)
    }

    /// Single-line title with the amount embedded inline. Same 32pt
    /// bold weight the other orchestrator headers use. The amount
    /// block ("1 030.24 USD") is glued together with non-breaking
    /// spaces so the line-wrapper can only break the title BEFORE or
    /// AFTER it, never mid-amount — without this, a long figure
    /// could end up with the integer part on one line and the
    /// decimals + currency on the next.
    private var header: some View {
        Text(headerTitleText)
            .font(.system(size: 32, weight: .bold))
            .foregroundColor(AppColors.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var headerTitleText: String {
        guard amount > 0.001 else {
            return "How to track this expense?"
        }
        let nbsp = "\u{00A0}"
        // Group separator from `NumberFormatting.integerPart` is a
        // regular space ("1 030"); swap it for NBSP so the wrapper
        // sees the integer as one unbreakable run.
        let integer = NumberFormatting.integerPart(amount)
            .replacingOccurrences(of: " ", with: nbsp)
        let decimal = NumberFormatting.decimalPartIfAny(amount)
        let amountBlock = "\(integer)\(decimal)\(nbsp)\(currency)"
        return "How to track this \(amountBlock) expense?"
    }

    private var payForYourselfRow: some View {
        Button {
            onSelect(.payForYourself)
        } label: {
            HStack(spacing: 14) {
                // Muted "no-split" affordance — sits on the subtle
                // `backgroundElevated` surface with a tertiary-tinted
                // glyph instead of the bright white-on-gray of the
                // four `SplitMode` icons. Pay-for-yourself is the
                // dormant default option, so it shouldn't read as
                // colourful as the active modes below.
                Image(systemName: "person.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppColors.textTertiary)
                    .frame(width: 36, height: 36)
                    .background(AppColors.backgroundElevated)
                    .clipShape(Circle())

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text("Pay for yourself")
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                    Text("Your expense")
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                }
                Spacer()

                if selectedMode == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppFonts.iconLarge)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, AppSpacing.rowVertical)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func splitModeRow(_ mode: SplitMode) -> some View {
        Button {
            onSelect(.splitMode(mode))
        } label: {
            HStack(spacing: 14) {
                SplitModeIcon(mode: mode, size: 36)

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(displayLabel(for: mode))
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                    Text(helpText(for: mode))
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                }
                Spacer()

                if selectedMode == mode {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppFonts.iconLarge)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, AppSpacing.rowVertical)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func displayLabel(for mode: SplitMode) -> String {
        // Picker-local labels — leading "Split" verb pins each row
        // to the same action category so the four options read as
        // siblings ("Split evenly / Split by items / Split by amount /
        // Settle up"). The global `mode.displayLabel` stays "Evenly"
        // / "By amount" / etc. because that's the noun form other
        // surfaces want (transaction detail chip, friend filters,
        // share-distribution legend) — only the mode picker frames
        // the choice as a verb. Settle-up keeps its existing label
        // since it's already an imperative.
        switch mode {
        case .evenly:   return "Split evenly"
        case .byItems:  return "Split by items in receipt"
        case .byAmount: return "Split by amount"
        case .settleUp: return mode.displayLabel
        }
    }

    private func helpText(for mode: SplitMode) -> String {
        if mode == .byItems && !hasUsableReceipt {
            return "Scan a receipt to assign items"
        }
        return mode.helpText
    }
}


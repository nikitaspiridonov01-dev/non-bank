import SwiftUI
import UserNotifications

struct MainTabView: View {
    // Data stores live at the app root now — `non_bankApp` owns the
    // single `@StateObject` instances and pushes them down via
    // `@EnvironmentObject`. Lifting them out of this view was needed
    // so the splash-stage `OnboardingView` (which sits above the tab
    // bar in `RootView`) can resolve the same stores the main app
    // sees.
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var syncManager: SyncManager
    @EnvironmentObject var notificationCoordinator: NotificationCoordinator
    @EnvironmentObject var shareLinkCoordinator: ShareLinkCoordinator
    @Environment(\.scenePhase) private var scenePhase

    /// Timer that fires every 60s to check for new recurring spawns
    @State private var spawnTimer: Timer?
    /// Transaction whose notification was tapped — drives the detail sheet
    /// that opens out of any tab.
    @State private var notificationOpenedTransaction: Transaction?
    /// Transaction that was just created or matched from an incoming
    /// share link. Drives a detail sheet so the user lands directly on
    /// the imported (or already-imported) transaction after the share-
    /// link flow completes.
    @State private var shareLinkOpenedTransaction: Transaction?

    var body: some View {
        ZStack(alignment: .bottom) {
            // HomeView is always kept in the view tree and just hidden
            // via opacity / hit-testing when the Settings tab is up.
            // The previous `if router.selectedTab == 0` discard reset
            // the home scroll offset every time the user popped into
            // Settings and back — `ScrollView` state lives in the view
            // tree, so destroying the tree throws the position away.
            // SettingsView, on the other hand, is rebuilt on entry
            // (no expensive scroll state to preserve, and we want its
            // `.onAppear` hooks — display name reload, sync availability
            // check — to re-run each visit).
            ZStack {
                HomeView()
                    .environmentObject(transactionStore)
                    .environmentObject(categoryStore)
                    .environmentObject(friendStore)
                    .environmentObject(receiptItemStore)
                    .opacity(router.selectedTab == 0 ? 1 : 0)
                    .allowsHitTesting(router.selectedTab == 0)

                if router.selectedTab == 1 {
                    SettingsView()
                        .environmentObject(transactionStore)
                        .environmentObject(categoryStore)
                        .environmentObject(friendStore)
                        .environmentObject(receiptItemStore)
                }
            }
            // Кастомный нижний бар
            if !router.hideTabBar {
            HStack {
                Spacer()
                // Home Tab.
                // Inactive tint uses `textSecondary` (not the warm-grey
                // `iconInactive`) because the latter sits at ~3.2:1
                // against the cream page — readable but easy to miss
                // for a user double-tapping the already-active tab.
                // `textSecondary` lands at ~5.5:1 and reads as
                // "current vs other" distinctly.
                Button(action: { router.selectedTab = 0 }) {
                    VStack(spacing: AppSpacing.xs) {
                        Image(systemName: "house.fill")
                            .font(AppFonts.tabIcon)
                            .foregroundColor(router.selectedTab == 0 ? AppColors.accent : AppColors.textSecondary)
                        Text("Home")
                            .font(AppFonts.tabLabel)
                            .foregroundColor(router.selectedTab == 0 ? AppColors.accent : AppColors.textSecondary)
                    }
                }
                .accessibilityLabel("Home tab")
                .accessibilityAddTraits(router.selectedTab == 0 ? .isSelected : [])
                Spacer(minLength: AppSizes.tabBarCenterSpacing)
                // Центральная кнопка — black-pill CTA с native iOS 26
                // Liquid Glass поверх. `ctaSurface` инвертируется
                // (чёрная в Light / белая в Dark), foreground — наоборот.
                Button(action: { router.showCreateTransaction() }) {
                    Image(systemName: "plus")
                        .font(AppFonts.fabIcon)
                        .foregroundColor(AppColors.ctaForeground)
                        .frame(width: AppSizes.fabSize, height: AppSizes.fabSize)
                        .background(AppColors.ctaSurface, in: .circle)
                        .glassEffect(.regular, in: .circle)
                }
                .offset(y: AppSizes.fabOffset)
                .accessibilityLabel("Add transaction")
                .accessibilityHint("Opens the create-transaction form")
                Spacer(minLength: AppSizes.tabBarCenterSpacing)

                // Profile Tab. Same `textSecondary` inactive tint as
                // the Home tab — see comment above.
                Button(action: { router.selectedTab = 1 }) {
                    VStack(spacing: AppSpacing.xs) {
                        Image(systemName: "person.crop.circle")
                            .font(AppFonts.tabIcon)
                            .foregroundColor(router.selectedTab == 1 ? Color.accentColor : AppColors.textSecondary)
                        Text("Profile")
                            .font(AppFonts.tabLabel)
                            .foregroundColor(router.selectedTab == 1 ? Color.accentColor : AppColors.textSecondary)
                    }
                }
                .accessibilityLabel("Profile tab")
                .accessibilityAddTraits(router.selectedTab == 1 ? .isSelected : [])
                Spacer()
            }
            .padding(.horizontal, AppSizes.tabBarHorizontalPadding)
            .padding(.bottom, AppSizes.tabBarBottomPadding)
            .background(
                ZStack(alignment: .top) {
                    // Adaptive blur material (no forced dark scheme)
                    Color.clear
                        .background(.bar)
                    // Adaptive overlay (clear on light, dim on dark via token)
                    AppColors.backgroundOverlay
                    // Subtle top divider for light mode definition
                    Divider().background(AppColors.border)
                }
                .ignoresSafeArea(edges: .bottom)
            )
            } // end if !router.hideTabBar
        }
        .ignoresSafeArea(.keyboard)
        .sheet(isPresented: $router.showTransactionEditor, onDismiss: {
            router.dismissTransactionEditor()
        }) {
            CreateTransactionModal(
                editingTransaction: router.editingTransaction,
                autoOpenSplitFlow: router.autoOpenSplitFlow,
                autoOpenScanFlow: router.autoOpenScanFlow,
                autoSplitByItems: router.autoSplitByItems,
                prefilledFriendIDs: router.prefilledFriendIDs
            )
            .environmentObject(categoryStore)
            .environmentObject(transactionStore)
            .environmentObject(currencyStore)
            .environmentObject(friendStore)
            .environmentObject(receiptItemStore)
        }
        // Post-create share prompt for split transactions. Driven by
        // `router.pendingSplitShareSyncID` so the trigger is decoupled
        // from the create modal's own dismiss animation. We resolve
        // the transaction from the store at present-time so the sheet
        // always sees the latest version (any post-save tweak —
        // recurring spawn, sync update — flows in).
        .sheet(
            isPresented: Binding(
                get: { router.pendingSplitShareSyncID != nil },
                set: { if !$0 { router.dismissSplitSharePrompt() } }
            ),
            onDismiss: { router.dismissSplitSharePrompt() }
        ) {
            if let syncID = router.pendingSplitShareSyncID,
               let tx = transactionStore.transactions.first(where: { $0.syncID == syncID }) {
                ShareSplitPromptSheet(transaction: tx)
                    .environmentObject(categoryStore)
                    .environmentObject(friendStore)
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.visible)
                // Background is set on the sheet itself
                // (`AppColors.backgroundPrimary`) to match the rest of
                // the sheet family — CategoriesSheetView,
                // CurrencyRatesSheet, the create-transaction modal
                // all use that token. The previous
                // `.presentationBackground(.regularMaterial)` here
                // produced a flat translucent-grey card that read as
                // an odd one out.
            }
        }
        .sheet(item: $notificationOpenedTransaction) { tx in
            // Prefer the freshest version from the store — the snapshot we
            // matched by syncID could have stale fields if the user edited
            // while the notification was being processed. Resolve by
            // `syncID` (not `id`) so Replace-reminder, which rotates the
            // autoincrement id, doesn't strand this sheet on a deleted row.
            // Falls back to the bound `tx` so the sheet never renders an
            // empty body (which appears as a blank gray sheet) if the
            // store hasn't reloaded yet.
            let fresh = transactionStore.transactions.first(where: { $0.syncID == tx.syncID }) ?? tx
            TransactionDetailView(
                transaction: fresh,
                onEdit: {
                    let txToEdit = fresh
                    notificationOpenedTransaction = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        router.showEditTransaction(txToEdit)
                    }
                },
                onDelete: {
                    transactionStore.delete(id: fresh.id)
                    notificationOpenedTransaction = nil
                },
                onClose: { notificationOpenedTransaction = nil },
                source: fresh.isSplit ? .debts : .home
            )
            .environmentObject(categoryStore)
            .environmentObject(transactionStore)
            .environmentObject(friendStore)
            .environmentObject(currencyStore)
            .environmentObject(receiptItemStore)
        }
        .onChange(of: notificationCoordinator.pendingTransactionSyncID) { _ in
            handlePendingNotification()
        }
        .onChange(of: transactionStore.transactions.count) { _ in
            // Keep the receipt-item cache in sync with deletions / cascading
            // wipes that happen through TransactionStore. The store does the
            // SQL delete itself; we just need to refresh the in-memory copy.
            Task { await receiptItemStore.load() }
            // Cold-start case: the notification arrived before transactions
            // finished loading. Re-attempt the lookup whenever the store's
            // contents change so the card eventually pops open.
            handlePendingNotification()
        }
        .onAppear {
            if SyncManager.isCloudKitEnabled {
                syncManager.transactionStore = transactionStore
                syncManager.categoryStore = categoryStore
                syncManager.friendStore = friendStore
                syncManager.receiptItemStore = receiptItemStore
                transactionStore.syncManager = syncManager
                categoryStore.syncManager = syncManager
                friendStore.syncManager = syncManager
                receiptItemStore.syncManager = syncManager
                // ReceiptItem rows only carry the parent's local
                // autoincrement id; CloudKit pushes need the stable
                // syncID. The lookup reads off the in-memory
                // transaction store so it stays cheap.
                receiptItemStore.transactionSyncIDLookup = { [weak transactionStore] id in
                    transactionStore?.transactions.first(where: { $0.id == id })?.syncID
                }
                Task { await syncManager.syncIfEnabled() }
            }
            requestNotificationPermission()
            startSpawnTimer()
        }
        .onDisappear {
            spawnTimer?.invalidate()
            spawnTimer = nil
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                if SyncManager.isCloudKitEnabled {
                    Task { await syncManager.syncIfEnabled() }
                }
                // Check for new spawns every time the app becomes active
                transactionStore.processRecurringSpawns()
                startSpawnTimer()
            } else if newPhase == .background {
                spawnTimer?.invalidate()
                spawnTimer = nil
            }
        }
        // ─── Share-link routing ─────────────────────────────────────
        // `.onOpenURL` on the app root fires very early — typically
        // while `RootView` is still on the splash screen (1.5 s) and
        // MainTabView hasn't mounted yet. A plain `.onChange(of:
        // pendingPayload)` observer would miss this because SwiftUI's
        // `onChange` only fires on subsequent transitions, never on
        // the initial value at attach time. Friends opening a link
        // from a cold start would see the app launch but the
        // transaction would never save.
        //
        // `.task(id:)` covers both cases:
        //   • On mount, runs the body with the current `pendingPayload.id`
        //     — catches cold-start where the payload was already parked.
        //   • Re-runs when the id rotates — covers warm-start re-taps
        //     and a second link arriving while one is mid-route.
        //
        // The body waits for `transactionStore.hasLoadedOnce` before
        // classifying so the receiver's full history is in scope. A
        // cold-start re-import of an already-known `syncID` would
        // otherwise misclassify as "new create" and duplicate the row.
        .task(id: shareLinkCoordinator.pendingPayload?.id) {
            guard shareLinkCoordinator.pendingPayload != nil else { return }
            while !transactionStore.hasLoadedOnce {
                try? await Task.sleep(for: .milliseconds(50))
                if Task.isCancelled { return }
            }
            if let payload = shareLinkCoordinator.pendingPayload {
                shareLinkCoordinator.startRouting(payload, in: transactionStore.transactions)
            }
        }
        // React to state-machine transitions:
        //  - `autoPickIndex` set → classifier identified the receiver
        //    (single-participant or matched by ID). Skip the picker UI
        //    and commit immediately.
        //  - `.completed` / `.identical` → present the resulting
        //    transaction's detail sheet, then reset.
        .onChange(of: shareLinkCoordinator.routingState) { state in
            switch state {
            case .showingPicker(let payload, let isUpdate, let existingID, let autoPickIndex)
                where autoPickIndex != nil:
                Task {
                    await shareLinkCoordinator.pickedParticipant(
                        index: autoPickIndex!,
                        payload: payload,
                        existingID: existingID,
                        isUpdate: isUpdate,
                        transactionStore: transactionStore,
                        friendStore: friendStore,
                        categoryStore: categoryStore,
                        receiptItemStore: receiptItemStore
                    )
                }
            case .completed(let txSyncID, _), .identical(let txSyncID):
                // `syncID` lookup (instead of the previous `id` /
                // SQLite-autoincrement) survives Replace-reminder
                // flows that rotate the int id, AND survives the
                // staleness window between a write and the next
                // `load()` cycle — `syncID` is set on the in-memory
                // record at insert/update time, so it's already
                // queryable even before the followup `load()` would
                // refresh anything else.
                if let tx = transactionStore.transactions.first(where: { $0.syncID == txSyncID }) {
                    shareLinkOpenedTransaction = tx
                }
                shareLinkCoordinator.reset()
            default:
                break
            }
        }
        // Picker sheet (multi-participant case, no ID match). Driven by
        // a derived Bool binding on the routing state so dismiss-from-
        // system (drag-to-close) routes back through `reset()`.
        .sheet(isPresented: shareLinkPickerBinding) {
            if case .showingPicker(let payload, let isUpdate, let existingID, _) = shareLinkCoordinator.routingState {
                WhoAreYouPickerView(
                    payload: payload,
                    isForUpdate: isUpdate,
                    onPick: { index in
                        Task {
                            await shareLinkCoordinator.pickedParticipant(
                                index: index,
                                payload: payload,
                                existingID: existingID,
                                isUpdate: isUpdate,
                                transactionStore: transactionStore,
                                friendStore: friendStore,
                                categoryStore: categoryStore,
                                receiptItemStore: receiptItemStore
                            )
                        }
                    },
                    onCancel: { shareLinkCoordinator.reset() }
                )
            }
        }
        // "Friend wants to update this transaction" alert — fires when
        // the same `syncID` is re-imported with different content.
        .alert("Update transaction?", isPresented: shareLinkUpdateAlertBinding) {
            Button("Cancel", role: .cancel) { shareLinkCoordinator.reset() }
            Button("Update") {
                if case .showingUpdateAlert(let payload, let existingID, let knownIdx) = shareLinkCoordinator.routingState {
                    Task {
                        await shareLinkCoordinator.confirmedUpdate(
                            payload: payload,
                            existingID: existingID,
                            knownParticipantIndex: knownIdx,
                            transactionStore: transactionStore,
                            friendStore: friendStore,
                            categoryStore: categoryStore,
                            receiptItemStore: receiptItemStore
                        )
                    }
                }
            }
        } message: {
            Text("Your friend re-shared this transaction with different details. Update your copy to match?")
        }
        // Decode/insert error — shows once per failure.
        .alert("Couldn't open share link", isPresented: shareLinkErrorBinding) {
            Button("OK", role: .cancel) { shareLinkCoordinator.reset() }
        } message: {
            if case .errored(let error) = shareLinkCoordinator.routingState {
                Text(error.localizedDescription)
            } else {
                Text("Unknown error.")
            }
        }
        // Detail sheet for the just-created / matched transaction. Same
        // pattern as `notificationOpenedTransaction` — resolve by
        // `syncID` so Replace-reminder doesn't break this binding.
        .sheet(item: $shareLinkOpenedTransaction) { tx in
            // Fall back to the bound `tx` so the sheet never renders an
            // empty body if the store hasn't reloaded yet (same defensive
            // pattern as `notificationOpenedTransaction`).
            let fresh = transactionStore.transactions.first(where: { $0.syncID == tx.syncID }) ?? tx
            TransactionDetailView(
                transaction: fresh,
                onEdit: {
                    let txToEdit = fresh
                    shareLinkOpenedTransaction = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        router.showEditTransaction(txToEdit)
                    }
                },
                onDelete: {
                    transactionStore.delete(id: fresh.id)
                    shareLinkOpenedTransaction = nil
                },
                onClose: { shareLinkOpenedTransaction = nil },
                source: fresh.isSplit ? .debts : .home
            )
            .environmentObject(categoryStore)
            .environmentObject(transactionStore)
            .environmentObject(friendStore)
            .environmentObject(currencyStore)
            .environmentObject(receiptItemStore)
        }
    }

    // MARK: - Share-link bindings

    /// True while routing wants the picker sheet up. Setter routes
    /// dismiss back through `reset()` so SwiftUI's drag-to-close gesture
    /// doesn't leave the state machine stuck in `.showingPicker`.
    ///
    /// Only fires when the classifier said "we don't know who the
    /// receiver is" (`autoPickIndex == nil`). The auto-pick path goes
    /// through `.onChange(of: routingState)` and never renders the
    /// sheet.
    private var shareLinkPickerBinding: Binding<Bool> {
        Binding(
            get: {
                if case .showingPicker(_, _, _, let autoIdx) = shareLinkCoordinator.routingState,
                   autoIdx == nil { return true }
                return false
            },
            set: { isPresented in
                if !isPresented { shareLinkCoordinator.reset() }
            }
        )
    }

    private var shareLinkUpdateAlertBinding: Binding<Bool> {
        Binding(
            get: {
                if case .showingUpdateAlert = shareLinkCoordinator.routingState { return true }
                return false
            },
            set: { isPresented in
                if !isPresented { shareLinkCoordinator.reset() }
            }
        )
    }

    private var shareLinkErrorBinding: Binding<Bool> {
        Binding(
            get: {
                if case .errored = shareLinkCoordinator.routingState { return true }
                return false
            },
            set: { isPresented in
                if !isPresented { shareLinkCoordinator.reset() }
            }
        )
    }

    // MARK: - Recurring Spawn Timer

    private func startSpawnTimer() {
        spawnTimer?.invalidate()
        spawnTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in
                // Scheduled `UNCalendarNotificationTrigger`s (see
                // NotificationService) already deliver per-occurrence alerts
                // on time — no need for a duplicate in-foreground notification
                // when catching up spawns.
                transactionStore.processRecurringSpawns()
            }
        }
    }

    // MARK: - Local Notifications

    private func requestNotificationPermission() {
        NotificationService.requestAuthorization()
    }

    /// Resolves the transaction the user tapped on a notification and opens
    /// its detail sheet — split transactions get the debts-style card, others
    /// the standard home card.
    private func handlePendingNotification() {
        guard let syncID = notificationCoordinator.pendingTransactionSyncID,
              let tx = transactionStore.transactions.first(where: { $0.syncID == syncID })
        else { return }
        // Hop to the home tab so the underlying context matches the card.
        router.selectedTab = 0
        notificationOpenedTransaction = tx
        notificationCoordinator.consumePendingTransaction()
    }
}

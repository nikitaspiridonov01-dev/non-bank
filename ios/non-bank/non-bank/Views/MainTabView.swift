import SwiftUI
import UserNotifications

struct MainTabView: View {
    @StateObject private var transactionStore = TransactionStore()
    @StateObject private var categoryStore = CategoryStore(defaults: CategoryStore.defaultCategories)
    @StateObject private var friendStore = FriendStore()
    @StateObject private var receiptItemStore = ReceiptItemStore()
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
            Group {
                if router.selectedTab == 0 {
                    HomeView()
                        .environmentObject(transactionStore)
                        .environmentObject(categoryStore)
                        .environmentObject(friendStore)
                        .environmentObject(receiptItemStore)
                } else if router.selectedTab == 1 {
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
                // Home Tab
                Button(action: { router.selectedTab = 0 }) {
                    VStack(spacing: AppSpacing.xs) {
                        Image(systemName: "house.fill")
                            .font(AppFonts.tabIcon)
                            .foregroundColor(router.selectedTab == 0 ? Color.accentColor : Color.secondary)
                        Text("Home")
                            .font(AppFonts.tabLabel)
                            .foregroundColor(router.selectedTab == 0 ? Color.accentColor : Color.secondary)
                    }
                }
                Spacer(minLength: AppSizes.tabBarCenterSpacing)
                // Центральная кнопка
                Button(action: { router.showCreateTransaction() }) {
                    ZStack {
                        LinearGradient(
                            gradient: Gradient(colors: [AppColors.accentGradientTop, AppColors.accentGradientBottom]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(width: AppSizes.fabSize, height: AppSizes.fabSize)
                        .shadow(color: AppColors.accentShadow, radius: 14, y: 8)
                        .cornerRadius(AppRadius.fab)
                        
                        Image(systemName: "plus")
                            .font(AppFonts.fabIcon)
                            .foregroundColor(AppColors.textOnAccent)
                    }
                }
                .offset(y: AppSizes.fabOffset)
                Spacer(minLength: AppSizes.tabBarCenterSpacing)
                
                // Profile Tab
                Button(action: { router.selectedTab = 1 }) {
                    VStack(spacing: AppSpacing.xs) {
                        Image(systemName: "person.crop.circle")
                            .font(AppFonts.tabIcon)
                            .foregroundColor(router.selectedTab == 1 ? Color.accentColor : Color.secondary)
                        Text("Profile")
                            .font(AppFonts.tabLabel)
                            .foregroundColor(router.selectedTab == 1 ? Color.accentColor : Color.secondary)
                    }
                }
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
                isPresented: $router.showTransactionEditor,
                editingTransaction: router.editingTransaction
            )
            .environmentObject(categoryStore)
            .environmentObject(transactionStore)
            .environmentObject(currencyStore)
            .environmentObject(friendStore)
            .environmentObject(receiptItemStore)
        }
        .sheet(item: $notificationOpenedTransaction) { tx in
            // Use the freshest version from the store — the snapshot we
            // matched by syncID could have stale fields if the user edited
            // while the notification was being processed. Resolve by
            // `syncID` (not `id`) so Replace-reminder, which rotates the
            // autoincrement id, doesn't strand this sheet on a deleted row.
            if let fresh = transactionStore.transactions.first(where: { $0.syncID == tx.syncID }) {
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
                transactionStore.syncManager = syncManager
                categoryStore.syncManager = syncManager
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
        // Coordinator parks decoded payloads in `pendingPayload`. When
        // the transaction store finishes loading (so we have data to
        // classify against), kick off routing.
        .onChange(of: shareLinkCoordinator.pendingPayload) { newValue in
            if let payload = newValue {
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
                        categoryStore: categoryStore
                    )
                }
            case .completed(let txID, _), .identical(let txID):
                if let tx = transactionStore.transactions.first(where: { $0.id == txID }) {
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
                                categoryStore: categoryStore
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
                            categoryStore: categoryStore
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
            if let fresh = transactionStore.transactions.first(where: { $0.syncID == tx.syncID }) {
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

import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @State private var showCurrencyRatesSheet = false
    @State private var showCategoriesSheet = false

    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var router: NavigationRouter
    @EnvironmentObject var syncManager: SyncManager

    @State private var isImportActive = false
    @State private var showSyncError = false
    @State private var syncErrorMessage = ""
    @State private var idCopied = false
    /// Display name visible to recipients of share-links. Loaded from
    /// `UserProfileService` on appear; updated whenever the
    /// `ProfileNameSheet` saves a new value.
    @State private var displayName: String = ""
    /// Drives the `ProfileNameSheet` for editing the display name —
    /// reusing the same big-text input UI as `FriendFormView` so the
    /// two flows feel consistent.
    @State private var showProfileNameSheet: Bool = false

    private let userID = UserIDService.currentID()

    var body: some View {
        NavigationView {
            List {
                // Profile avatar header
                Section {
                    VStack(spacing: AppSpacing.md) {
                        PixelCatFillView(id: userID, blackAndWhite: false, cornerRadius: AppRadius.large)

                        Button(action: {
                            UIPasteboard.general.string = userID
                            idCopied = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                idCopied = false
                            }
                        }) {
                            HStack(spacing: 6) {
                                Text(userID)
                                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                                    .foregroundColor(AppColors.textSecondary)
                                Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                                    .font(.system(size: 12))
                                    .foregroundColor(idCopied ? .green : AppColors.textTertiary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, AppSpacing.rowVertical)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                // Display name. Visible to recipients of share-links as
                // the friend's name in their app — falls back to the
                // generic `"Friend"` placeholder if left empty.
                // Tapping this row presents `ProfileNameSheet` (the same
                // big-text input UI used for friend creation), so the
                // two flows feel like the same surface.
                Section {
                    Button {
                        showProfileNameSheet = true
                    } label: {
                        HStack {
                            Label("Your name", systemImage: "person.fill")
                                .foregroundColor(AppColors.textPrimary)
                            Spacer()
                            Text(displayName.isEmpty ? "Not set" : displayName)
                                .foregroundColor(AppColors.textSecondary)
                                .lineLimit(1)
                            Image(systemName: "chevron.right")
                                .font(AppFonts.footnote)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                } footer: {
                    Text("Shown to people you share split transactions with. Leave empty to share as 'Friend'.")
                }

                Section {
                    Picker(selection: $currencyStore.selectedCurrency) {
                        ForEach(currencyStore.currencyOptions, id: \.self) { code in
                            Text("\(CurrencyInfo.byCode[code]?.emoji ?? "💱") \(code)")
                                .tag(code)
                        }
                    } label: {
                        Label("Base Currency", systemImage: "dollarsign.circle")
                    }
                    Button(action: { showCurrencyRatesSheet = true }) {
                        Label("Currencies", systemImage: "coloncurrencysign.circle")
                    }
                    Button(action: { showCategoriesSheet = true }) {
                        Label("Categories", systemImage: "tag")
                    }
                    NavigationLink {
                        FriendsView()
                            .environmentObject(friendStore)
                    } label: {
                        Label("Friends", systemImage: "person.2")
                    }
                }

                if SyncManager.isCloudKitEnabled {
                Section {
                    HStack {
                        Label("iCloud Sync", systemImage: "icloud")
                        Spacer()
                        if syncManager.syncStatus == .syncing {
                            ProgressView()
                                .padding(.trailing, AppSpacing.xs)
                        }
                        Toggle("", isOn: Binding(
                            get: { syncManager.isSyncEnabled },
                            set: { newValue in
                                Task {
                                    if newValue {
                                        await syncManager.checkAvailability()
                                        if syncManager.iCloudAvailable {
                                            await syncManager.enableSync()
                                        } else {
                                            syncErrorMessage = "iCloud is not available. Sign in to iCloud in device Settings."
                                            showSyncError = true
                                        }
                                    } else {
                                        await syncManager.disableSync()
                                    }
                                }
                            }
                        ))
                        .labelsHidden()
                    }
                    if case .lastSynced(let date) = syncManager.syncStatus {
                        HStack {
                            Text("Last synced")
                                .foregroundColor(.secondary)
                            Spacer()
                            Text(date, style: .relative)
                                .foregroundColor(.secondary)
                                .font(.caption)
                        }
                    }
                    if case .error(let msg) = syncManager.syncStatus {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                } header: {
                    Text("Sync")
                }
                } // end if isCloudKitEnabled

                Section {
                    NavigationLink {
                        ExportTransactionsView()
                            .environmentObject(transactionStore)
                    } label: {
                        Label("Export Transactions", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink(isActive: $isImportActive) {
                        ImportTransactionsView(isFlowActive: $isImportActive)
                            .environmentObject(transactionStore)
                            .environmentObject(categoryStore)
                            .environmentObject(currencyStore)
                    } label: {
                        Label("Import Transactions", systemImage: "square.and.arrow.down")
                    }
                }

                // MARK: - Receipt Scanner disabled (feature temporarily removed)
                // Section("Experimental") {
                //     NavigationLink {
                //         DebugReceiptScannerView()
                //     } label: {
                //         Label("Receipt Scanner", systemImage: "doc.text.viewfinder")
                //     }
                // }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .navigationBarHidden(true)
            .safeAreaInset(edge: .bottom) {
                Color.clear.frame(height: 80)
            }
            .onAppear {
                router.hideTabBar = false
                Task { await syncManager.checkAvailability() }
                displayName = UserProfileService.displayName() ?? ""
            }
            .sheet(isPresented: $showProfileNameSheet) {
                ProfileNameSheet(
                    initialName: displayName,
                    title: "Your name",
                    subtitle: "This is shown to people you share split transactions with."
                ) { newName in
                    displayName = newName
                    UserProfileService.setDisplayName(newName)
                }
            }
            .sheet(isPresented: $showCurrencyRatesSheet) {
                CurrencyRatesSheet(isPresented: $showCurrencyRatesSheet)
                    .environmentObject(currencyStore)
            }
            .sheet(isPresented: $showCategoriesSheet) {
                CategoriesSheetView(isPresented: $showCategoriesSheet)
                    .environmentObject(categoryStore)
                    .environmentObject(transactionStore)
            }
            .fullScreenCover(isPresented: $router.showImportSuccess) {
                ImportSuccessScreen(
                    count: router.importedCount,
                    onDone: {
                        router.showImportSuccess = false
                        isImportActive = false
                    }
                )
            }
            .alert("iCloud Unavailable", isPresented: $showSyncError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(syncErrorMessage)
            }
        }
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(SyncManager())
    }
}

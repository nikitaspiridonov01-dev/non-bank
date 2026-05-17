import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @Environment(\.analytics) private var analytics
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
    /// Drives the `InsightsBehaviorSheet` — the modal that lets the
    /// user pick whether splits count by their share or only by what
    /// they paid upfront. Single-source-of-truth toggle lives in
    /// `InsightsSettings.shared`; this state just drives presentation.
    @State private var showInsightsBehaviorSheet: Bool = false

    /// Observed so the "On / Off" status text next to the row in
    /// Settings updates immediately when the user closes the sheet
    /// after flipping the toggle.
    @ObservedObject private var insightsSettings = InsightsSettings.shared

    /// Drives the support-mail sheet. Set when the user taps one of the
    /// rows in the Help & feedback section; cleared when the mail sheet
    /// dismisses. Optional so `.sheet(item:)` only presents when set.
    @State private var pendingMailKind: SupportMail.Kind?
    /// Displayed when the device has no Mail account configured and we
    /// can't fall back to `mailto:` either.
    @State private var mailUnavailableAlert: Bool = false

    /// Observed so the analytics toggle in the Privacy section
    /// re-renders the row state from a single source. Flipping the
    /// `@Published var isEnabled` immediately updates both
    /// `UserDefaults` and the live `AnalyticsService` instance.
    @ObservedObject private var analyticsConsent = AnalyticsConsentService.shared

    private let userID = UserIDService.currentID()

    var body: some View {
        NavigationStack {
            List {
                // Profile avatar header
                Section {
                    VStack(spacing: AppSpacing.sm) {
                        PixelCatView(id: userID, size: 72, blackAndWhite: false)
                            .clipShape(Circle())

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
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.xs)
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
                .listRowBackground(AppColors.backgroundElevated)

                Section {
                    // The "Base Currency" picker that used to live
                    // here was removed in favour of letting the user
                    // change base by tapping a row in the Currencies
                    // sheet (see `CurrencyRatesSheet`). One canonical
                    // entry point — every currency dropdown in the
                    // app routes its "More currencies" overflow to
                    // the same sheet.
                    // Explicit `Label { title } icon: { ... }` so the
                    // title picks up `textPrimary` (high contrast on
                    // cream) while the icon stays accent-tinted —
                    // matches the visual rhythm of the `Friends`
                    // `NavigationLink` row below. Using a plain
                    // `Label("...", systemImage:)` inside a `Button`
                    // tints the entire label with the accent colour,
                    // which on the cream surface dropped contrast on
                    // the text.
                    Button(action: { showCurrencyRatesSheet = true }) {
                        Label {
                            Text("Currencies").foregroundColor(AppColors.textPrimary)
                        } icon: {
                            Image(systemName: "coloncurrencysign.circle").foregroundColor(.accentColor)
                        }
                    }
                    Button(action: { showCategoriesSheet = true }) {
                        Label {
                            Text("Categories").foregroundColor(AppColors.textPrimary)
                        } icon: {
                            Image(systemName: "tag").foregroundColor(.accentColor)
                        }
                    }
                    NavigationLink {
                        FriendsView()
                            .environmentObject(friendStore)
                    } label: {
                        Label("Friends", systemImage: "person.2")
                    }
                }
                .listRowBackground(AppColors.backgroundElevated)

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
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text(date, style: .relative)
                                .foregroundColor(AppColors.textSecondary)
                                .font(.caption)
                        }
                    }
                    if case .error(let msg) = syncManager.syncStatus {
                        Text(msg)
                            .font(.caption)
                            .foregroundColor(AppColors.danger)
                    }
                } header: {
                    Text("Sync")
                }
                .listRowBackground(AppColors.backgroundElevated)
                } // end if isCloudKitEnabled

                Section {
                    NavigationLink {
                        ExportTransactionsView()
                            .environmentObject(transactionStore)
                            .environmentObject(friendStore)
                    } label: {
                        Label("Export Transactions", systemImage: "square.and.arrow.up")
                    }
                    NavigationLink(isActive: $isImportActive) {
                        ImportTransactionsView(isFlowActive: $isImportActive)
                            .environmentObject(transactionStore)
                            .environmentObject(categoryStore)
                            .environmentObject(currencyStore)
                            .environmentObject(friendStore)
                    } label: {
                        Label("Import Transactions", systemImage: "square.and.arrow.down")
                    }
                }
                .listRowBackground(AppColors.backgroundElevated)

                Section {
                    Button(action: { showInsightsBehaviorSheet = true }) {
                        HStack(spacing: 14) {
                            Image(systemName: "chart.bar.xaxis")
                                .foregroundColor(.accentColor)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Potential expenses and debts")
                                    .foregroundColor(AppColors.textPrimary)
                                Text(insightsSettings.includePotentialExpenses
                                     ? "Counted by your share — including what's still owed."
                                     : "Counted only by what actually moved.")
                                    .font(AppFonts.metaText)
                                    .foregroundColor(AppColors.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(AppFonts.footnote)
                                .foregroundColor(AppColors.textTertiary)
                        }
                    }
                } header: {
                    Text("Insights and analytics")
                }
                .listRowBackground(AppColors.backgroundElevated)

                Section {
                    Toggle(isOn: $analyticsConsent.isEnabled) {
                        Label("Share anonymous analytics", systemImage: "chart.bar.doc.horizontal")
                            .foregroundColor(AppColors.textPrimary)
                    }
                } header: {
                    Text("Privacy")
                } footer: {
                    Text("Helps us see which features are useful. No names, no amounts, no IDFA. See Licenses & Privacy for details.")
                        .font(AppFonts.footnote)
                        .foregroundColor(AppColors.textTertiary)
                }
                .listRowBackground(AppColors.backgroundElevated)

                Section {
                    // Tips sit at the top of the section — it's the
                    // most actionable row here (mail buttons require
                    // composing a message; the tip jar just opens). A
                    // user looking to support the app shouldn't have
                    // to scroll past three feedback links to find it.
                    NavigationLink {
                        TipJarView()
                    } label: {
                        Label("Leave a tip", systemImage: "heart.fill")
                            .foregroundColor(AppColors.textPrimary)
                    }
                    ForEach(SupportMail.Kind.allCases) { kind in
                        Button {
                            pendingMailKind = kind
                        } label: {
                            HStack {
                                Label(kind.label, systemImage: kind.systemImage)
                                    .foregroundColor(AppColors.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundColor(AppColors.textTertiary)
                            }
                        }
                    }
                    NavigationLink {
                        LicensesView()
                    } label: {
                        Label("Licenses & Privacy", systemImage: "doc.text")
                            .foregroundColor(AppColors.textPrimary)
                    }
                } header: {
                    Text("Help and feedback")
                }
                .listRowBackground(AppColors.backgroundElevated)
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
                analytics.track(.settingsViewed)
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
            .sheet(isPresented: $showInsightsBehaviorSheet) {
                InsightsBehaviorSheet()
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
            // Mail sheet (or `mailto:` fallback). `item:`-driven so each
            // re-tap re-presents with a fresh composer instead of
            // re-using the prior modal's state.
            .sheet(item: $pendingMailKind) { kind in
                if MailComposeView.canSend {
                    MailComposeView(
                        recipient: SupportMail.address,
                        subject: kind.subject,
                        body: kind.body()
                    )
                    .ignoresSafeArea()
                } else {
                    // Mail.app uninstalled / no account: nudge the user
                    // out to whatever default mail handler is configured
                    // via mailto. If even that fails, surface an alert.
                    Color.clear.onAppear {
                        defer { pendingMailKind = nil }
                        if let url = kind.mailtoURL(), UIApplication.shared.canOpenURL(url) {
                            UIApplication.shared.open(url)
                        } else {
                            mailUnavailableAlert = true
                        }
                    }
                }
            }
            .alert("Mail not available", isPresented: $mailUnavailableAlert) {
                Button("Copy address", role: .none) {
                    UIPasteboard.general.string = SupportMail.address
                }
                Button("Close", role: .cancel) {}
            } message: {
                Text("Set up a Mail account in iOS Settings, or send your message to \(SupportMail.address).")
            }
        }
        .trackScreen("SettingsView")
    }
}

struct SettingsView_Previews: PreviewProvider {
    static var previews: some View {
        SettingsView()
            .environmentObject(SyncManager())
    }
}

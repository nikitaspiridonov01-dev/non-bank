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
                    // `isActive` (not a plain push) so the "friends are now
                    // synced" notification can deep-link straight here: tapping
                    // it from the background sets `router.openFriends`, which
                    // programmatically activates this link. SwiftUI clears the
                    // binding when the user pops back, so it won't re-push.
                    NavigationLink(isActive: $router.openFriends) {
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
                        // No inline ProgressView: the spinner appearing
                        // and disappearing on every foreground sync
                        // reflowed the row and read as a flicker. The
                        // "Last synced" date (below) is the only progress
                        // signal — it just updates in place when a sync
                        // completes, no animation.
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
                    // Driven by the persistent `lastSyncedDate`, NOT the
                    // transient `syncStatus`, so the row stays put (no
                    // appear/disappear flicker) and just refreshes its
                    // date when a sync lands. Gated on `isSyncEnabled`
                    // so a stale date doesn't linger after the user
                    // turns sync off (that toggle is a deliberate
                    // action, not the automatic flicker we fixed).
                    // ALWAYS-VISIBLE status (the date never just disappears now):
                    // a real "Last synced" date once a sync lands, else the live
                    // phase ("Syncing…" / "Not synced yet"). Restore is automatic
                    // (syncIfEnabled does a full zone pull on launch when the
                    // local store is empty), so there's no manual button.
                    if syncManager.isSyncEnabled {
                        HStack {
                            Text("Last synced")
                                .foregroundColor(AppColors.textSecondary)
                            Spacer()
                            Text({
                                if let synced = syncManager.lastSyncedDate {
                                    return synced.formatted(date: .abbreviated, time: .shortened)
                                }
                                if case .syncing = syncManager.syncStatus { return "Syncing…" }
                                return "Not synced yet"
                            }())
                                .foregroundColor(AppColors.textSecondary)
                                .font(.caption)
                        }
                        // What the last full sync pulled/merged from iCloud —
                        // restores the diagnostic that makes a failed restore
                        // visible ("Pulled 0 …" = the zone is empty / nothing was
                        // backed up, vs a real count = data came down).
                        if let diag = syncManager.lastDiagnostic {
                            Text(diag)
                                .font(.caption)
                                .foregroundColor(AppColors.textTertiary)
                        }
                        if case .error(let msg) = syncManager.syncStatus {
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(AppColors.danger)
                        }
                    }
                } header: {
                    Text("Sync")
                } footer: {
                    Text("Backs up your data and keeps it in sync across your devices.")
                        .font(AppFonts.footnote)
                        .foregroundColor(AppColors.textTertiary)
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

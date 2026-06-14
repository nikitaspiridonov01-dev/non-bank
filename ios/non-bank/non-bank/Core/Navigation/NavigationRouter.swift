import SwiftUI
import Combine
import UIKit

/// Centralized navigation state for the app.
///
/// Owns tab selection and app-level sheet presentation (create / edit transaction).
/// Injected as `@EnvironmentObject` from the app root.
@MainActor
final class NavigationRouter: ObservableObject {
    // MARK: - Tab

    @Published var selectedTab: Int = 0
    @Published var hideTabBar: Bool = false

    // MARK: - Create / Edit Transaction Sheet

    @Published var showTransactionEditor: Bool = false
    @Published private(set) var editingTransaction: Transaction? = nil
    /// When true, the create modal auto-opens the split orchestrator
    /// after appearing. Used by friend-scoped CTAs ("Add split with
    /// X") so the user lands directly inside the split flow without
    /// having to find the chip on the modal. Defaults to `false`.
    @Published private(set) var autoOpenSplitFlow: Bool = false
    /// When true, the create modal pops the receipt source picker
    /// (Camera / Photo Library) as soon as the modal finishes its
    /// appear animation. Used by the Home / Debts toolbar scan
    /// buttons so a tap takes the user straight to capturing.
    @Published private(set) var autoOpenScanFlow: Bool = false
    /// When true, the create modal pre-arms `byItems` split mode —
    /// participants from `prefilledFriendIDs` (plus the user) get
    /// selected and the orchestrator opens at the item-assignment
    /// step after the scan finishes. Used by the Debts / Friend
    /// scan-receipt buttons. Defaults to `false`.
    @Published private(set) var autoSplitByItems: Bool = false
    /// Friend IDs to pre-select as split participants when
    /// `autoOpenSplitFlow` or `autoSplitByItems` is true. Empty when
    /// the CTA isn't friend-scoped (e.g. a generic "+ Add split"
    /// empty-state, or the Debts toolbar scan).
    @Published private(set) var prefilledFriendIDs: [String] = []
    /// Receipt image(s) the user already picked or captured BEFORE the
    /// create modal opened (Home scan icon → gallery-first flow). When
    /// non-empty, the modal skips the source picker and parses these
    /// immediately, so the gallery shows first and the create screen
    /// appears only after parsing. Transient: cleared on dismiss.
    @Published private(set) var pendingScanImages: [UIImage] = []

    func showCreateTransaction(
        autoOpenSplitFlow: Bool = false,
        autoOpenScanFlow: Bool = false,
        autoSplitByItems: Bool = false,
        prefilledFriendIDs: [String] = [],
        pendingScanImages: [UIImage] = []
    ) {
        editingTransaction = nil
        self.autoOpenSplitFlow = autoOpenSplitFlow
        self.autoOpenScanFlow = autoOpenScanFlow
        self.autoSplitByItems = autoSplitByItems
        self.prefilledFriendIDs = prefilledFriendIDs
        self.pendingScanImages = pendingScanImages
        showTransactionEditor = true
    }

    func showEditTransaction(_ transaction: Transaction) {
        editingTransaction = transaction
        autoOpenSplitFlow = false
        autoOpenScanFlow = false
        autoSplitByItems = false
        prefilledFriendIDs = []
        pendingScanImages = []
        showTransactionEditor = true
    }

    func dismissTransactionEditor() {
        showTransactionEditor = false
        editingTransaction = nil
        autoOpenSplitFlow = false
        autoOpenScanFlow = false
        autoSplitByItems = false
        prefilledFriendIDs = []
        pendingScanImages = []
    }

    // MARK: - Import Success

    @Published var showImportSuccess: Bool = false
    @Published var importedCount: Int = 0

    func showImportComplete(count: Int) {
        importedCount = count
        showImportSuccess = true
    }

    // MARK: - Split share prompt

    /// `syncID` of a freshly-created split transaction that the user
    /// hasn't been prompted to share yet. Set when `CreateTransactionModal`
    /// saves a new split row; observed by `MainTabView` to present
    /// `ShareSplitPromptSheet`. Cleared when the user dismisses the
    /// prompt or shares.
    @Published var pendingSplitShareSyncID: String? = nil

    func promptSplitShare(syncID: String) {
        pendingSplitShareSyncID = syncID
    }

    func dismissSplitSharePrompt() {
        pendingSplitShareSyncID = nil
    }
}

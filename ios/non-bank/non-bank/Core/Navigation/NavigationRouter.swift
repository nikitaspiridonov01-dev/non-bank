import SwiftUI
import Combine

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
    /// Optional starting tab for the create flow — `nil` falls back to the
    /// modal's default (.expense). Used by empty-state CTAs that want to
    /// drop the user straight into the Split tab.
    @Published private(set) var initialCreateTab: TransactionTab? = nil
    /// Friend IDs to pre-select as split participants when opening in
    /// `.split` mode. Empty when the empty-state CTA isn't friend-scoped.
    @Published private(set) var prefilledFriendIDs: [String] = []

    func showCreateTransaction(
        initialTab: TransactionTab? = nil,
        prefilledFriendIDs: [String] = []
    ) {
        editingTransaction = nil
        self.initialCreateTab = initialTab
        self.prefilledFriendIDs = prefilledFriendIDs
        showTransactionEditor = true
    }

    func showEditTransaction(_ transaction: Transaction) {
        editingTransaction = transaction
        initialCreateTab = nil
        prefilledFriendIDs = []
        showTransactionEditor = true
    }

    func dismissTransactionEditor() {
        showTransactionEditor = false
        editingTransaction = nil
        initialCreateTab = nil
        prefilledFriendIDs = []
    }

    // MARK: - Import Success

    @Published var showImportSuccess: Bool = false
    @Published var importedCount: Int = 0

    func showImportComplete(count: Int) {
        importedCount = count
        showImportSuccess = true
    }
}

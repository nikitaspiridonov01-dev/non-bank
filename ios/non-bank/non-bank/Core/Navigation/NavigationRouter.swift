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

    func showCreateTransaction() {
        editingTransaction = nil
        showTransactionEditor = true
    }

    func showEditTransaction(_ transaction: Transaction) {
        editingTransaction = transaction
        showTransactionEditor = true
    }

    func dismissTransactionEditor() {
        showTransactionEditor = false
        editingTransaction = nil
    }

    // MARK: - Import Success

    @Published var showImportSuccess: Bool = false
    @Published var importedCount: Int = 0

    func showImportComplete(count: Int) {
        importedCount = count
        showImportSuccess = true
    }
}

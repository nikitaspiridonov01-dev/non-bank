import Foundation
import Combine

/// In-memory cache of all receipt items, mirroring the SQLite table.
///
/// Mirrors the pattern used by `TransactionStore`/`FriendStore` so the rest of
/// the app can read items synchronously through `items(forTransactionID:)` and
/// `hasItems(forTransactionID:)` without juggling async lookups in each view.
/// Saving items replaces the previous set for that transaction (the OCR flow
/// always produces a fresh batch — there's no partial-update concept).
@MainActor
class ReceiptItemStore: ObservableObject {
    @Published private(set) var items: [ReceiptItem] = []

    private let repo: ReceiptItemRepositoryProtocol
    /// Set in `MainTabView` after both stores exist. Weak so the
    /// store doesn't retain the SyncManager.
    weak var syncManager: SyncManager?
    /// Looks up a transaction's stable `syncID` from its local
    /// autoincrement id. Items reference their parent by local id, but
    /// CloudKit needs the syncID. Wired up alongside `syncManager`.
    var transactionSyncIDLookup: ((Int) -> String?)?

    nonisolated init(repo: ReceiptItemRepositoryProtocol = ReceiptItemRepository()) {
        self.repo = repo
        Task { await load() }
    }

    func load() async {
        items = await repo.fetchAll()
    }

    /// Items for a single transaction, sorted in original receipt order.
    func items(forTransactionID transactionID: Int) -> [ReceiptItem] {
        items
            .filter { $0.transactionID == transactionID }
            .sorted { lhs, rhs in
                if lhs.position != rhs.position { return lhs.position < rhs.position }
                return (lhs.persistedID ?? 0) < (rhs.persistedID ?? 0)
            }
    }

    /// Cheap existence check used by row-badge logic.
    func hasItems(forTransactionID transactionID: Int) -> Bool {
        items.contains { $0.transactionID == transactionID }
    }

    /// Replace the saved items for a transaction with `newItems`.
    /// Stamps `transactionID` and `position` automatically.
    func saveItems(_ newItems: [ReceiptItem], for transactionID: Int) async {
        let priorSyncIDs = items.filter { $0.transactionID == transactionID }.map { $0.syncID }

        await repo.deleteAll(transactionID: transactionID)
        let stamped = newItems.enumerated().map { idx, item -> ReceiptItem in
            var copy = item
            copy.transactionID = transactionID
            copy.position = idx
            copy.lastModified = Date()
            return copy
        }
        _ = await repo.insertBatch(stamped)
        await load()

        // CloudKit: replace the prior set with the new one. Items
        // dropped from the local edit are deleted in CloudKit so they
        // don't reappear on the other device on next pull.
        if let txSyncID = transactionSyncIDLookup?(transactionID) {
            await syncManager?.reconcileReceiptItems(
                newItems: stamped,
                priorSyncIDs: priorSyncIDs,
                transactionSyncID: txSyncID
            )
        }
    }

    /// Drop the items for a transaction (e.g. when the transaction is deleted).
    func deleteItems(forTransactionID transactionID: Int) async {
        let removed = items.filter { $0.transactionID == transactionID }
        await repo.deleteAll(transactionID: transactionID)
        await load()

        if let txSyncID = transactionSyncIDLookup?(transactionID), !removed.isEmpty {
            await syncManager?.reconcileReceiptItems(
                newItems: [],
                priorSyncIDs: removed.map { $0.syncID },
                transactionSyncID: txSyncID
            )
        }
    }
}

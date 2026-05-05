import Foundation
import Combine
import SwiftUI

@MainActor
class TransactionStore: ObservableObject {
    @Published private(set) var transactions: [Transaction] = []
    private let repo: TransactionRepositoryProtocol
    private let receiptItemRepo: ReceiptItemRepositoryProtocol
    weak var syncManager: SyncManager?
    /// Guards the one-shot stale-notification cleanup that runs after the
    /// first load — subsequent CRUD already keeps the notification queue
    /// in sync, so we don't need to pay the cost on every load.
    private var hasCleanedStaleNotifications = false

    nonisolated init(
        repo: TransactionRepositoryProtocol = TransactionRepository(),
        receiptItemRepo: ReceiptItemRepositoryProtocol = ReceiptItemRepository()
    ) {
        self.repo = repo
        self.receiptItemRepo = receiptItemRepo
        Task {
            await load()
        }
    }

    func load() async {
        transactions = await repo.fetchAll()
        if !hasCleanedStaleNotifications {
            hasCleanedStaleNotifications = true
            NotificationService.cleanupStale(transactions: transactions)
        }
    }

    func add(_ transaction: Transaction) {
        Task {
            await repo.insert(transaction)
            await load()
            NotificationService.schedule(for: transaction)
            // Trigger a spawn pass right away — covers recurring parents
            // created with a first-occurrence time that has already passed
            // while the user was filling the form.
            processRecurringSpawns()
            await syncManager?.pushTransaction(transaction, action: .save)
        }
    }

    /// Insert a transaction and return the autoincrement ID assigned by SQLite.
    /// Used by callers that need the new ID immediately — e.g. saving linked
    /// receipt items right after the transaction is created. Looks up the
    /// inserted record by its stable `syncID` after the load completes.
    func addAndReturnID(_ transaction: Transaction) async -> Int? {
        await repo.insert(transaction)
        await load()
        NotificationService.schedule(for: transaction)
        processRecurringSpawns()
        await syncManager?.pushTransaction(transaction, action: .save)
        return transactions.first(where: { $0.syncID == transaction.syncID })?.id
    }

    func addBatch(_ transactions: [Transaction]) {
        Task {
            await repo.insertBatch(transactions)
            await load()
            for tx in transactions {
                NotificationService.schedule(for: tx)
            }
            processRecurringSpawns()
            await syncManager?.pushTransactionBatch(transactions)
        }
    }

    func update(_ transaction: Transaction) {
        Task {
            await repo.update(transaction)
            await load()
            NotificationService.schedule(for: transaction)
            processRecurringSpawns()
            await syncManager?.pushTransaction(transaction, action: .save)
        }
    }

    /// Rewrite every transaction's split-info friend list, replacing
    /// `phantomID` references with `realID`. Used by the share-link
    /// receiver flow alongside `FriendStore.upgradePhantom(...)` —
    /// after the Friend record's ID changes, all historical split
    /// transactions need to follow so the user's debt history stays
    /// consistent. Async + sequential to keep DB writes ordered.
    func upgradePhantomFriendID(from phantomID: String, to realID: String) async {
        guard phantomID != realID else { return }
        let affected = transactions.filter { tx in
            tx.splitInfo?.friends.contains(where: { $0.friendID == phantomID }) ?? false
        }
        for tx in affected {
            guard let split = tx.splitInfo else { continue }
            // Rewrite each FriendShare carrying the phantom ID. Other
            // shares are kept as-is (their IDs were already correct).
            let rewrittenShares = split.friends.map { share -> FriendShare in
                guard share.friendID == phantomID else { return share }
                return FriendShare(
                    friendID: realID,
                    share: share.share,
                    paidAmount: share.paidAmount,
                    isSettled: share.isSettled
                )
            }
            let newSplit = SplitInfo(
                totalAmount: split.totalAmount,
                paidByMe: split.paidByMe,
                myShare: split.myShare,
                lentAmount: split.lentAmount,
                friends: rewrittenShares,
                splitMode: split.splitMode
            )
            let updated = Transaction(
                id: tx.id,
                syncID: tx.syncID,
                emoji: tx.emoji,
                category: tx.category,
                title: tx.title,
                description: tx.description,
                amount: tx.amount,
                currency: tx.currency,
                date: tx.date,
                type: tx.type,
                tags: tx.tags,
                lastModified: Date(),
                repeatInterval: tx.repeatInterval,
                parentReminderID: tx.parentReminderID,
                splitInfo: newSplit,
                payloadChecksum: tx.payloadChecksum
            )
            await repo.update(updated)
        }
        if !affected.isEmpty {
            await load()
        }
    }

    func delete(id: Int) {
        let tx = transactions.first { $0.id == id }
        Task {
            await repo.delete(id: id)
            // Cascade-delete any receipt items belonging to this transaction —
            // SQLite foreign-key cascades aren't enabled on the connection,
            // so we do it explicitly here.
            await receiptItemRepo.deleteAll(transactionID: id)
            await load()
            if let tx {
                NotificationService.cancel(for: tx)
                // Deleting a child of a recurring parent: ack the occurrence
                // so the spawn logic doesn't regenerate it. Deleting the
                // parent itself: clear the tracker *and* unlink surviving
                // children so they stop rendering as recurring.
                if let parentID = tx.parentReminderID,
                   let parent = transactions.first(where: { $0.id == parentID }) {
                    SpawnTracker.acknowledge(parentSyncID: parent.syncID, at: tx.date)
                }
                if tx.isRecurringParent {
                    SpawnTracker.clear(parentSyncID: tx.syncID)
                    let orphans = transactions.filter { $0.parentReminderID == tx.id }
                    if !orphans.isEmpty {
                        for orphan in orphans {
                            let updated = orphan.orphanedFromRecurringParent()
                            await repo.update(updated)
                            await syncManager?.pushTransaction(updated, action: .save)
                        }
                        await load()
                    }
                }
                await syncManager?.pushTransaction(tx, action: .delete)
            }
        }
    }

    func deleteAll() {
        let allTx = transactions
        Task {
            await repo.deleteAll()
            // Cascade-delete every transaction's receipt items.
            for tx in allTx {
                await receiptItemRepo.deleteAll(transactionID: tx.id)
            }
            await load()
            for tx in allTx {
                NotificationService.cancel(for: tx)
                if tx.isRecurringParent {
                    SpawnTracker.clear(parentSyncID: tx.syncID)
                }
                await syncManager?.pushTransaction(tx, action: .delete)
            }
        }
    }

    // MARK: - Reminder Helpers

    /// Transactions eligible for the Home screen (past-dated, non-parent).
    var homeTransactions: [Transaction] {
        ReminderService.homeTransactions(from: transactions)
    }

    /// Transactions eligible for the Reminders screen.
    var reminderTransactions: [Transaction] {
        ReminderService.reminders(from: transactions)
    }

    /// Checks if any recurring parents need to spawn new children and creates them.
    /// Calls `onSpawned` with the list of newly created children (if any).
    func processRecurringSpawns(onSpawned: (([Transaction]) -> Void)? = nil) {
        Task {
            let parents = transactions.filter { $0.isRecurringParent }
            guard !parents.isEmpty else { return }
            let needed = ReminderService.transactionsNeedingSpawn(
                recurringParents: parents,
                allTransactions: transactions
            )
            guard !needed.isEmpty else { return }
            let children = needed.map { ReminderService.spawnChild(from: $0.parent, at: $0.spawnDate) }
            await repo.insertBatch(children)
            // Acknowledge each occurrence so that later child deletion doesn't
            // cause a re-spawn of the same occurrence.
            for (parent, spawnDate) in needed {
                SpawnTracker.acknowledge(parentSyncID: parent.syncID, at: spawnDate)
            }
            await syncManager?.pushTransactionBatch(children)
            await load()
            onSpawned?(children)
        }
    }
}
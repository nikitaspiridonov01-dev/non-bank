import Foundation
import Combine
import SwiftUI

@MainActor
class TransactionStore: ObservableObject {
    @Published private(set) var transactions: [Transaction] = []
    /// Flips to `true` the first time `load()` finishes — including
    /// the very first load that's kicked off in `init` before any view
    /// has subscribed. View code observes this so it can show a
    /// skeleton placeholder during cold-launch instead of flashing
    /// the empty state at the user while SQLite is still fetching.
    /// Stays `true` for the rest of the session even when subsequent
    /// `load()` calls (sync push-back, edits) mutate `transactions`.
    @Published private(set) var hasLoadedOnce: Bool = false
    /// Monotonic version counter — increments on every `load()` so views
    /// observing transactions can build a cheap O(1) Hashable fingerprint
    /// for `.task(id:)` triggers without iterating the whole array. Used
    /// by `HomeViewModel.recomputeFiltered` to detect "the data behind my
    /// cache changed" without needing `[Transaction]` itself to be
    /// `Hashable`. Wraps on overflow; given iOS app lifetimes one increment
    /// per CRUD operation, overflow is astronomically far away.
    @Published private(set) var version: UInt64 = 0
    private let repo: TransactionRepositoryProtocol
    private let receiptItemRepo: ReceiptItemRepositoryProtocol
    weak var syncManager: SyncManager?
    /// Guards the one-shot stale-notification cleanup that runs after the
    /// first load — subsequent CRUD already keeps the notification queue
    /// in sync, so we don't need to pay the cost on every load.
    private var hasCleanedStaleNotifications = false
    /// Handle for the in-flight recurring-spawn pass. `processRecurringSpawns`
    /// fires from multiple triggers (60-second timer in `MainTabView`,
    /// `scenePhase == .active`, share-link receive completion) and the
    /// previous fire-and-forget pattern would launch concurrent passes
    /// that all read the same `transactions` snapshot and race their DB
    /// writes. Storing the handle lets a new caller drop its request
    /// when a previous pass is still running — spawn passes are
    /// idempotent against `transactions`, so the next trigger picks up
    /// anything missed without re-running the same DB work twice.
    private var spawnTask: Task<Void, Never>?

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
        // Bump the version BEFORE the hasLoadedOnce flip so any view
        // observing both reads a fresh version on the same frame it
        // sees `hasLoadedOnce == true`.
        version &+= 1
        // Flag set AFTER the assignment so views that observe both
        // `transactions` and `hasLoadedOnce` together see consistent
        // state on the same frame.
        hasLoadedOnce = true
        if !hasCleanedStaleNotifications {
            hasCleanedStaleNotifications = true
            NotificationService.cleanupStale(transactions: transactions)
        }
    }

    func add(_ transaction: Transaction) {
        Task {
            // Idempotency guard: a logical save can be committed more than
            // once (UI re-entrancy, retry). The `transactions` table has
            // no UNIQUE constraint on `sync_id`, so a blind `insert` would
            // create a duplicate row every time. If a row with this
            // `syncID` already exists, update it in place (carrying the
            // existing autoincrement `id` so the UPDATE … WHERE id = ?
            // resolves) instead of inserting a second copy — so one
            // logical save can only ever yield one transaction.
            await insertOrUpdateBySyncID(transaction)
            await load()
            NotificationService.schedule(for: transaction)
            // Trigger a spawn pass right away — covers recurring parents
            // created with a first-occurrence time that has already passed
            // while the user was filling the form.
            processRecurringSpawns()
            await syncManager?.pushTransaction(transaction, action: .save)
        }
    }

    /// Insert `transaction`, or — when a row already carries the same
    /// stable `syncID` — update that existing row in place. Centralises
    /// the idempotency rule shared by `add(_:)` and `addAndReturnID(_:)`:
    /// a double-commit of one logical save (re-entrancy / retry) can
    /// never fan out into duplicate rows. The incoming `transaction.id`
    /// is `0` for a fresh create, so we re-stamp it with the existing
    /// row's autoincrement id before updating; otherwise the
    /// `UPDATE … WHERE id = ?` would target nothing.
    private func insertOrUpdateBySyncID(_ transaction: Transaction) async {
        if let existing = transactions.first(where: { $0.syncID == transaction.syncID }) {
            let reconciled = transaction.id == existing.id
                ? transaction
                : transaction.withID(existing.id)
            await repo.update(reconciled)
        } else {
            await repo.insert(transaction)
        }
    }

    /// Insert a transaction and return the autoincrement ID assigned by SQLite.
    /// Used by callers that need the new ID immediately — e.g. saving linked
    /// receipt items right after the transaction is created. Looks up the
    /// inserted record by its stable `syncID` after the load completes.
    func addAndReturnID(_ transaction: Transaction) async -> Int? {
        // Same idempotency guard as `add(_:)` — a double-commit of the
        // same logical save (same `syncID`) updates the existing row
        // rather than inserting a duplicate, then resolves the existing
        // autoincrement id below.
        await insertOrUpdateBySyncID(transaction)
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

    /// Awaitable batch insert that returns a `syncID → new autoincrement id`
    /// map. Used by the native non-bank import path so the caller can
    /// stamp receipt items with the right `transactionID` after the rows
    /// land in SQLite — local IDs aren't part of the export format.
    func addBatchAndReturnSyncIDMap(_ transactions: [Transaction]) async -> [String: Int] {
        await repo.insertBatch(transactions)
        await load()
        for tx in transactions {
            NotificationService.schedule(for: tx)
        }
        processRecurringSpawns()
        await syncManager?.pushTransactionBatch(transactions)
        let importedSyncIDs = Set(transactions.map { $0.syncID })
        var map: [String: Int] = [:]
        for tx in self.transactions where importedSyncIDs.contains(tx.syncID) {
            map[tx.syncID] = tx.id
        }
        return map
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

    /// Rewrite every transaction whose category title matches `oldTitle`
    /// so that it points at `newTitle` with `newEmoji`. Used by the
    /// category editor — `Transaction.category` is a text reference,
    /// not a foreign key, so a rename has to walk the table itself.
    /// `lastModified` is bumped on each touched row so CloudKit and any
    /// other devices treat the rewrite as the latest edit.
    func renameCategory(from oldTitle: String, to newTitle: String, newEmoji: String) {
        let affected = transactions.filter { $0.category == oldTitle }
        guard !affected.isEmpty else { return }
        Task {
            var rewritten: [Transaction] = []
            for tx in affected {
                let updated = Transaction(
                    id: tx.id, syncID: tx.syncID,
                    emoji: newEmoji, category: newTitle,
                    title: tx.title, description: tx.description,
                    amount: tx.amount, currency: tx.currency,
                    date: tx.date, type: tx.type,
                    tags: tx.tags, lastModified: Date(),
                    repeatInterval: tx.repeatInterval,
                    parentReminderID: tx.parentReminderID,
                    splitInfo: tx.splitInfo,
                    payloadChecksum: tx.payloadChecksum,
                    excludedFromInsights: tx.excludedFromInsights
                )
                await repo.update(updated)
                rewritten.append(updated)
            }
            await load()
            await syncManager?.pushTransactionBatch(rewritten)
        }
    }

    /// Awaitable update — same as `update(_:)` but the caller can
    /// `await` until the DB write + `load()` finishes. Used by the
    /// share-link receiver: without this, the coordinator transitioned
    /// to `.completed` while the underlying Task was still in flight,
    /// so the UI's `transactions.first(where:)` lookup would either
    /// see stale data or — when paired with id-based lookup — miss
    /// the row entirely.
    func updateAndWait(_ transaction: Transaction) async {
        await repo.update(transaction)
        await load()
        NotificationService.schedule(for: transaction)
        processRecurringSpawns()
        await syncManager?.pushTransaction(transaction, action: .save)
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
                payloadChecksum: tx.payloadChecksum,
                excludedFromInsights: tx.excludedFromInsights,
                // Preserve the sync edit version — an id rewrite is not a
                // content edit, and resetting it to 0 would let a stale
                // server delivery clobber this transaction on the next pull.
                editVersion: tx.editVersion
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
            // Snapshot the receipt items BEFORE deleting them locally —
            // we need their syncIDs to cascade the delete to CloudKit,
            // otherwise the records linger as orphans (they never come
            // back to other devices because their parent is gone, but
            // they keep taking up zone storage forever).
            let cascadingItems = await receiptItemRepo.fetch(transactionID: id)
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
                if !cascadingItems.isEmpty {
                    await syncManager?.reconcileReceiptItems(
                        newItems: [],
                        priorSyncIDs: cascadingItems.map { $0.syncID },
                        transactionSyncID: tx.syncID
                    )
                }
            }
        }
    }

    func deleteAll() {
        Task { await deleteAllAndWait() }
    }

    /// Awaitable variant of `deleteAll()`. Use this when sequencing
    /// a wipe with a follow-up batch operation — e.g. the replace-mode
    /// import path needs the wipe to *finish* before the new batch
    /// inserts, otherwise the two fire-and-forget Tasks race on the
    /// SQLite queue and the late delete eats the freshly-inserted
    /// rows. Body is identical to the original `deleteAll()` Task
    /// closure, just hoisted into a callable async function.
    func deleteAllAndWait() async {
        let allTx = transactions
        // Snapshot receipt items per transaction BEFORE the wipe.
        // Same reason as the single-delete path: orphans on CloudKit
        // are functionally invisible to other devices but consume
        // zone storage indefinitely.
        var priorItemSyncIDsByTxSyncID: [String: [String]] = [:]
        for tx in allTx {
            let items = await receiptItemRepo.fetch(transactionID: tx.id)
            if !items.isEmpty {
                priorItemSyncIDsByTxSyncID[tx.syncID] = items.map { $0.syncID }
            }
        }
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
            if let priorSyncIDs = priorItemSyncIDsByTxSyncID[tx.syncID] {
                await syncManager?.reconcileReceiptItems(
                    newItems: [],
                    priorSyncIDs: priorSyncIDs,
                    transactionSyncID: tx.syncID
                )
            }
        }
    }

    // MARK: - Reminder Helpers

    /// Transactions eligible for the Home screen (past-dated, non-parent).
    var homeTransactions: [Transaction] {
        ReminderService.homeTransactions(from: transactions)
    }

    /// `homeTransactions` normalised for analytics / balance / trend
    /// aggregation: rows the user hid (`excludedFromInsights`) are
    /// dropped, and split-transaction amounts are rewritten to
    /// `myShare` when the global "include potential expenses" setting
    /// is ON. Use this for any sum/aggregate on Home or Insights; keep
    /// the raw `homeTransactions` for the list view itself so the user
    /// can still see and unhide excluded rows.
    var homeTransactionsForInsights: [Transaction] {
        AnalyticsContext.normaliseForInsights(
            homeTransactions,
            includePotentialExpenses: InsightsSettings.shared.includePotentialExpenses
        )
    }

    /// Transactions eligible for the Reminders screen.
    var reminderTransactions: [Transaction] {
        ReminderService.reminders(from: transactions)
    }

    /// Checks if any recurring parents need to spawn new children and creates them.
    /// Calls `onSpawned` with the list of newly created children (if any).
    ///
    /// Idempotent against `transactions` — if a previous pass is still
    /// in flight (`spawnTask != nil`) the new request is dropped: the
    /// running pass will either pick up the same parents/needed pairs
    /// or the next trigger (60-second timer, scene-active) will catch
    /// up. The earlier fire-and-forget pattern launched a fresh `Task`
    /// per call with no handle, so rapid navigation could queue 5+
    /// passes racing the same DB writes.
    func processRecurringSpawns(onSpawned: (([Transaction]) -> Void)? = nil) {
        guard spawnTask == nil else { return }
        spawnTask = Task { [weak self] in
            // Clear the handle on exit so the next trigger can fire,
            // regardless of whether this pass found anything to do.
            // `defer` runs after the body completes (success or
            // cancellation) so the handle is never left dangling.
            defer { Task { @MainActor [weak self] in self?.spawnTask = nil } }
            guard let self else { return }
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
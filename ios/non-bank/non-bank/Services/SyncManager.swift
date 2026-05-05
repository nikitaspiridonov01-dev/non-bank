import Foundation
import CloudKit
import Combine

@MainActor
class SyncManager: ObservableObject {

    // ⚡️ MASTER SWITCH — set to `true` when you have a paid Apple Developer account
    // and have enabled the iCloud + CloudKit capability in Xcode.
    static let isCloudKitEnabled = false

    @Published var isSyncEnabled: Bool = UserDefaults.standard.bool(forKey: syncEnabledKey) {
        didSet { UserDefaults.standard.set(isSyncEnabled, forKey: Self.syncEnabledKey) }
    }
    @Published var syncStatus: SyncStatus = .idle
    @Published var iCloudAvailable: Bool = false

    enum SyncStatus: Equatable {
        case idle
        case syncing
        case error(String)
        case lastSynced(Date)
    }

    static let syncEnabledKey = "iCloudSyncEnabled"
    private let pendingDeletesTxKey = "ck_pendingDeleteTransactions"
    private let pendingDeletesCatKey = "ck_pendingDeleteCategories"

    private lazy var cloudKit = CloudKitService.shared
    private let db = SQLiteService.shared

    /// Weak references set from stores so SyncManager can trigger reload.
    weak var transactionStore: TransactionStore?
    weak var categoryStore: CategoryStore?

    private var isSyncing = false

    nonisolated init() {}

    // MARK: - Check iCloud

    func checkAvailability() async {
        guard Self.isCloudKitEnabled else { iCloudAvailable = false; return }
        let status = await cloudKit.checkAccountStatus()
        iCloudAvailable = (status == .available)
    }

    // MARK: - Enable / Disable Sync

    func enableSync() async {
        guard Self.isCloudKitEnabled, !isSyncing else { return }
        isSyncEnabled = true
        syncStatus = .syncing
        do {
            try await cloudKit.createCustomZoneIfNeeded()
            try await cloudKit.createSubscriptionIfNeeded()
            try await performInitialSync()
            syncStatus = .lastSynced(Date())
        } catch {
            print("Enable sync error: \(error)")
            syncStatus = .error(error.localizedDescription)
        }
    }

    func disableSync() async {
        guard Self.isCloudKitEnabled, !isSyncing else { return }
        // Pull latest before disabling
        syncStatus = .syncing
        do {
            try await pullChanges()
        } catch {
            print("Pull before disable error: \(error)")
        }
        isSyncEnabled = false
        syncStatus = .idle
    }

    // MARK: - Initial Sync

    private func performInitialSync() async throws {
        isSyncing = true
        defer { isSyncing = false }

        // 1. Fetch everything from CloudKit
        let remoteTransactionRecords = try await cloudKit.fetchAllRecords(ofType: CloudKitService.transactionType)
        let remoteCategoryRecords = try await cloudKit.fetchAllRecords(ofType: CloudKitService.categoryType)

        let remoteTransactions = remoteTransactionRecords.compactMap { cloudKit.transactionFromRecord($0) }
        let remoteCategories = remoteCategoryRecords.compactMap { cloudKit.categoryFromRecord($0) }

        // 2. Fetch local data
        let localTransactions = await db.fetchAllTransactions()
        let localCategories = await db.fetchAllCategories()

        // 3. Merge categories (by title, case-insensitive)
        let mergedCategories = mergeCategories(local: localCategories, remote: remoteCategories)
        // Write merged categories to local DB
        for cat in mergedCategories.toInsertLocally {
            await db.insertCategory(cat)
        }
        for cat in mergedCategories.toUpdateLocally {
            await db.updateCategory(cat)
        }
        // Push new/updated categories to CloudKit
        let categoryRecords = mergedCategories.toPushRemote.map { cloudKit.categoryToRecord($0) }
        if !categoryRecords.isEmpty {
            try await cloudKit.saveRecords(categoryRecords)
        }

        // 4. Merge transactions (by syncID)
        let mergedTx = mergeTransactions(local: localTransactions, remote: remoteTransactions)
        // Write merged transactions to local DB
        for tx in mergedTx.toInsertLocally {
            await db.insertTransaction(tx)
        }
        for tx in mergedTx.toUpdateLocally {
            await db.updateTransaction(tx)
        }
        // Push new/updated transactions to CloudKit
        let txRecords = mergedTx.toPushRemote.map { cloudKit.transactionToRecord($0) }
        if !txRecords.isEmpty {
            try await cloudKit.saveRecords(txRecords)
        }

        // 5. Reset change token for future delta syncs
        cloudKit.resetChangeToken()
        // Do an initial fetch to seed the token
        _ = try? await cloudKit.fetchChanges()

        // 6. Reload stores
        await reloadStores()
    }

    // MARK: - Push (after local change)

    func pushTransaction(_ tx: Transaction, action: SyncAction) async {
        guard Self.isCloudKitEnabled, isSyncEnabled else { return }
        do {
            switch action {
            case .save:
                let record = cloudKit.transactionToRecord(tx)
                try await cloudKit.saveRecords([record])
            case .delete:
                let recordID = cloudKit.recordID(forSyncID: tx.syncID, type: CloudKitService.transactionType)
                try await cloudKit.deleteRecords([recordID])
            }
        } catch {
            print("Push transaction error: \(error)")
            if action == .delete {
                addPendingDelete(syncID: tx.syncID, key: pendingDeletesTxKey, type: CloudKitService.transactionType)
            }
        }
    }

    func pushCategory(_ cat: Category, action: SyncAction) async {
        guard Self.isCloudKitEnabled, isSyncEnabled else { return }
        do {
            switch action {
            case .save:
                let record = cloudKit.categoryToRecord(cat)
                try await cloudKit.saveRecords([record])
            case .delete:
                let recordID = cloudKit.recordID(forSyncID: cat.id.uuidString, type: CloudKitService.categoryType)
                try await cloudKit.deleteRecords([recordID])
            }
        } catch {
            print("Push category error: \(error)")
            if action == .delete {
                addPendingDelete(syncID: cat.id.uuidString, key: pendingDeletesCatKey, type: CloudKitService.categoryType)
            }
        }
    }

    func pushTransactionBatch(_ transactions: [Transaction]) async {
        guard Self.isCloudKitEnabled, isSyncEnabled, !transactions.isEmpty else { return }
        let records = transactions.map { cloudKit.transactionToRecord($0) }
        do {
            try await cloudKit.saveRecords(records)
        } catch {
            print("Push batch error: \(error)")
        }
    }

    func pushCategoryBatch(_ categories: [Category]) async {
        guard Self.isCloudKitEnabled, isSyncEnabled, !categories.isEmpty else { return }
        let records = categories.map { cloudKit.categoryToRecord($0) }
        do {
            try await cloudKit.saveRecords(records)
        } catch {
            print("Push category batch error: \(error)")
        }
    }

    // MARK: - Pull (fetch remote changes)

    func pullChanges() async throws {
        guard Self.isCloudKitEnabled, isSyncEnabled, !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }

        syncStatus = .syncing

        // Retry pending deletes
        await retryPendingDeletes()

        do {
            let (changed, deletedIDs) = try await cloudKit.fetchChanges()

            // Process deleted records
            for recordID in deletedIDs {
                let name = recordID.recordName
                if name.hasPrefix("\(CloudKitService.transactionType)_") {
                    let syncID = String(name.dropFirst(CloudKitService.transactionType.count + 1))
                    await db.deleteTransactionBySyncID(syncID)
                } else if name.hasPrefix("\(CloudKitService.categoryType)_") {
                    let idString = String(name.dropFirst(CloudKitService.categoryType.count + 1))
                    if let uuid = UUID(uuidString: idString) {
                        await db.deleteCategory(id: uuid)
                    }
                }
            }

            // Process changed records
            for record in changed {
                if record.recordType == CloudKitService.transactionType {
                    if let remoteTx = cloudKit.transactionFromRecord(record) {
                        let localTx = await db.fetchTransactionBySyncID(remoteTx.syncID)
                        if let localTx {
                            if remoteTx.lastModified > localTx.lastModified {
                                let updated = Transaction(
                                    id: localTx.id, syncID: remoteTx.syncID,
                                    emoji: remoteTx.emoji, category: remoteTx.category,
                                    title: remoteTx.title, description: remoteTx.description,
                                    amount: remoteTx.amount, currency: remoteTx.currency,
                                    date: remoteTx.date, type: remoteTx.type,
                                    tags: nil, lastModified: remoteTx.lastModified,
                                    repeatInterval: remoteTx.repeatInterval,
                                    parentReminderID: remoteTx.parentReminderID,
                                    splitInfo: remoteTx.splitInfo
                                )
                                await db.updateTransaction(updated)
                            }
                        } else {
                            await db.insertTransaction(remoteTx)
                        }
                    }
                } else if record.recordType == CloudKitService.categoryType {
                    if let remoteCat = cloudKit.categoryFromRecord(record) {
                        let localCat = await db.fetchCategoryByID(remoteCat.id)
                        if let localCat {
                            if remoteCat.lastModified > localCat.lastModified {
                                await db.updateCategory(remoteCat)
                            }
                        } else {
                            await db.insertCategory(remoteCat)
                        }
                    }
                }
            }

            if !changed.isEmpty || !deletedIDs.isEmpty {
                await reloadStores()
            }

            syncStatus = .lastSynced(Date())
        } catch {
            syncStatus = .error(error.localizedDescription)
            throw error
        }
    }

    // MARK: - Foreground sync

    func syncIfEnabled() async {
        guard Self.isCloudKitEnabled, isSyncEnabled else { return }
        await checkAvailability()
        guard iCloudAvailable else { return }
        try? await pullChanges()
    }

    // MARK: - Merge Logic

    struct MergeResult<T> {
        let toInsertLocally: [T]
        let toUpdateLocally: [T]
        let toPushRemote: [T]
    }

    private func mergeTransactions(local: [Transaction], remote: [Transaction]) -> MergeResult<Transaction> {
        var localBySyncID: [String: Transaction] = [:]
        for tx in local { localBySyncID[tx.syncID] = tx }

        var remoteBySyncID: [String: Transaction] = [:]
        for tx in remote { remoteBySyncID[tx.syncID] = tx }

        var toInsertLocally: [Transaction] = []
        var toUpdateLocally: [Transaction] = []
        var toPushRemote: [Transaction] = []

        // Remote records not in local → insert locally
        for (syncID, remoteTx) in remoteBySyncID {
            if let localTx = localBySyncID[syncID] {
                // Both exist — newest wins
                if remoteTx.lastModified > localTx.lastModified {
                    let updated = Transaction(
                        id: localTx.id, syncID: syncID,
                        emoji: remoteTx.emoji, category: remoteTx.category,
                        title: remoteTx.title, description: remoteTx.description,
                        amount: remoteTx.amount, currency: remoteTx.currency,
                        date: remoteTx.date, type: remoteTx.type,
                        tags: nil, lastModified: remoteTx.lastModified,
                        repeatInterval: remoteTx.repeatInterval,
                        parentReminderID: remoteTx.parentReminderID,
                        splitInfo: remoteTx.splitInfo
                    )
                    toUpdateLocally.append(updated)
                } else if localTx.lastModified > remoteTx.lastModified {
                    toPushRemote.append(localTx)
                }
            } else {
                toInsertLocally.append(remoteTx)
            }
        }

        // Local records not in remote → push to cloud
        for (syncID, localTx) in localBySyncID {
            if remoteBySyncID[syncID] == nil {
                toPushRemote.append(localTx)
            }
        }

        return MergeResult(toInsertLocally: toInsertLocally, toUpdateLocally: toUpdateLocally, toPushRemote: toPushRemote)
    }

    private func mergeCategories(local: [Category], remote: [Category]) -> MergeResult<Category> {
        var localByID: [UUID: Category] = [:]
        for cat in local { localByID[cat.id] = cat }
        var localByTitle: [String: Category] = [:]
        for cat in local { localByTitle[cat.title.lowercased()] = cat }

        var remoteByID: [UUID: Category] = [:]
        for cat in remote { remoteByID[cat.id] = cat }

        var toInsertLocally: [Category] = []
        var toUpdateLocally: [Category] = []
        var toPushRemote: [Category] = []

        for (id, remoteCat) in remoteByID {
            if let localCat = localByID[id] {
                if remoteCat.lastModified > localCat.lastModified {
                    toUpdateLocally.append(remoteCat)
                } else if localCat.lastModified > remoteCat.lastModified {
                    toPushRemote.append(localCat)
                }
            } else if localByTitle[remoteCat.title.lowercased()] != nil {
                // Category with same title exists locally (different UUID) — skip to avoid duplicates
                // Keep local version, push it to cloud
                let existing = localByTitle[remoteCat.title.lowercased()]!
                toPushRemote.append(existing)
            } else {
                toInsertLocally.append(remoteCat)
            }
        }

        // Local categories not in remote → push
        for (id, localCat) in localByID {
            if remoteByID[id] == nil {
                toPushRemote.append(localCat)
            }
        }

        return MergeResult(toInsertLocally: toInsertLocally, toUpdateLocally: toUpdateLocally, toPushRemote: toPushRemote)
    }

    // MARK: - Pending Deletes

    private func addPendingDelete(syncID: String, key: String, type: String) {
        var pending = UserDefaults.standard.stringArray(forKey: key) ?? []
        if !pending.contains(syncID) {
            pending.append(syncID)
            UserDefaults.standard.set(pending, forKey: key)
        }
    }

    private func retryPendingDeletes() async {
        // Transactions
        let pendingTx = UserDefaults.standard.stringArray(forKey: pendingDeletesTxKey) ?? []
        if !pendingTx.isEmpty {
            let ids = pendingTx.map { cloudKit.recordID(forSyncID: $0, type: CloudKitService.transactionType) }
            do {
                try await cloudKit.deleteRecords(ids)
                UserDefaults.standard.removeObject(forKey: pendingDeletesTxKey)
            } catch {
                print("Retry pending tx deletes error: \(error)")
            }
        }

        // Categories
        let pendingCat = UserDefaults.standard.stringArray(forKey: pendingDeletesCatKey) ?? []
        if !pendingCat.isEmpty {
            let ids = pendingCat.map { cloudKit.recordID(forSyncID: $0, type: CloudKitService.categoryType) }
            do {
                try await cloudKit.deleteRecords(ids)
                UserDefaults.standard.removeObject(forKey: pendingDeletesCatKey)
            } catch {
                print("Retry pending cat deletes error: \(error)")
            }
        }
    }

    // MARK: - Reload stores

    private func reloadStores() async {
        await transactionStore?.load()
        await categoryStore?.reloadFromDB()
    }
}

// MARK: - SyncAction

enum SyncAction {
    case save
    case delete
}

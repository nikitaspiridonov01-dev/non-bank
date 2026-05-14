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
    private let pendingDeletesFriendKey = "ck_pendingDeleteFriends"
    private let pendingDeletesItemKey = "ck_pendingDeleteReceiptItems"

    private lazy var cloudKit = CloudKitService.shared
    private let db = SQLiteService.shared

    /// Weak references set from stores so SyncManager can trigger reload.
    weak var transactionStore: TransactionStore?
    weak var categoryStore: CategoryStore?
    weak var friendStore: FriendStore?
    weak var receiptItemStore: ReceiptItemStore?

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
        let remoteFriendRecords = try await cloudKit.fetchAllRecords(ofType: CloudKitService.friendType)
        let remoteReceiptItemRecords = try await cloudKit.fetchAllRecords(ofType: CloudKitService.receiptItemType)

        let remoteTransactions = remoteTransactionRecords.compactMap { cloudKit.transactionFromRecord($0) }
        let remoteCategories = remoteCategoryRecords.compactMap { cloudKit.categoryFromRecord($0) }
        let remoteFriends = remoteFriendRecords.compactMap { cloudKit.friendFromRecord($0) }
        let remoteReceiptItemTuples = remoteReceiptItemRecords.compactMap { cloudKit.receiptItemFromRecord($0) }

        // 2. Fetch local data
        let localTransactions = await db.fetchAllTransactions()
        let localCategories = await db.fetchAllCategories()
        let localFriends = await db.fetchAllFriends()
        let localReceiptItems = await db.fetchAllReceiptItems()

        // 3. Merge categories (by title, case-insensitive)
        let mergedCategories = mergeCategories(local: localCategories, remote: remoteCategories)
        for cat in mergedCategories.toInsertLocally {
            await db.insertCategory(cat)
        }
        for cat in mergedCategories.toUpdateLocally {
            await db.updateCategory(cat)
        }
        let categoryRecords = mergedCategories.toPushRemote.map { cloudKit.categoryToRecord($0) }
        if !categoryRecords.isEmpty {
            try await cloudKit.saveRecords(categoryRecords)
        }

        // 4. Merge friends (by id, lastModified-based conflict resolution)
        let mergedFriends = mergeFriends(local: localFriends, remote: remoteFriends)
        for friend in mergedFriends.toInsertLocally {
            await db.insertFriend(friend)
        }
        for friend in mergedFriends.toUpdateLocally {
            await db.updateFriend(friend)
        }
        let friendRecords = mergedFriends.toPushRemote.map { cloudKit.friendToRecord($0) }
        if !friendRecords.isEmpty {
            try await cloudKit.saveRecords(friendRecords)
        }

        // 5. Merge transactions (by syncID).
        //    Done after friends so any incoming split-transaction's
        //    friend references resolve to real records on first pull.
        let mergedTx = mergeTransactions(local: localTransactions, remote: remoteTransactions)
        for tx in mergedTx.toInsertLocally {
            await db.insertTransaction(tx)
        }
        for tx in mergedTx.toUpdateLocally {
            await db.updateTransaction(tx)
        }
        let txRecords = mergedTx.toPushRemote.map { cloudKit.transactionToRecord($0) }
        if !txRecords.isEmpty {
            try await cloudKit.saveRecords(txRecords)
        }

        // 6. Merge receipt items. Needs the latest transactions table
        //    (post-merge above) so we can resolve `transactionSyncID →
        //    local transactionID` when inserting remote items.
        let (syncIDToID, idToSyncID) = await loadTransactionIDMaps()
        let mergedItems = mergeReceiptItems(
            local: localReceiptItems,
            remote: remoteReceiptItemTuples,
            transactionIDBySyncID: syncIDToID
        )
        for item in mergedItems.toInsertLocally {
            _ = await db.insertReceiptItem(item)
        }
        for item in mergedItems.toUpdateLocally {
            await db.updateReceiptItem(item)
        }
        let itemRecords: [CKRecord] = mergedItems.toPushRemote.compactMap { item in
            guard let txID = item.transactionID,
                  let parentSyncID = idToSyncID[txID] else { return nil }
            return cloudKit.receiptItemToRecord(item, transactionSyncID: parentSyncID)
        }
        if !itemRecords.isEmpty {
            try await cloudKit.saveRecords(itemRecords)
        }

        // 7. Reset change token for future delta syncs
        cloudKit.resetChangeToken()
        _ = try? await cloudKit.fetchChanges()

        // 8. Reload stores
        await reloadStores()
    }

    /// One DB read, both directions: `syncID → id` for resolving
    /// incoming receipt items to a local parent, `id → syncID` for
    /// stamping outgoing items with their parent's stable identifier.
    private func loadTransactionIDMaps() async -> (syncIDToID: [String: Int], idToSyncID: [Int: String]) {
        let all = await db.fetchAllTransactions()
        var syncIDToID: [String: Int] = [:]
        var idToSyncID: [Int: String] = [:]
        for tx in all {
            syncIDToID[tx.syncID] = tx.id
            idToSyncID[tx.id] = tx.syncID
        }
        return (syncIDToID, idToSyncID)
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

    func pushFriend(_ friend: Friend, action: SyncAction) async {
        guard Self.isCloudKitEnabled, isSyncEnabled else { return }
        do {
            switch action {
            case .save:
                let record = cloudKit.friendToRecord(friend)
                try await cloudKit.saveRecords([record])
            case .delete:
                let recordID = cloudKit.recordID(forSyncID: friend.id, type: CloudKitService.friendType)
                try await cloudKit.deleteRecords([recordID])
            }
        } catch {
            print("Push friend error: \(error)")
            if action == .delete {
                addPendingDelete(syncID: friend.id, key: pendingDeletesFriendKey, type: CloudKitService.friendType)
            }
        }
    }

    /// Push a single receipt item. Caller supplies the parent
    /// transaction's `syncID` since the item only carries the local
    /// autoincrement id.
    func pushReceiptItem(_ item: ReceiptItem, transactionSyncID: String, action: SyncAction) async {
        guard Self.isCloudKitEnabled, isSyncEnabled else { return }
        do {
            switch action {
            case .save:
                let record = cloudKit.receiptItemToRecord(item, transactionSyncID: transactionSyncID)
                try await cloudKit.saveRecords([record])
            case .delete:
                let recordID = cloudKit.recordID(forSyncID: item.syncID, type: CloudKitService.receiptItemType)
                try await cloudKit.deleteRecords([recordID])
            }
        } catch {
            print("Push receipt item error: \(error)")
            if action == .delete {
                addPendingDelete(syncID: item.syncID, key: pendingDeletesItemKey, type: CloudKitService.receiptItemType)
            }
        }
    }

    /// Reconcile a transaction's receipt items in CloudKit against a
    /// new local set. Pushes inserts/updates for the incoming list and
    /// deletes any prior items (identified by `priorSyncIDs`) that
    /// aren't present any more. Use this from
    /// `ReceiptItemStore.saveItems(...)` after the local replace.
    func reconcileReceiptItems(
        newItems: [ReceiptItem],
        priorSyncIDs: [String],
        transactionSyncID: String
    ) async {
        guard Self.isCloudKitEnabled, isSyncEnabled else { return }
        let newSyncIDs = Set(newItems.map { $0.syncID })
        let removedSyncIDs = priorSyncIDs.filter { !newSyncIDs.contains($0) }

        let saveRecords = newItems.map { cloudKit.receiptItemToRecord($0, transactionSyncID: transactionSyncID) }
        do {
            if !saveRecords.isEmpty {
                try await cloudKit.saveRecords(saveRecords)
            }
        } catch {
            print("Push receipt items batch error: \(error)")
        }

        if !removedSyncIDs.isEmpty {
            let recordIDs = removedSyncIDs.map { cloudKit.recordID(forSyncID: $0, type: CloudKitService.receiptItemType) }
            do {
                try await cloudKit.deleteRecords(recordIDs)
            } catch {
                print("Delete removed receipt items error: \(error)")
                for sid in removedSyncIDs {
                    addPendingDelete(syncID: sid, key: pendingDeletesItemKey, type: CloudKitService.receiptItemType)
                }
            }
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
                } else if name.hasPrefix("\(CloudKitService.friendType)_") {
                    let friendID = String(name.dropFirst(CloudKitService.friendType.count + 1))
                    await db.deleteFriend(id: friendID)
                } else if name.hasPrefix("\(CloudKitService.receiptItemType)_") {
                    let syncID = String(name.dropFirst(CloudKitService.receiptItemType.count + 1))
                    await db.deleteReceiptItemBySyncID(syncID)
                }
            }

            // Process changed records. Friends first so any split
            // transaction that arrives in the same fetch already has
            // its referenced people in the local Friend table when its
            // UI renders.
            var pendingReceiptItems: [(item: ReceiptItem, transactionSyncID: String)] = []
            for record in changed {
                if record.recordType == CloudKitService.friendType {
                    if let remoteFriend = cloudKit.friendFromRecord(record) {
                        let localFriend = await db.fetchFriendByID(remoteFriend.id)
                        if let localFriend {
                            if remoteFriend.lastModified > localFriend.lastModified {
                                await db.updateFriend(remoteFriend)
                            }
                        } else {
                            await db.insertFriend(remoteFriend)
                        }
                    }
                } else if record.recordType == CloudKitService.transactionType {
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
                                    tags: remoteTx.tags, lastModified: remoteTx.lastModified,
                                    repeatInterval: remoteTx.repeatInterval,
                                    parentReminderID: remoteTx.parentReminderID,
                                    splitInfo: remoteTx.splitInfo,
                                    payloadChecksum: remoteTx.payloadChecksum,
                                    excludedFromInsights: remoteTx.excludedFromInsights
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
                } else if record.recordType == CloudKitService.receiptItemType {
                    if let tuple = cloudKit.receiptItemFromRecord(record) {
                        pendingReceiptItems.append(tuple)
                    }
                }
            }

            // Resolve receipt items now that the transactions table is
            // up to date — items reference their parent by syncID, but
            // SQLite stores them keyed to the local autoincrement id.
            if !pendingReceiptItems.isEmpty {
                let (syncIDToID, _) = await loadTransactionIDMaps()
                for (item, txSyncID) in pendingReceiptItems {
                    guard let txID = syncIDToID[txSyncID] else { continue }
                    var stamped = item
                    stamped.transactionID = txID
                    if let local = await db.fetchReceiptItemBySyncID(item.syncID) {
                        if item.lastModified > local.lastModified {
                            stamped.persistedID = local.persistedID
                            await db.updateReceiptItem(stamped)
                        }
                    } else {
                        _ = await db.insertReceiptItem(stamped)
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
                        tags: remoteTx.tags, lastModified: remoteTx.lastModified,
                        repeatInterval: remoteTx.repeatInterval,
                        parentReminderID: remoteTx.parentReminderID,
                        splitInfo: remoteTx.splitInfo,
                        payloadChecksum: remoteTx.payloadChecksum,
                        excludedFromInsights: remoteTx.excludedFromInsights
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

    private func mergeFriends(local: [Friend], remote: [Friend]) -> MergeResult<Friend> {
        var localByID: [String: Friend] = [:]
        for f in local { localByID[f.id] = f }
        var remoteByID: [String: Friend] = [:]
        for f in remote { remoteByID[f.id] = f }

        var toInsertLocally: [Friend] = []
        var toUpdateLocally: [Friend] = []
        var toPushRemote: [Friend] = []

        for (id, remoteFriend) in remoteByID {
            if let localFriend = localByID[id] {
                if remoteFriend.lastModified > localFriend.lastModified {
                    toUpdateLocally.append(remoteFriend)
                } else if localFriend.lastModified > remoteFriend.lastModified {
                    toPushRemote.append(localFriend)
                }
            } else {
                toInsertLocally.append(remoteFriend)
            }
        }
        for (id, localFriend) in localByID {
            if remoteByID[id] == nil {
                toPushRemote.append(localFriend)
            }
        }
        return MergeResult(toInsertLocally: toInsertLocally, toUpdateLocally: toUpdateLocally, toPushRemote: toPushRemote)
    }

    /// Merge receipt items keyed by `syncID`. Remote items only enter
    /// the local DB once their parent transaction has been resolved —
    /// items whose parent isn't present yet are silently dropped from
    /// the insert/update plan; the next pull will pick them up after
    /// the missing transaction lands.
    private func mergeReceiptItems(
        local: [ReceiptItem],
        remote: [(item: ReceiptItem, transactionSyncID: String)],
        transactionIDBySyncID: [String: Int]
    ) -> MergeResult<ReceiptItem> {
        var localBySyncID: [String: ReceiptItem] = [:]
        for item in local { localBySyncID[item.syncID] = item }
        var remoteBySyncID: [String: (item: ReceiptItem, transactionSyncID: String)] = [:]
        for tuple in remote { remoteBySyncID[tuple.item.syncID] = tuple }

        var toInsertLocally: [ReceiptItem] = []
        var toUpdateLocally: [ReceiptItem] = []
        var toPushRemote: [ReceiptItem] = []

        for (syncID, tuple) in remoteBySyncID {
            // Resolve parent — drop the item if we don't have the
            // owning transaction locally yet.
            guard let parentID = transactionIDBySyncID[tuple.transactionSyncID] else { continue }
            var stamped = tuple.item
            stamped.transactionID = parentID

            if let localItem = localBySyncID[syncID] {
                if tuple.item.lastModified > localItem.lastModified {
                    stamped.persistedID = localItem.persistedID
                    toUpdateLocally.append(stamped)
                } else if localItem.lastModified > tuple.item.lastModified {
                    toPushRemote.append(localItem)
                }
            } else {
                toInsertLocally.append(stamped)
            }
        }
        for (syncID, localItem) in localBySyncID {
            if remoteBySyncID[syncID] == nil {
                toPushRemote.append(localItem)
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

        // Friends
        let pendingFriend = UserDefaults.standard.stringArray(forKey: pendingDeletesFriendKey) ?? []
        if !pendingFriend.isEmpty {
            let ids = pendingFriend.map { cloudKit.recordID(forSyncID: $0, type: CloudKitService.friendType) }
            do {
                try await cloudKit.deleteRecords(ids)
                UserDefaults.standard.removeObject(forKey: pendingDeletesFriendKey)
            } catch {
                print("Retry pending friend deletes error: \(error)")
            }
        }

        // Receipt items
        let pendingItem = UserDefaults.standard.stringArray(forKey: pendingDeletesItemKey) ?? []
        if !pendingItem.isEmpty {
            let ids = pendingItem.map { cloudKit.recordID(forSyncID: $0, type: CloudKitService.receiptItemType) }
            do {
                try await cloudKit.deleteRecords(ids)
                UserDefaults.standard.removeObject(forKey: pendingDeletesItemKey)
            } catch {
                print("Retry pending receipt item deletes error: \(error)")
            }
        }
    }

    // MARK: - Reload stores

    private func reloadStores() async {
        await transactionStore?.load()
        await categoryStore?.reloadFromDB()
        await friendStore?.load()
        await receiptItemStore?.load()
    }
}

// MARK: - SyncAction

enum SyncAction {
    case save
    case delete
}

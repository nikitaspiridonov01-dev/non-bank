import Foundation
import CloudKit

final class CloudKitService {
    static let shared = CloudKitService()

    private var _container: CKContainer?
    private var _containerChecked = false
    private var container: CKContainer? {
        if !_containerChecked {
            _containerChecked = true
            // ubiquityIdentityToken is nil when iCloud is not signed in or entitlement is missing
            guard FileManager.default.ubiquityIdentityToken != nil else {
                return nil
            }
            _container = CKContainer.default()
        }
        return _container
    }
    private var privateDB: CKDatabase? { container?.privateCloudDatabase }
    private let zoneName = "NonBankZone"
    private lazy var customZone = CKRecordZone(zoneName: zoneName)

    static let transactionType = "Transaction"
    static let categoryType = "Category"
    static let friendType = "Friend"
    static let receiptItemType = "ReceiptItem"

    private let changeTokenKey = "ck_serverChangeToken"

    private init() {}

    // MARK: - Availability

    func checkAccountStatus() async -> CKAccountStatus {
        guard let container else { return .noAccount }
        do {
            return try await container.accountStatus()
        } catch {
            print("CloudKit account status error: \(error)")
            return .couldNotDetermine
        }
    }

    // MARK: - Zone Setup

    func createCustomZoneIfNeeded() async throws {
        guard let privateDB else { throw CloudKitSyncError.notAvailable }
        let zoneCreatedKey = "ck_zoneCreated"
        if UserDefaults.standard.bool(forKey: zoneCreatedKey) { return }
        do {
            _ = try await privateDB.save(customZone)
            UserDefaults.standard.set(true, forKey: zoneCreatedKey)
        } catch let error as CKError where error.code == .serverRecordChanged || error.code == .zoneNotFound {
            _ = try await privateDB.save(customZone)
            UserDefaults.standard.set(true, forKey: zoneCreatedKey)
        }
    }

    // MARK: - Subscriptions

    func createSubscriptionIfNeeded() async throws {
        guard let privateDB else { throw CloudKitSyncError.notAvailable }
        let subKey = "ck_subscriptionCreated"
        if UserDefaults.standard.bool(forKey: subKey) { return }

        let subscription = CKDatabaseSubscription(subscriptionID: "non-bank-private-changes")
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        do {
            _ = try await privateDB.save(subscription)
            UserDefaults.standard.set(true, forKey: subKey)
        } catch let error as CKError where error.code == .serverRejectedRequest {
            // Already exists
            UserDefaults.standard.set(true, forKey: subKey)
        }
    }

    // MARK: - Transaction ↔ CKRecord

    private func zoneID() -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
    }

    func recordID(forSyncID syncID: String, type: String) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(type)_\(syncID)", zoneID: zoneID())
    }

    func transactionToRecord(_ tx: Transaction) -> CKRecord {
        let rid = recordID(forSyncID: tx.syncID, type: Self.transactionType)
        let record = CKRecord(recordType: Self.transactionType, recordID: rid)
        record["syncID"] = tx.syncID as CKRecordValue
        record["emoji"] = tx.emoji as CKRecordValue
        record["category"] = tx.category as CKRecordValue
        record["title"] = tx.title as CKRecordValue
        record["desc"] = (tx.description ?? "") as CKRecordValue
        record["amount"] = tx.amount as CKRecordValue
        record["currency"] = tx.currency as CKRecordValue
        record["date"] = tx.date as CKRecordValue
        record["type"] = tx.type.rawValue as CKRecordValue
        record["lastModified"] = tx.lastModified as CKRecordValue

        // Tags — JSON-encoded so the array survives round-trip. Earlier
        // versions hard-coded `""` here, so missing/empty values on pull
        // decode back to `nil`.
        if let tags = tx.tags, !tags.isEmpty,
           let data = try? JSONEncoder().encode(tags),
           let str = String(data: data, encoding: .utf8) {
            record["tags"] = str as CKRecordValue
        }

        // New fields — stored as JSON strings (nil-safe)
        if let ri = tx.repeatInterval, let data = try? JSONEncoder().encode(ri) {
            record["repeatInterval"] = String(data: data, encoding: .utf8) as? CKRecordValue
        }
        if let pid = tx.parentReminderID {
            record["parentReminderID"] = pid as CKRecordValue
        }
        if let si = tx.splitInfo, let data = try? JSONEncoder().encode(si) {
            record["splitInfo"] = String(data: data, encoding: .utf8) as? CKRecordValue
        }
        // Share-link re-import classifier (Phase 4). Without this on
        // sync the receiver device can't tell "I've already seen this
        // exact link" from "the sharer edited and re-shared it."
        if let checksum = tx.payloadChecksum {
            record["payloadChecksum"] = checksum as CKRecordValue
        }
        // Per-tx insights exclusion. Synced so the user's hide decision
        // travels with the transaction across their devices (see
        // InsightsSettings for the global toggle, which is synced
        // separately via NSUbiquitousKeyValueStore).
        record["excludedFromInsights"] = (tx.excludedFromInsights ? 1 : 0) as CKRecordValue
        // Monotonic split-sync version guard. CloudKit (own-device sync)
        // must carry this so a transaction round-tripped through iCloud
        // keeps its editVersion instead of resetting to 0 and breaking
        // SyncEngine.pullAndApply's version comparison.
        record["editVersion"] = tx.editVersion as CKRecordValue

        return record
    }

    func transactionFromRecord(_ record: CKRecord) -> Transaction? {
        guard let syncID = record["syncID"] as? String,
              let emoji = record["emoji"] as? String,
              let category = record["category"] as? String,
              let title = record["title"] as? String,
              let amount = record["amount"] as? Double,
              let currency = record["currency"] as? String,
              let date = record["date"] as? Date,
              let typeRaw = record["type"] as? String,
              let lastModified = record["lastModified"] as? Date
        else { return nil }

        let desc = record["desc"] as? String
        let type = TransactionType(rawValue: typeRaw) ?? .expenses
        // Decode new optional fields
        var repeatInterval: RepeatInterval?
        if let riJSON = record["repeatInterval"] as? String,
           let riData = riJSON.data(using: .utf8) {
            repeatInterval = try? JSONDecoder().decode(RepeatInterval.self, from: riData)
        }
        let parentReminderID = record["parentReminderID"] as? Int
        var splitInfo: SplitInfo?
        if let siJSON = record["splitInfo"] as? String,
           let siData = siJSON.data(using: .utf8) {
            splitInfo = try? JSONDecoder().decode(SplitInfo.self, from: siData)
        }
        var tags: [String]?
        if let tagsJSON = record["tags"] as? String, !tagsJSON.isEmpty,
           let tagsData = tagsJSON.data(using: .utf8) {
            tags = try? JSONDecoder().decode([String].self, from: tagsData)
        }
        let payloadChecksum = record["payloadChecksum"] as? String
        // Missing key = false (rows that pre-date the feature on either
        // side default to "counted in insights").
        let excludedFromInsights = (record["excludedFromInsights"] as? Int).map { $0 != 0 } ?? false
        // Missing key = 0 (legacy records that pre-date this field on
        // either device default to the lowest version).
        let editVersion = record["editVersion"] as? Int ?? 0

        return Transaction(
            id: 0, syncID: syncID, emoji: emoji, category: category,
            title: title, description: desc?.isEmpty == true ? nil : desc,
            amount: amount, currency: currency, date: date,
            type: type, tags: tags, lastModified: lastModified,
            repeatInterval: repeatInterval, parentReminderID: parentReminderID, splitInfo: splitInfo,
            payloadChecksum: payloadChecksum,
            excludedFromInsights: excludedFromInsights,
            editVersion: editVersion
        )
    }

    // MARK: - Category ↔ CKRecord

    func categoryToRecord(_ cat: Category) -> CKRecord {
        let rid = recordID(forSyncID: cat.id.uuidString, type: Self.categoryType)
        let record = CKRecord(recordType: Self.categoryType, recordID: rid)
        record["categoryID"] = cat.id.uuidString as CKRecordValue
        record["emoji"] = cat.emoji as CKRecordValue
        record["title"] = cat.title as CKRecordValue
        record["lastModified"] = cat.lastModified as CKRecordValue
        return record
    }

    func categoryFromRecord(_ record: CKRecord) -> Category? {
        guard let idString = record["categoryID"] as? String,
              let uuid = UUID(uuidString: idString),
              let emoji = record["emoji"] as? String,
              let title = record["title"] as? String,
              let lastModified = record["lastModified"] as? Date
        else { return nil }
        return Category(id: uuid, emoji: emoji, title: title, lastModified: lastModified)
    }

    // MARK: - Friend ↔ CKRecord
    //
    // Friends are first-class CloudKit records so that split-transaction
    // friendID references stay meaningful across devices. The receiver
    // would otherwise see a UUID that doesn't resolve to anyone in
    // FriendStore — the avatar renders as a phantom and groups /
    // splitMode / `isConnected` would all be lost.

    func friendToRecord(_ friend: Friend) -> CKRecord {
        let rid = recordID(forSyncID: friend.id, type: Self.friendType)
        let record = CKRecord(recordType: Self.friendType, recordID: rid)
        record["friendID"] = friend.id as CKRecordValue
        record["name"] = friend.name as CKRecordValue
        record["lastModified"] = friend.lastModified as CKRecordValue
        record["isConnected"] = (friend.isConnected ? 1 : 0) as CKRecordValue
        if !friend.groups.isEmpty,
           let data = try? JSONEncoder().encode(friend.groups),
           let str = String(data: data, encoding: .utf8) {
            record["groups"] = str as CKRecordValue
        }
        if let mode = friend.splitMode {
            record["splitMode"] = mode.rawValue as CKRecordValue
        }
        return record
    }

    func friendFromRecord(_ record: CKRecord) -> Friend? {
        guard let id = record["friendID"] as? String,
              let name = record["name"] as? String,
              let lastModified = record["lastModified"] as? Date
        else { return nil }
        let isConnected = (record["isConnected"] as? Int).map { $0 != 0 } ?? false
        var groups: [String] = []
        if let str = record["groups"] as? String,
           let data = str.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            groups = decoded
        }
        let splitMode: SplitMode? = (record["splitMode"] as? String).flatMap { SplitMode(rawValue: $0) }
        return Friend(
            id: id, name: name, groups: groups,
            splitMode: splitMode, lastModified: lastModified,
            isConnected: isConnected
        )
    }

    // MARK: - ReceiptItem ↔ CKRecord
    //
    // Receipt items reference their parent transaction by the parent's
    // stable `syncID` (not the local autoincrement, which differs per
    // device). The receiver resolves `transactionSyncID` to a local
    // `transactionID` after the parent transaction is in place.

    func receiptItemToRecord(_ item: ReceiptItem, transactionSyncID: String) -> CKRecord {
        let rid = recordID(forSyncID: item.syncID, type: Self.receiptItemType)
        let record = CKRecord(recordType: Self.receiptItemType, recordID: rid)
        record["syncID"] = item.syncID as CKRecordValue
        record["transactionSyncID"] = transactionSyncID as CKRecordValue
        record["name"] = item.name as CKRecordValue
        record["position"] = item.position as CKRecordValue
        record["lastModified"] = item.lastModified as CKRecordValue
        if let q = item.quantity { record["quantity"] = q as CKRecordValue }
        if let p = item.price { record["price"] = p as CKRecordValue }
        if let t = item.total { record["total"] = t as CKRecordValue }
        if !item.assignedParticipantIDs.isEmpty,
           let data = try? JSONEncoder().encode(item.assignedParticipantIDs),
           let str = String(data: data, encoding: .utf8) {
            record["assignedParticipantIDs"] = str as CKRecordValue
        }
        return record
    }

    /// Decode a receipt-item record. Returns both the rebuilt
    /// `ReceiptItem` (with `transactionID = nil` — caller resolves it
    /// after fetching the parent transaction) and the parent's syncID.
    func receiptItemFromRecord(_ record: CKRecord) -> (item: ReceiptItem, transactionSyncID: String)? {
        guard let syncID = record["syncID"] as? String,
              let transactionSyncID = record["transactionSyncID"] as? String,
              let name = record["name"] as? String,
              let lastModified = record["lastModified"] as? Date
        else { return nil }
        let position = record["position"] as? Int ?? 0
        let quantity = record["quantity"] as? Double
        let price = record["price"] as? Double
        let total = record["total"] as? Double
        var assigned: [String] = []
        if let str = record["assignedParticipantIDs"] as? String,
           let data = str.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            assigned = decoded
        }
        let item = ReceiptItem(
            name: name, quantity: quantity, price: price, total: total,
            assignedParticipantIDs: assigned,
            persistedID: nil, transactionID: nil,
            syncID: syncID, position: position, lastModified: lastModified
        )
        return (item, transactionSyncID)
    }

    // MARK: - Save / Delete

    func saveRecords(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        guard let privateDB else { throw CloudKitSyncError.notAvailable }
        let batchSize = 400
        for start in stride(from: 0, to: records.count, by: batchSize) {
            let end = min(start + batchSize, records.count)
            let batch = Array(records[start..<end])
            let operation = CKModifyRecordsOperation(recordsToSave: batch, recordIDsToDelete: nil)
            operation.savePolicy = .changedKeys
            operation.isAtomic = false
            try await privateDB.add(operation)
        }
    }

    func deleteRecords(_ recordIDs: [CKRecord.ID]) async throws {
        guard !recordIDs.isEmpty else { return }
        guard let privateDB else { throw CloudKitSyncError.notAvailable }
        let batchSize = 400
        for start in stride(from: 0, to: recordIDs.count, by: batchSize) {
            let end = min(start + batchSize, recordIDs.count)
            let batch = Array(recordIDs[start..<end])
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)
            operation.isAtomic = false
            try await privateDB.add(operation)
        }
    }

    // MARK: - Fetch all records of a type

    func fetchAllRecords(ofType type: String) async throws -> [CKRecord] {
        guard let privateDB else { throw CloudKitSyncError.notAvailable }
        var results: [CKRecord] = []
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: type, predicate: predicate)
        let zone = zoneID()

        do {
            var cursor: CKQueryOperation.Cursor?
            let (firstResults, firstCursor) = try await privateDB.records(matching: query, inZoneWith: zone, resultsLimit: CKQueryOperation.maximumResults)
            for (_, result) in firstResults {
                if let record = try? result.get() {
                    results.append(record)
                }
            }
            cursor = firstCursor

            while let currentCursor = cursor {
                let (moreResults, nextCursor) = try await privateDB.records(continuingMatchFrom: currentCursor, resultsLimit: CKQueryOperation.maximumResults)
                for (_, result) in moreResults {
                    if let record = try? result.get() {
                        results.append(record)
                    }
                }
                cursor = nextCursor
            }
            return results
        } catch let error as CKError where Self.isMissingRecordType(error) {
            // The record type doesn't exist in the schema yet. This is
            // the expected state on a fresh CloudKit container before
            // anything has been pushed — the development environment
            // auto-creates record types only on the first *save*, but
            // `performInitialSync` queries (fetch) first. Treat a
            // missing type as "no remote records" so the sync proceeds
            // to the push step, which creates the schema; every
            // subsequent fetch of that type then succeeds. Without this
            // the first-ever sync on a new container always errored
            // with "Did not find record type: Transaction".
            return []
        }
    }

    /// True when a CloudKit query failed because the queried record type
    /// isn't in the container schema yet (fresh container, nothing
    /// pushed). `unknownItem` is the documented code; the server's
    /// "Did not find record type: X" message is matched as a
    /// cross-version fallback.
    private static func isMissingRecordType(_ error: CKError) -> Bool {
        if error.code == .unknownItem { return true }
        let desc = error.localizedDescription.lowercased()
        return desc.contains("did not find record type")
            || desc.contains("unknown record type")
    }

    // MARK: - Fetch changes (delta sync)

    func fetchChanges() async throws -> (changed: [CKRecord], deletedIDs: [CKRecord.ID]) {
        guard let privateDB else { throw CloudKitSyncError.notAvailable }
        let tokenData = UserDefaults.standard.data(forKey: changeTokenKey)
        let token: CKServerChangeToken? = tokenData.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }

        var changedRecords: [CKRecord] = []
        var deletedRecordIDs: [CKRecord.ID] = []

        let config = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        config.previousServerChangeToken = token

        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [zoneID()], configurationsByRecordZoneID: [zoneID(): config])

        return try await withCheckedThrowingContinuation { continuation in
            operation.recordWasChangedBlock = { _, result in
                if let record = try? result.get() {
                    changedRecords.append(record)
                }
            }
            operation.recordWithIDWasDeletedBlock = { recordID, _ in
                deletedRecordIDs.append(recordID)
            }
            operation.recordZoneChangeTokensUpdatedBlock = { [weak self] _, newToken, _ in
                guard let self, let newToken else { return }
                if let data = try? NSKeyedArchiver.archivedData(withRootObject: newToken, requiringSecureCoding: true) {
                    UserDefaults.standard.set(data, forKey: self.changeTokenKey)
                }
            }
            operation.recordZoneFetchResultBlock = { [weak self] _, result in
                guard let self else { return }
                switch result {
                case .success(let (serverChangeToken, _, _)):
                    if let data = try? NSKeyedArchiver.archivedData(withRootObject: serverChangeToken, requiringSecureCoding: true) {
                        UserDefaults.standard.set(data, forKey: self.changeTokenKey)
                    }
                case .failure:
                    break
                }
            }
            operation.fetchRecordZoneChangesResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: (changedRecords, deletedRecordIDs))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            privateDB.add(operation)
        }
    }

    // MARK: - Reset change token

    func resetChangeToken() {
        UserDefaults.standard.removeObject(forKey: changeTokenKey)
    }
}

// MARK: - CKDatabase async helper for CKModifyRecordsOperation
extension CKDatabase {
    func add(_ operation: CKModifyRecordsOperation) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            self.add(operation)
        }
    }
}

enum CloudKitSyncError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable:
            return "iCloud is not available. Please sign in to iCloud in Settings."
        }
    }
}

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
        record["tags"] = "" as CKRecordValue
        record["lastModified"] = tx.lastModified as CKRecordValue

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

        return Transaction(
            id: 0, syncID: syncID, emoji: emoji, category: category,
            title: title, description: desc?.isEmpty == true ? nil : desc,
            amount: amount, currency: currency, date: date,
            type: type, tags: nil, lastModified: lastModified,
            repeatInterval: repeatInterval, parentReminderID: parentReminderID, splitInfo: splitInfo
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

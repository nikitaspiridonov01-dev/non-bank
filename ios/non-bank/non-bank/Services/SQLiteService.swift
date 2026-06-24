import Foundation
import SQLite3

class SQLiteService: DatabaseProtocol {
    static let shared = SQLiteService()
    private var db: OpaquePointer?
    private let dbName = "app-data.sqlite"
    // 1. Serial queue for DB operations
    private let dbQueue = DispatchQueue(label: "com.app.sqliteQueue", qos: .userInitiated)

    private static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        return e
    }()

    private static let jsonDecoder: JSONDecoder = {
        let d = JSONDecoder()
        return d
    }()

    private func encodeJSON<T: Encodable>(_ value: T?) -> String? {
        guard let value else { return nil }
        guard let data = try? Self.jsonEncoder.encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeJSON<T: Decodable>(_ type: T.Type, from text: String?) -> T? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? Self.jsonDecoder.decode(type, from: data)
    }

    private init() {
        dbQueue.sync {
            openDatabase()
            createTransactionTable()
            createCategoryTable()
            createFriendsTable()
            createReceiptItemsTable()
            migrateSchema()
        }
    }

    private func openDatabase() {
        let fileManager = FileManager.default
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let appSupportDir = urls[0]
        // Ensure Application Support directory exists
        if !fileManager.fileExists(atPath: appSupportDir.path) {
            try? fileManager.createDirectory(at: appSupportDir, withIntermediateDirectories: true)
        }
        let dbURL = appSupportDir.appendingPathComponent(dbName)
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            print("Failed to open database")
        }
    }

    private func createTransactionTable() {
        let createTableString = """
        CREATE TABLE IF NOT EXISTS transactions (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            emoji TEXT NOT NULL,
            category TEXT NOT NULL,
            title TEXT NOT NULL,
            description TEXT,
            amount REAL NOT NULL,
            currency TEXT NOT NULL,
            date REAL NOT NULL,
            type TEXT NOT NULL,
            isIncome INTEGER NOT NULL,
            tags TEXT
        );
        """
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                // Table created
            }
        }
        sqlite3_finalize(createTableStatement)
    }

    private func createCategoryTable() {
        let createTableString = """
        CREATE TABLE IF NOT EXISTS categories (
            id TEXT PRIMARY KEY,
            emoji TEXT NOT NULL UNIQUE,
            title TEXT NOT NULL UNIQUE
        );
        """
        var createTableStatement: OpaquePointer?
        if sqlite3_prepare_v2(db, createTableString, -1, &createTableStatement, nil) == SQLITE_OK {
            if sqlite3_step(createTableStatement) == SQLITE_DONE {
                // Table created
            }
        }
        sqlite3_finalize(createTableStatement)
    }

    private func createFriendsTable() {
        let sql = """
        CREATE TABLE IF NOT EXISTS friends (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            groups_json TEXT,
            split_mode TEXT,
            last_modified REAL NOT NULL,
            is_connected INTEGER NOT NULL DEFAULT 0
        );
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            if sqlite3_step(statement) == SQLITE_DONE {
                // Table created
            }
        }
        sqlite3_finalize(statement)
    }

    private func createReceiptItemsTable() {
        // Receipt items belonging to a transaction. We don't enable SQLite
        // foreign-key cascading (legacy connections may not have FKs on); the
        // store's `delete(id:)` flow explicitly deletes children instead.
        //
        // `assigned_participant_ids` stores the JSON-encoded array of
        // participant IDs (Friend.id strings or `__me__`) responsible for
        // this line in a `byItems` split. NULL/empty for receipts created
        // outside a `byItems` flow — they don't need item-level assignment.
        let sql = """
        CREATE TABLE IF NOT EXISTS receipt_items (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            sync_id TEXT NOT NULL UNIQUE,
            transaction_id INTEGER NOT NULL,
            position INTEGER NOT NULL DEFAULT 0,
            name TEXT NOT NULL,
            quantity REAL,
            price REAL,
            total REAL,
            last_modified REAL NOT NULL,
            assigned_participant_ids TEXT
        );
        """
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK {
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        exec("CREATE INDEX IF NOT EXISTS idx_receipt_items_tx ON receipt_items(transaction_id);")
    }

    // MARK: - Schema Migration

    private func migrateSchema() {
        // Add sync_id and last_modified columns to transactions if missing
        if !columnExists("sync_id", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN sync_id TEXT;")
            // Backfill existing rows with unique sync IDs
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT id FROM transactions WHERE sync_id IS NULL;", -1, &stmt, nil) == SQLITE_OK {
                while sqlite3_step(stmt) == SQLITE_ROW {
                    let rowId = sqlite3_column_int(stmt, 0)
                    let uuid = UUID().uuidString
                    exec("UPDATE transactions SET sync_id = '\(uuid)' WHERE id = \(rowId);")
                }
            }
            sqlite3_finalize(stmt)
        }
        if !columnExists("last_modified", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN last_modified REAL;")
            let now = Date().timeIntervalSince1970
            exec("UPDATE transactions SET last_modified = \(now) WHERE last_modified IS NULL;")
        }
        // Add last_modified column to categories if missing
        if !columnExists("last_modified", in: "categories") {
            exec("ALTER TABLE categories ADD COLUMN last_modified REAL;")
            let now = Date().timeIntervalSince1970
            exec("UPDATE categories SET last_modified = \(now) WHERE last_modified IS NULL;")
        }

        // --- Recurring transactions ---
        if !columnExists("repeat_interval", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN repeat_interval TEXT;")
        }
        if !columnExists("parent_reminder_id", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN parent_reminder_id INTEGER;")
        }

        // --- Split transactions ---
        if !columnExists("split_info", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN split_info TEXT;")
        }

        // --- Share-link checksum (Phase 4 receiver flow) ---
        // Recorded for transactions imported from a friend's share link.
        // Lets `ShareIntentClassifier` decide whether a re-import is
        // identical (no-op) or an edit (prompt the user). NULL on rows
        // that pre-date this feature or were created locally.
        if !columnExists("payload_checksum", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN payload_checksum TEXT;")
        }

        // --- Per-transaction exclude-from-insights flag ---
        // User can hide an individual transaction from analytics from
        // the detail view or a row swipe action. Stored as 0/1; default
        // 0 (counted) for pre-existing rows.
        if !columnExists("excluded_from_insights", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN excluded_from_insights INTEGER NOT NULL DEFAULT 0;")
        }

        // --- Server-sync edit version ---
        // Monotonic per-transaction edit counter for server-mediated
        // sync's version guard. Default 0 for pre-existing rows.
        if !columnExists("edit_version", in: "transactions") {
            exec("ALTER TABLE transactions ADD COLUMN edit_version INTEGER NOT NULL DEFAULT 0;")
        }

        // --- Friends v2: add groups_json, split_mode columns ---
        if !columnExists("groups_json", in: "friends") {
            exec("ALTER TABLE friends ADD COLUMN groups_json TEXT;")
        }
        if !columnExists("split_mode", in: "friends") {
            exec("ALTER TABLE friends ADD COLUMN split_mode TEXT;")
        }
        // --- Friends v4: connection state ---
        // True when this friend's id is a real userID (set by share-link
        // import or phantom-upgrade flow). Drives colored vs B&W avatar.
        // Existing rows default to 0 (= phantom) which is correct: nothing
        // before this point could have been "connected".
        if !columnExists("is_connected", in: "friends") {
            exec("ALTER TABLE friends ADD COLUMN is_connected INTEGER NOT NULL DEFAULT 0;")
        }

        // --- Receipt items: per-line assignment for `byItems` split mode ---
        // Stores the JSON-encoded array of participant IDs that bought a
        // given line. NULL on rows that pre-date the feature; the read
        // path treats NULL as the empty array.
        if !columnExists("assigned_participant_ids", in: "receipt_items") {
            exec("ALTER TABLE receipt_items ADD COLUMN assigned_participant_ids TEXT;")
        }

        // --- Receipt items: stored kind override for manual tips ---
        // `forced_kind` stores `ReceiptItem.Kind.rawValue` (e.g. "tip") for
        // a manually-added tip line, so it keeps behaving as a tip after
        // reload even though tip keywords no longer auto-classify. NULL on
        // rows that pre-date the feature and on every auto-parsed line; the
        // read path maps NULL → nil → name-based classification.
        if !columnExists("forced_kind", in: "receipt_items") {
            exec("ALTER TABLE receipt_items ADD COLUMN forced_kind TEXT;")
        }

        // --- Friends v3: remove legacy emoji column ---
        // Old schema had `emoji TEXT NOT NULL` which blocks new inserts that omit it.
        // SQLite ALTER TABLE DROP COLUMN requires 3.35+; safer to recreate the table.
        if columnExists("emoji", in: "friends") {
            exec("""
                CREATE TABLE IF NOT EXISTS friends_new (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    groups_json TEXT,
                    split_mode TEXT,
                    last_modified REAL NOT NULL
                );
            """)
            exec("INSERT OR IGNORE INTO friends_new (id, name, groups_json, split_mode, last_modified) SELECT id, name, groups_json, split_mode, last_modified FROM friends;")
            exec("DROP TABLE friends;")
            exec("ALTER TABLE friends_new RENAME TO friends;")
        }

        // --- Durable de-dup guard on synced transactions ---
        // `sync_id` is the stable cross-device identity of a synced
        // transaction. Dedup historically lived ONLY in app code
        // (`TransactionStore.insertOrUpdateBySyncID` + the SyncEngine
        // existing-by-syncID lookup); with no DB constraint, any timing race
        // that bypassed the in-memory snapshot could fork a second row for
        // the same `sync_id`. This migration adds the DB-level backstop:
        // collapse any rows that already duplicated a non-empty `sync_id`,
        // then enforce uniqueness going forward with a partial UNIQUE index.
        // Gated on the index not yet existing, so the one-time collapse runs
        // only on the upgrading launch and the whole block is a no-op every
        // launch after. It is also self-idempotent if it ever does re-run:
        // both collapses do nothing once there are no dups/orphans, and the
        // index uses IF NOT EXISTS.
        if !indexExists("idx_transactions_sync_id") {
            // (a) Collapse existing duplicate forks that share a non-empty
            // `sync_id`, keeping the AUTHORITATIVE row and deleting the rest.
            // Authoritative = the NEWEST edit, matching the rest of the sync
            // model (last-write-wins / monotonic `edit_version`): within each
            // group, keep the maximum by (edit_version, last_modified, id) and
            // delete every row that has a strictly-greater sibling.
            //
            // It is NOT correct to keep MIN(id): a fork is by construction a
            // LATER insert (e.g. a friend's edit applied while the in-memory
            // snapshot was stale — the very race this index backstops), so the
            // higher-id row usually carries the NEWER amount/split/editVersion.
            // Keeping the oldest would silently and irreversibly discard the
            // user's most recent edit (the originating delivery is already
            // acked, so nothing re-delivers to repair it). COALESCE guards rows
            // from before `edit_version`/`last_modified` existed (NULL sorts
            // oldest). `id` is unique, so the ordering is a strict total order
            // → exactly one survivor per group. Rows with NULL/empty `sync_id`
            // are local-only, never duplicates, and are left untouched.
            exec("""
                DELETE FROM transactions
                WHERE sync_id IS NOT NULL AND sync_id != ''
                  AND EXISTS (
                      SELECT 1 FROM transactions newer
                      WHERE newer.sync_id = transactions.sync_id
                        AND newer.id != transactions.id
                        AND (
                            COALESCE(newer.edit_version, 0) > COALESCE(transactions.edit_version, 0)
                         OR (COALESCE(newer.edit_version, 0) = COALESCE(transactions.edit_version, 0)
                             AND COALESCE(newer.last_modified, 0) > COALESCE(transactions.last_modified, 0))
                         OR (COALESCE(newer.edit_version, 0) = COALESCE(transactions.edit_version, 0)
                             AND COALESCE(newer.last_modified, 0) = COALESCE(transactions.last_modified, 0)
                             AND newer.id > transactions.id)
                        )
                  );
            """)
            // (b) Reap `receipt_items` orphaned by the collapse (plus any
            // pre-existing orphans). `receipt_items.transaction_id` has no FK
            // cascade, so a deleted fork's items would otherwise linger forever
            // pointing at a gone row AND the surviving row would read back an
            // empty breakdown. The authoritative survivor kept ITS OWN items
            // (saved against its id), so the doomed forks' item rows are stale
            // duplicates — delete them. `transactions.id` is NOT NULL, so the
            // `NOT IN` form is safe from the NULL-in-NOT-IN pitfall.
            exec("""
                DELETE FROM receipt_items
                WHERE transaction_id NOT IN (SELECT id FROM transactions);
            """)
            // (c) Enforce uniqueness from here on. Partial index so the
            // constraint covers only genuinely-synced rows; NULL/empty
            // `sync_id` rows can still coexist freely. The transaction insert
            // path's `ON CONFLICT(sync_id)` upsert targets exactly this
            // index — its conflict-target WHERE must repeat this predicate.
            exec("""
                CREATE UNIQUE INDEX IF NOT EXISTS idx_transactions_sync_id
                ON transactions(sync_id)
                WHERE sync_id IS NOT NULL AND sync_id != '';
            """)
        }
    }

    private func columnExists(_ column: String, in table: String) -> Bool {
        var stmt: OpaquePointer?
        let query = "PRAGMA table_info(\(table));"
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 1) {
                    let name = String(cString: cString)
                    if name == column {
                        sqlite3_finalize(stmt)
                        return true
                    }
                }
            }
        }
        sqlite3_finalize(stmt)
        return false
    }

    /// True when an index with `name` already exists in the schema. Used to
    /// gate one-shot index-creation migrations the same way `columnExists`
    /// gates column-addition ones, so the block runs once on the upgrading
    /// launch and is skipped on every launch thereafter.
    private func indexExists(_ name: String) -> Bool {
        var stmt: OpaquePointer?
        let query = "SELECT 1 FROM sqlite_master WHERE type = 'index' AND name = ? LIMIT 1;"
        var exists = false
        if sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (name as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                exists = true
            }
        }
        sqlite3_finalize(stmt)
        return exists
    }

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func close() {
        sqlite3_close(db)
    }

    // MARK: - CRUD for Transaction

    private func bindTransactionFields(_ statement: OpaquePointer?, _ transaction: Transaction, idOffset: Int = 0) {
        sqlite3_bind_text(statement, 1, (transaction.emoji as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 2, (transaction.category as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 3, (transaction.title as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 4, ((transaction.description ?? "") as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 5, transaction.amount)
        sqlite3_bind_text(statement, 6, (transaction.currency as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 7, transaction.date.timeIntervalSince1970)
        sqlite3_bind_text(statement, 8, (transaction.type.rawValue as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 9, transaction.isIncome ? 1 : 0)
        let tagsString = transaction.tags?.joined(separator: ",") ?? ""
        sqlite3_bind_text(statement, 10, (tagsString as NSString).utf8String, -1, nil)
        sqlite3_bind_text(statement, 11, (transaction.syncID as NSString).utf8String, -1, nil)
        sqlite3_bind_double(statement, 12, transaction.lastModified.timeIntervalSince1970)
        // New fields
        if let riJSON = encodeJSON(transaction.repeatInterval) {
            sqlite3_bind_text(statement, 13, (riJSON as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 13)
        }
        if let parentID = transaction.parentReminderID {
            sqlite3_bind_int(statement, 14, Int32(parentID))
        } else {
            sqlite3_bind_null(statement, 14)
        }
        if let siJSON = encodeJSON(transaction.splitInfo) {
            sqlite3_bind_text(statement, 15, (siJSON as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 15)
        }
        // Phase 4: share-link payload checksum. NULL for locally-created
        // transactions; a 64-char hex SHA-256 string for ones imported
        // from a friend's share link.
        if let checksum = transaction.payloadChecksum {
            sqlite3_bind_text(statement, 16, (checksum as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, 16)
        }
        sqlite3_bind_int(statement, 17, transaction.excludedFromInsights ? 1 : 0)
        sqlite3_bind_int(statement, 18, Int32(transaction.editVersion))
    }

    // Upsert: a duplicate `sync_id` reconciles the existing row in place
    // instead of forking a second one. This is the DB-level backstop under
    // `TransactionStore.insertOrUpdateBySyncID`'s in-memory fast-path — even
    // if a timing race slips past the app-level dedup, the partial UNIQUE
    // index on `sync_id` (see `migrateSchema`) turns the second insert into
    // an UPDATE of the existing row rather than a SQLITE_CONSTRAINT failure.
    // The conflict target repeats the index's WHERE predicate, which SQLite
    // requires to match a *partial* unique index; rows with a NULL/empty
    // `sync_id` (local-only) fall outside the index and just insert normally.
    // `sync_id` itself is never rewritten (it's the conflict key); every
    // other column is overwritten with the incoming values — last-write-wins,
    // matching the app-level update path.
    private static let transactionInsertSQL = """
        INSERT INTO transactions (emoji, category, title, description, amount, currency, date, type, isIncome, tags, sync_id, last_modified, repeat_interval, parent_reminder_id, split_info, payload_checksum, excluded_from_insights, edit_version)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(sync_id) WHERE sync_id IS NOT NULL AND sync_id != '' DO UPDATE SET
            emoji = excluded.emoji,
            category = excluded.category,
            title = excluded.title,
            description = excluded.description,
            amount = excluded.amount,
            currency = excluded.currency,
            date = excluded.date,
            type = excluded.type,
            isIncome = excluded.isIncome,
            tags = excluded.tags,
            last_modified = excluded.last_modified,
            repeat_interval = excluded.repeat_interval,
            parent_reminder_id = excluded.parent_reminder_id,
            split_info = excluded.split_info,
            payload_checksum = excluded.payload_checksum,
            excluded_from_insights = excluded.excluded_from_insights,
            edit_version = excluded.edit_version;
        """

    func insert(transaction: Transaction) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, Self.transactionInsertSQL, -1, &statement, nil) == SQLITE_OK {
                    self.bindTransactionFields(statement, transaction)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to insert transaction")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    private func readTransactionRow(_ statement: OpaquePointer?) -> Transaction {
        let id = Int(sqlite3_column_int(statement, 0))
        let emoji = String(cString: sqlite3_column_text(statement, 1))
        let category = String(cString: sqlite3_column_text(statement, 2))
        let title = String(cString: sqlite3_column_text(statement, 3))
        let description = String(cString: sqlite3_column_text(statement, 4))
        let amount = sqlite3_column_double(statement, 5)
        let currency = String(cString: sqlite3_column_text(statement, 6))
        let date = Date(timeIntervalSince1970: sqlite3_column_double(statement, 7))
        let typeRaw = String(cString: sqlite3_column_text(statement, 8))
        let type = TransactionType(rawValue: typeRaw) ?? .expenses
        let tagsString = String(cString: sqlite3_column_text(statement, 10))
        let tags = tagsString.isEmpty ? [] : tagsString.components(separatedBy: ",")
        let syncID: String
        if sqlite3_column_type(statement, 11) != SQLITE_NULL, let ptr = sqlite3_column_text(statement, 11) {
            syncID = String(cString: ptr)
        } else {
            syncID = UUID().uuidString
        }
        let lastModified: Date
        if sqlite3_column_type(statement, 12) != SQLITE_NULL {
            lastModified = Date(timeIntervalSince1970: sqlite3_column_double(statement, 12))
        } else {
            lastModified = Date()
        }
        // New fields
        var repeatInterval: RepeatInterval? = nil
        if sqlite3_column_type(statement, 13) != SQLITE_NULL, let ptr = sqlite3_column_text(statement, 13) {
            repeatInterval = decodeJSON(RepeatInterval.self, from: String(cString: ptr))
        }
        var parentReminderID: Int? = nil
        if sqlite3_column_type(statement, 14) != SQLITE_NULL {
            parentReminderID = Int(sqlite3_column_int(statement, 14))
        }
        var splitInfo: SplitInfo? = nil
        if sqlite3_column_type(statement, 15) != SQLITE_NULL, let ptr = sqlite3_column_text(statement, 15) {
            splitInfo = decodeJSON(SplitInfo.self, from: String(cString: ptr))
        }
        var payloadChecksum: String? = nil
        if sqlite3_column_type(statement, 16) != SQLITE_NULL, let ptr = sqlite3_column_text(statement, 16) {
            payloadChecksum = String(cString: ptr)
        }
        // Column 17 — excluded_from_insights — is declared NOT NULL
        // with a default of 0, but we still check for NULL defensively
        // in case the read happens against a row that pre-dates the
        // migration on a partially-upgraded database.
        var excludedFromInsights = false
        if sqlite3_column_type(statement, 17) != SQLITE_NULL {
            excludedFromInsights = sqlite3_column_int(statement, 17) != 0
        }
        // Column 18 — edit_version — NOT NULL DEFAULT 0; check NULL
        // defensively for rows read on a partially-migrated database.
        var editVersion = 0
        if sqlite3_column_type(statement, 18) != SQLITE_NULL {
            editVersion = Int(sqlite3_column_int(statement, 18))
        }
        return Transaction(id: id, syncID: syncID, emoji: emoji, category: category, title: title, description: description, amount: amount, currency: currency, date: date, type: type, tags: tags, lastModified: lastModified, repeatInterval: repeatInterval, parentReminderID: parentReminderID, splitInfo: splitInfo, payloadChecksum: payloadChecksum, excludedFromInsights: excludedFromInsights, editVersion: editVersion)
    }

    private static let transactionSelectSQL = "SELECT id, emoji, category, title, description, amount, currency, date, type, isIncome, tags, sync_id, last_modified, repeat_interval, parent_reminder_id, split_info, payload_checksum, excluded_from_insights, edit_version FROM transactions ORDER BY date DESC;"

    func fetchAllTransactions() async -> [Transaction] {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var statement: OpaquePointer?
                var result: [Transaction] = []
                if sqlite3_prepare_v2(self.db, Self.transactionSelectSQL, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        result.append(self.readTransactionRow(statement))
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func deleteTransaction(id: Int) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let deleteString = "DELETE FROM transactions WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, deleteString, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int(statement, 1, Int32(id))
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to delete transaction")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func deleteAllTransactions() async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let deleteString = "DELETE FROM transactions;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, deleteString, -1, &statement, nil) == SQLITE_OK {
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to delete all transactions")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func update(transaction: Transaction) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let updateString = "UPDATE transactions SET emoji = ?, category = ?, title = ?, description = ?, amount = ?, currency = ?, date = ?, type = ?, isIncome = ?, tags = ?, sync_id = ?, last_modified = ?, repeat_interval = ?, parent_reminder_id = ?, split_info = ?, payload_checksum = ?, excluded_from_insights = ?, edit_version = ? WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, updateString, -1, &statement, nil) == SQLITE_OK {
                    self.bindTransactionFields(statement, transaction)
                    // bindTransactionFields binds columns 1–18 (ending with
                    // edit_version at 18); the WHERE clause's `id` is the
                    // next free slot.
                    sqlite3_bind_int(statement, 19, Int32(transaction.id))
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to update transaction")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - CRUD for Category
    func insert(category: Category) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let insertString = "INSERT INTO categories (id, emoji, title, last_modified) VALUES (?, ?, ?, ?);"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, insertString, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (category.id.uuidString as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(statement, 2, (category.emoji as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(statement, 3, (category.title as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(statement, 4, category.lastModified.timeIntervalSince1970)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to insert category")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func fetchAllCategories() async -> [Category] {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT id, emoji, title, last_modified FROM categories ORDER BY title COLLATE NOCASE ASC;"
                var statement: OpaquePointer?
                var result: [Category] = []
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        let idString = String(cString: sqlite3_column_text(statement, 0))
                        let emoji = String(cString: sqlite3_column_text(statement, 1))
                        let title = String(cString: sqlite3_column_text(statement, 2))
                        let lastModified: Date
                        if sqlite3_column_type(statement, 3) != SQLITE_NULL {
                            lastModified = Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                        } else {
                            lastModified = Date()
                        }
                        if let uuid = UUID(uuidString: idString) {
                            result.append(Category(id: uuid, emoji: emoji, title: title, lastModified: lastModified))
                        }
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func deleteCategory(id: UUID) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let deleteString = "DELETE FROM categories WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, deleteString, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to delete category")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func update(category: Category) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let updateString = "UPDATE categories SET emoji = ?, title = ?, last_modified = ? WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, updateString, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (category.emoji as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(statement, 2, (category.title as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(statement, 3, category.lastModified.timeIntervalSince1970)
                    sqlite3_bind_text(statement, 4, (category.id.uuidString as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to update category")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - DatabaseProtocol conformance

    func insertTransaction(_ transaction: Transaction) async {
        await insert(transaction: transaction)
    }

    func insertTransactions(_ transactions: [Transaction]) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                sqlite3_exec(self.db, "BEGIN TRANSACTION", nil, nil, nil)
                for transaction in transactions {
                    var statement: OpaquePointer?
                    if sqlite3_prepare_v2(self.db, Self.transactionInsertSQL, -1, &statement, nil) == SQLITE_OK {
                        self.bindTransactionFields(statement, transaction)
                        if sqlite3_step(statement) != SQLITE_DONE {
                            print("Failed to insert transaction in batch")
                        }
                    }
                    sqlite3_finalize(statement)
                }
                sqlite3_exec(self.db, "COMMIT", nil, nil, nil)
                continuation.resume(returning: ())
            }
        }
    }

    func updateTransaction(_ transaction: Transaction) async {
        await update(transaction: transaction)
    }

    func insertCategory(_ category: Category) async {
        await insert(category: category)
    }

    func updateCategory(_ category: Category) async {
        await update(category: category)
    }

    // MARK: - Sync helpers

    func fetchTransactionBySyncID(_ syncID: String) async -> Transaction? {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT id, emoji, category, title, description, amount, currency, date, type, isIncome, tags, sync_id, last_modified, repeat_interval, parent_reminder_id, split_info, payload_checksum, excluded_from_insights, edit_version FROM transactions WHERE sync_id = ? LIMIT 1;"
                var statement: OpaquePointer?
                var result: Transaction?
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (syncID as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        result = self.readTransactionRow(statement)
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - CRUD for Friend

    func insertFriend(_ friend: Friend) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let sql = "INSERT INTO friends (id, name, groups_json, split_mode, last_modified, is_connected) VALUES (?, ?, ?, ?, ?, ?);"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (friend.id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(statement, 2, (friend.name as NSString).utf8String, -1, nil)
                    if !friend.groups.isEmpty, let json = try? JSONEncoder().encode(friend.groups), let str = String(data: json, encoding: .utf8) {
                        sqlite3_bind_text(statement, 3, (str as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 3)
                    }
                    if let mode = friend.splitMode {
                        sqlite3_bind_text(statement, 4, (mode.rawValue as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 4)
                    }
                    sqlite3_bind_double(statement, 5, friend.lastModified.timeIntervalSince1970)
                    sqlite3_bind_int(statement, 6, friend.isConnected ? 1 : 0)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        let errmsg = String(cString: sqlite3_errmsg(self.db))
                        print("Failed to insert friend: \(errmsg)")
                    }
                } else {
                    let errmsg = String(cString: sqlite3_errmsg(self.db))
                    print("Failed to prepare insert friend: \(errmsg)")
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func fetchAllFriends() async -> [Friend] {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT id, name, groups_json, split_mode, last_modified, is_connected FROM friends ORDER BY name COLLATE NOCASE ASC;"
                var statement: OpaquePointer?
                var result: [Friend] = []
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        let id = String(cString: sqlite3_column_text(statement, 0))
                        let name = String(cString: sqlite3_column_text(statement, 1))
                        let groups: [String] = {
                            guard sqlite3_column_type(statement, 2) != SQLITE_NULL,
                                  let raw = sqlite3_column_text(statement, 2) else { return [] }
                            let str = String(cString: raw)
                            guard let data = str.data(using: .utf8),
                                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                            return arr
                        }()
                        let splitMode: SplitMode? = {
                            guard sqlite3_column_type(statement, 3) != SQLITE_NULL,
                                  let raw = sqlite3_column_text(statement, 3) else { return nil }
                            return SplitMode(rawValue: String(cString: raw))
                        }()
                        let lastModified = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                        let isConnected = sqlite3_column_int(statement, 5) != 0
                        result.append(Friend(
                            id: id, name: name, groups: groups,
                            splitMode: splitMode, lastModified: lastModified,
                            isConnected: isConnected
                        ))
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func updateFriend(_ friend: Friend) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let sql = "UPDATE friends SET name = ?, groups_json = ?, split_mode = ?, last_modified = ?, is_connected = ? WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (friend.name as NSString).utf8String, -1, nil)
                    if !friend.groups.isEmpty, let json = try? JSONEncoder().encode(friend.groups), let str = String(data: json, encoding: .utf8) {
                        sqlite3_bind_text(statement, 2, (str as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 2)
                    }
                    if let mode = friend.splitMode {
                        sqlite3_bind_text(statement, 3, (mode.rawValue as NSString).utf8String, -1, nil)
                    } else {
                        sqlite3_bind_null(statement, 3)
                    }
                    sqlite3_bind_double(statement, 4, friend.lastModified.timeIntervalSince1970)
                    sqlite3_bind_int(statement, 5, friend.isConnected ? 1 : 0)
                    sqlite3_bind_text(statement, 6, (friend.id as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to update friend")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func deleteFriend(id: String) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let sql = "DELETE FROM friends WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to delete friend")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Sync helpers

    func deleteTransactionBySyncID(_ syncID: String) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let sql = "DELETE FROM transactions WHERE sync_id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (syncID as NSString).utf8String, -1, nil)
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func fetchCategoryByID(_ id: UUID) async -> Category? {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT id, emoji, title, last_modified FROM categories WHERE id = ? LIMIT 1;"
                var statement: OpaquePointer?
                var result: Category?
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (id.uuidString as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        let idString = String(cString: sqlite3_column_text(statement, 0))
                        let emoji = String(cString: sqlite3_column_text(statement, 1))
                        let title = String(cString: sqlite3_column_text(statement, 2))
                        let lm = sqlite3_column_type(statement, 3) != SQLITE_NULL
                            ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 3))
                            : Date()
                        if let uuid = UUID(uuidString: idString) {
                            result = Category(id: uuid, emoji: emoji, title: title, lastModified: lm)
                        }
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    // MARK: - CRUD for ReceiptItem

    private static let receiptItemInsertSQL = """
        INSERT INTO receipt_items
            (sync_id, transaction_id, position, name, quantity, price, total, last_modified, assigned_participant_ids, forced_kind)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """

    private func bindReceiptItemFields(_ statement: OpaquePointer?, _ item: ReceiptItem) {
        guard let txID = item.transactionID else {
            // Caller must populate transactionID before insert. We bind a
            // sentinel of -1 so the row still gets written but is easy to
            // spot during debugging.
            sqlite3_bind_text(statement, 1, (item.syncID as NSString).utf8String, -1, nil)
            sqlite3_bind_int(statement, 2, -1)
            sqlite3_bind_int(statement, 3, Int32(item.position))
            sqlite3_bind_text(statement, 4, (item.name as NSString).utf8String, -1, nil)
            sqlite3_bind_null(statement, 5)
            sqlite3_bind_null(statement, 6)
            sqlite3_bind_null(statement, 7)
            sqlite3_bind_double(statement, 8, item.lastModified.timeIntervalSince1970)
            bindAssignedParticipantIDs(statement, position: 9, ids: item.assignedParticipantIDs)
            bindForcedKind(statement, position: 10, kind: item.forcedKind)
            return
        }
        sqlite3_bind_text(statement, 1, (item.syncID as NSString).utf8String, -1, nil)
        sqlite3_bind_int(statement, 2, Int32(txID))
        sqlite3_bind_int(statement, 3, Int32(item.position))
        sqlite3_bind_text(statement, 4, (item.name as NSString).utf8String, -1, nil)
        if let q = item.quantity {
            sqlite3_bind_double(statement, 5, q)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        if let p = item.price {
            sqlite3_bind_double(statement, 6, p)
        } else {
            sqlite3_bind_null(statement, 6)
        }
        if let t = item.total {
            sqlite3_bind_double(statement, 7, t)
        } else {
            sqlite3_bind_null(statement, 7)
        }
        sqlite3_bind_double(statement, 8, item.lastModified.timeIntervalSince1970)
        bindAssignedParticipantIDs(statement, position: 9, ids: item.assignedParticipantIDs)
        bindForcedKind(statement, position: 10, kind: item.forcedKind)
    }

    /// Binds the stored kind override (manual tips). nil → NULL, so an
    /// auto-parsed line stays name-classified on read.
    private func bindForcedKind(_ statement: OpaquePointer?, position: Int32, kind: ReceiptItem.Kind?) {
        if let raw = kind?.rawValue {
            sqlite3_bind_text(statement, position, (raw as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, position)
        }
    }

    /// JSON-encodes the assignment list. Empty list is stored as NULL —
    /// keeps rows from `byItems`-less flows (the common case) noise-free
    /// in the SQL dump, and matches the read path's NULL-as-empty default.
    private func bindAssignedParticipantIDs(_ statement: OpaquePointer?, position: Int32, ids: [String]) {
        if ids.isEmpty {
            sqlite3_bind_null(statement, position)
            return
        }
        if let data = try? JSONEncoder().encode(ids),
           let json = String(data: data, encoding: .utf8) {
            sqlite3_bind_text(statement, position, (json as NSString).utf8String, -1, nil)
        } else {
            sqlite3_bind_null(statement, position)
        }
    }

    private func readReceiptItemRow(_ statement: OpaquePointer?) -> ReceiptItem {
        let id = Int(sqlite3_column_int(statement, 0))
        let syncID = String(cString: sqlite3_column_text(statement, 1))
        let txID = Int(sqlite3_column_int(statement, 2))
        let position = Int(sqlite3_column_int(statement, 3))
        let name = String(cString: sqlite3_column_text(statement, 4))
        let quantity: Double? = sqlite3_column_type(statement, 5) != SQLITE_NULL
            ? sqlite3_column_double(statement, 5) : nil
        let price: Double? = sqlite3_column_type(statement, 6) != SQLITE_NULL
            ? sqlite3_column_double(statement, 6) : nil
        let total: Double? = sqlite3_column_type(statement, 7) != SQLITE_NULL
            ? sqlite3_column_double(statement, 7) : nil
        let lastModified = sqlite3_column_type(statement, 8) != SQLITE_NULL
            ? Date(timeIntervalSince1970: sqlite3_column_double(statement, 8))
            : Date()
        var assigned: [String] = []
        if sqlite3_column_type(statement, 9) != SQLITE_NULL,
           let ptr = sqlite3_column_text(statement, 9) {
            let json = String(cString: ptr)
            if let data = json.data(using: .utf8),
               let decoded = try? JSONDecoder().decode([String].self, from: data) {
                assigned = decoded
            }
        }
        var forcedKind: ReceiptItem.Kind? = nil
        if sqlite3_column_type(statement, 10) != SQLITE_NULL,
           let ptr = sqlite3_column_text(statement, 10) {
            forcedKind = ReceiptItem.Kind(rawValue: String(cString: ptr))
        }
        return ReceiptItem(
            name: name,
            quantity: quantity,
            price: price,
            total: total,
            assignedParticipantIDs: assigned,
            persistedID: id,
            transactionID: txID,
            syncID: syncID,
            position: position,
            lastModified: lastModified,
            forcedKind: forcedKind
        )
    }

    func insertReceiptItem(_ item: ReceiptItem) async -> Int? {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var statement: OpaquePointer?
                var assignedID: Int? = nil
                if sqlite3_prepare_v2(self.db, Self.receiptItemInsertSQL, -1, &statement, nil) == SQLITE_OK {
                    self.bindReceiptItemFields(statement, item)
                    if sqlite3_step(statement) == SQLITE_DONE {
                        assignedID = Int(sqlite3_last_insert_rowid(self.db))
                    } else {
                        let errmsg = String(cString: sqlite3_errmsg(self.db))
                        print("Failed to insert receipt item: \(errmsg)")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: assignedID)
            }
        }
    }

    func insertReceiptItems(_ items: [ReceiptItem]) async -> [ReceiptItem] {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var result: [ReceiptItem] = []
                sqlite3_exec(self.db, "BEGIN TRANSACTION", nil, nil, nil)
                for var item in items {
                    var statement: OpaquePointer?
                    if sqlite3_prepare_v2(self.db, Self.receiptItemInsertSQL, -1, &statement, nil) == SQLITE_OK {
                        self.bindReceiptItemFields(statement, item)
                        if sqlite3_step(statement) == SQLITE_DONE {
                            item.persistedID = Int(sqlite3_last_insert_rowid(self.db))
                        }
                    }
                    sqlite3_finalize(statement)
                    result.append(item)
                }
                sqlite3_exec(self.db, "COMMIT", nil, nil, nil)
                continuation.resume(returning: result)
            }
        }
    }

    private static let receiptItemSelectColumns = "id, sync_id, transaction_id, position, name, quantity, price, total, last_modified, assigned_participant_ids, forced_kind"

    func fetchReceiptItems(transactionID: Int) async -> [ReceiptItem] {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT \(Self.receiptItemSelectColumns) FROM receipt_items WHERE transaction_id = ? ORDER BY position ASC, id ASC;"
                var statement: OpaquePointer?
                var result: [ReceiptItem] = []
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int(statement, 1, Int32(transactionID))
                    while sqlite3_step(statement) == SQLITE_ROW {
                        result.append(self.readReceiptItemRow(statement))
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func fetchAllReceiptItems() async -> [ReceiptItem] {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT \(Self.receiptItemSelectColumns) FROM receipt_items ORDER BY transaction_id ASC, position ASC, id ASC;"
                var statement: OpaquePointer?
                var result: [ReceiptItem] = []
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    while sqlite3_step(statement) == SQLITE_ROW {
                        result.append(self.readReceiptItemRow(statement))
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func updateReceiptItem(_ item: ReceiptItem) async {
        guard let id = item.persistedID else { return }
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let sql = "UPDATE receipt_items SET sync_id = ?, transaction_id = ?, position = ?, name = ?, quantity = ?, price = ?, total = ?, last_modified = ?, assigned_participant_ids = ?, forced_kind = ? WHERE id = ?;"
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, sql, -1, &statement, nil) == SQLITE_OK {
                    self.bindReceiptItemFields(statement, item)
                    sqlite3_bind_int(statement, 11, Int32(id))
                    if sqlite3_step(statement) != SQLITE_DONE {
                        print("Failed to update receipt item")
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func deleteReceiptItem(id: Int) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, "DELETE FROM receipt_items WHERE id = ?;", -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int(statement, 1, Int32(id))
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    func deleteReceiptItems(transactionID: Int) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, "DELETE FROM receipt_items WHERE transaction_id = ?;", -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_int(statement, 1, Int32(transactionID))
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }

    // MARK: - Sync lookups (Friend / ReceiptItem)

    func fetchFriendByID(_ id: String) async -> Friend? {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT id, name, groups_json, split_mode, last_modified, is_connected FROM friends WHERE id = ? LIMIT 1;"
                var statement: OpaquePointer?
                var result: Friend?
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (id as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        let fid = String(cString: sqlite3_column_text(statement, 0))
                        let name = String(cString: sqlite3_column_text(statement, 1))
                        let groups: [String] = {
                            guard sqlite3_column_type(statement, 2) != SQLITE_NULL,
                                  let raw = sqlite3_column_text(statement, 2) else { return [] }
                            let str = String(cString: raw)
                            guard let data = str.data(using: .utf8),
                                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
                            return arr
                        }()
                        let splitMode: SplitMode? = {
                            guard sqlite3_column_type(statement, 3) != SQLITE_NULL,
                                  let raw = sqlite3_column_text(statement, 3) else { return nil }
                            return SplitMode(rawValue: String(cString: raw))
                        }()
                        let lastModified = Date(timeIntervalSince1970: sqlite3_column_double(statement, 4))
                        let isConnected = sqlite3_column_int(statement, 5) != 0
                        result = Friend(
                            id: fid, name: name, groups: groups,
                            splitMode: splitMode, lastModified: lastModified,
                            isConnected: isConnected
                        )
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func fetchReceiptItemBySyncID(_ syncID: String) async -> ReceiptItem? {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                let query = "SELECT \(Self.receiptItemSelectColumns) FROM receipt_items WHERE sync_id = ? LIMIT 1;"
                var statement: OpaquePointer?
                var result: ReceiptItem?
                if sqlite3_prepare_v2(self.db, query, -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (syncID as NSString).utf8String, -1, nil)
                    if sqlite3_step(statement) == SQLITE_ROW {
                        result = self.readReceiptItemRow(statement)
                    }
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: result)
            }
        }
    }

    func deleteReceiptItemBySyncID(_ syncID: String) async {
        await withCheckedContinuation { continuation in
            dbQueue.async {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(self.db, "DELETE FROM receipt_items WHERE sync_id = ?;", -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_text(statement, 1, (syncID as NSString).utf8String, -1, nil)
                    sqlite3_step(statement)
                }
                sqlite3_finalize(statement)
                continuation.resume(returning: ())
            }
        }
    }
}

import Foundation

struct Transaction: Identifiable, Codable, Equatable {
    let id: Int
    let syncID: String
    let emoji: String
    let category: String
    let title: String
    let description: String?
    let amount: Double
    let currency: String
    let date: Date
    let type: TransactionType
    let tags: [String]?
    let lastModified: Date

    // --- New fields (all optional for backward compatibility) ---

    /// Recurrence schedule. Non-nil means this transaction repeats.
    let repeatInterval: RepeatInterval?

    /// If this transaction was spawned by a recurring parent, links to the parent's ID.
    let parentReminderID: Int?

    /// Split details. Non-nil means this is a split transaction.
    /// When set, `amount` should equal `splitInfo.paidByMe`.
    let splitInfo: SplitInfo?

    /// SHA-256 checksum of the share-link payload that produced this
    /// transaction, if it was imported from a friend's share link. Used
    /// by `ShareIntentClassifier` to tell "byte-identical re-share" from
    /// "friend edited this and is reshipping the link" without re-running
    /// the encoder. `nil` for transactions created locally or imported
    /// before this feature shipped.
    let payloadChecksum: String?

    /// User-controlled flag: when true, this transaction never contributes
    /// to insights / analytics aggregates regardless of the global
    /// "include potential expenses" setting. Toggled from the detail
    /// view or a swipe action; persisted and synced. Defaults to false
    /// (counted in insights) for new and imported transactions.
    let excludedFromInsights: Bool

    /// Monotonic edit counter for server-mediated sync. Incremented on
    /// every local content edit (see `bumpingEditVersion()`), carried in
    /// the share payload (`SharedTransactionPayload.ev`) and the
    /// `pending_deliveries.version` column. The sync apply path
    /// (`ShareIntentClassifier`) and the server UPSERT both refuse to
    /// apply an incoming edit whose version isn't strictly greater than
    /// the stored one — so an out-of-order / stale delivery can never
    /// clobber a newer copy. Starts at 0; persisted in SQLite.
    let editVersion: Int

    init(
        id: Int,
        syncID: String = UUID().uuidString,
        emoji: String,
        category: String,
        title: String,
        description: String?,
        amount: Double,
        currency: String,
        date: Date,
        type: TransactionType,
        tags: [String]?,
        lastModified: Date = Date(),
        repeatInterval: RepeatInterval? = nil,
        parentReminderID: Int? = nil,
        splitInfo: SplitInfo? = nil,
        payloadChecksum: String? = nil,
        excludedFromInsights: Bool = false,
        editVersion: Int = 0
    ) {
        self.id = id
        self.syncID = syncID
        self.emoji = emoji
        self.category = category
        self.title = title
        self.description = description
        self.amount = amount
        self.currency = currency
        self.date = date
        self.type = type
        self.tags = tags
        self.lastModified = lastModified
        self.repeatInterval = repeatInterval
        self.parentReminderID = parentReminderID
        self.splitInfo = splitInfo
        self.payloadChecksum = payloadChecksum
        self.excludedFromInsights = excludedFromInsights
        self.editVersion = editVersion
    }

    /// Convenience accessor — derived from `type`, not stored separately.
    var isIncome: Bool { type == .income }

    var isValid: Bool {
        !emoji.isEmpty && !category.isEmpty && !title.isEmpty && amount > 0 && !currency.isEmpty
    }

    // --- New computed properties ---

    /// True if this transaction has a future date.
    var isFuture: Bool { date > Date() }

    /// True if this is a recurring parent (has repeatInterval, no parentReminderID).
    var isRecurringParent: Bool { repeatInterval != nil && parentReminderID == nil }

    /// True if this is a child spawned by a recurring parent.
    var isRecurringChild: Bool { parentReminderID != nil }

    /// True if this transaction is a split transaction.
    var isSplit: Bool { splitInfo != nil }

    /// True if this transaction should appear in the Reminders screen.
    var isReminder: Bool { isFuture || isRecurringParent }

    /// Returns a copy of this transaction with `parentReminderID` cleared so
    /// it no longer renders as a recurring child. Used when the parent
    /// reminder is deleted to unlink surviving past transactions.
    func orphanedFromRecurringParent() -> Transaction {
        Transaction(
            id: id,
            syncID: syncID,
            emoji: emoji,
            category: category,
            title: title,
            description: description,
            amount: amount,
            currency: currency,
            date: date,
            type: type,
            tags: tags,
            lastModified: Date(),
            repeatInterval: repeatInterval,
            parentReminderID: nil,
            splitInfo: splitInfo,
            payloadChecksum: payloadChecksum,
            excludedFromInsights: excludedFromInsights,
            editVersion: editVersion
        )
    }

    /// Returns a copy with `excludedFromInsights` toggled to the given
    /// value and `lastModified` bumped. Used by the detail view's
    /// include/exclude toggle and the row swipe action.
    func settingExcludedFromInsights(_ excluded: Bool) -> Transaction {
        Transaction(
            id: id,
            syncID: syncID,
            emoji: emoji,
            category: category,
            title: title,
            description: description,
            amount: amount,
            currency: currency,
            date: date,
            type: type,
            tags: tags,
            lastModified: Date(),
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: splitInfo,
            payloadChecksum: payloadChecksum,
            excludedFromInsights: excluded,
            editVersion: editVersion
        )
    }

    /// Returns a copy with the local autoincrement `id` replaced. Used
    /// by `TransactionStore`'s idempotency guard: when a logical save is
    /// committed twice (re-entrancy / retry) the rebuilt transaction
    /// carries `id == 0`, so before updating the already-inserted row in
    /// place we re-stamp it with that row's real autoincrement id. Every
    /// other field — including `lastModified` and `syncID` — is preserved
    /// verbatim, since this is a pure id re-target, not a content edit.
    func withID(_ newID: Int) -> Transaction {
        Transaction(
            id: newID,
            syncID: syncID,
            emoji: emoji,
            category: category,
            title: title,
            description: description,
            amount: amount,
            currency: currency,
            date: date,
            type: type,
            tags: tags,
            lastModified: lastModified,
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: splitInfo,
            payloadChecksum: payloadChecksum,
            excludedFromInsights: excludedFromInsights,
            editVersion: editVersion
        )
    }

    /// Returns a copy with `editVersion` incremented and `lastModified`
    /// bumped — call on every local content edit of a split transaction
    /// so paired friends' sync apply can order edits and the server UPSERT
    /// can reject stale ones. Non-split edits don't need it but it's
    /// harmless to bump.
    func bumpingEditVersion() -> Transaction {
        Transaction(
            id: id,
            syncID: syncID,
            emoji: emoji,
            category: category,
            title: title,
            description: description,
            amount: amount,
            currency: currency,
            date: date,
            type: type,
            tags: tags,
            lastModified: Date(),
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: splitInfo,
            payloadChecksum: payloadChecksum,
            excludedFromInsights: excludedFromInsights,
            editVersion: editVersion + 1
        )
    }

    /// Returns a copy with `editVersion` set to an explicit value (and
    /// `lastModified` bumped). Used by the edit path, where the freshly
    /// rebuilt transaction starts at version 0 but must carry the existing
    /// row's version + 1 so paired friends order this edit correctly.
    func settingEditVersion(_ version: Int) -> Transaction {
        Transaction(
            id: id,
            syncID: syncID,
            emoji: emoji,
            category: category,
            title: title,
            description: description,
            amount: amount,
            currency: currency,
            date: date,
            type: type,
            tags: tags,
            lastModified: Date(),
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: splitInfo,
            payloadChecksum: payloadChecksum,
            excludedFromInsights: excludedFromInsights,
            editVersion: version
        )
    }

    /// The amount to render as the primary number in transaction rows
    /// and cards on home / reminders / category lists. For split
    /// transactions in include-potential mode, this is `myShare` —
    /// matching the "Your share" label the row displays in that mode.
    /// Otherwise the stored `amount` (== `paidByMe` for splits).
    ///
    /// Analytics totals do NOT go through this helper — they go through
    /// `AnalyticsContext.normaliseForInsights`, which both rewrites the
    /// amount AND filters out `excludedFromInsights` rows in one pass.
    func displayPrimaryAmount(includePotentialExpenses: Bool) -> Double {
        if includePotentialExpenses, let split = splitInfo {
            return split.myShare
        }
        return amount
    }
}

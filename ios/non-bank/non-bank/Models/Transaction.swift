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
        payloadChecksum: String? = nil
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
            payloadChecksum: payloadChecksum
        )
    }
}

import Foundation
import Combine
import UIKit

// MARK: - Payer Model

struct Payer: Identifiable, Equatable {
    let id: String       // friend.id or "me"
    let name: String     // friend.name or "You"
    var amount: Double    // how much they paid
}

@MainActor
class CreateTransactionViewModel: ObservableObject {

    // MARK: - Form State

    @Published var isIncome: Bool = false
    @Published var amount: String = ""
    @Published var title: String = ""
    @Published var selectedCurrency: String = "USD"
    @Published var selectedCategory: Category? = nil
    @Published var note: String = ""
    @Published var date: Date = Date()
    /// Recurrence schedule. Non-nil turns the transaction into a recurring
    /// parent that spawns children on each occurrence.
    @Published var repeatInterval: RepeatInterval? = nil
    @Published var userHasManuallySelectedCategory: Bool = false

    // MARK: - Split State

    @Published var isSplitMode: Bool = false
    @Published var selectedFriends: [Friend] = []
    @Published var splitMode: SplitMode? = nil
    @Published var payers: [Payer] = []
    @Published var youIncludedInSplit: Bool = true

    // MARK: - Receipt State

    /// Items captured during the optional receipt scan flow. Persisted to
    /// `receipt_items` after the parent transaction is saved (see
    /// `CreateTransactionModal.commitTransaction`).
    @Published var pendingReceiptItems: [ReceiptItem] = []

    let maxDecimalDigits = 2

    // MARK: - Validation

    var isAmountValid: Bool {
        guard let value = Double(amount.replacingOccurrences(of: ",", with: ".")), value > 0 else { return false }
        return true
    }

    var formattedAmount: String {
        if amount.isEmpty { return "0" }
        var value = amount
        while value.hasPrefix("0") && value.count > 1 && !value.hasPrefix("0.") {
            value.removeFirst()
        }
        return value
    }

    /// Formatted amount with thousand separators (e.g. "29 250" or "29 250.50")
    var formattedAmountGrouped: String {
        let raw = formattedAmount
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        let intString = String(parts.first ?? "0")
        guard let intValue = Int(intString) else { return raw }
        let grouped = NumberFormatting.integerPart(Double(intValue))
        if parts.count > 1 {
            return grouped + "." + String(parts[1])
        }
        return grouped
    }

    /// Adaptive title font size based on character count
    var titleDisplayFontSize: CGFloat {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.count {
        case ..<12: return 36
        case 12..<20: return 30
        case 20..<30: return 26
        default: return 22
        }
    }

    /// Total participant count (friends + optionally me)
    var totalParticipantCount: Int {
        selectedFriends.count + (youIncludedInSplit ? 1 : 0)
    }

    /// Per-person amount for even split: total / participants
    var perPersonAmountFormatted: String {
        let total = Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
        let people = Double(max(totalParticipantCount, 1))
        let perPerson = total / people
        let intPart = NumberFormatting.integerPart(perPerson)
        let decimal = perPerson - Double(Int(perPerson))
        if decimal == 0 {
            return intPart
        } else {
            return intPart + String(format: ".%02d", Int((decimal * 100).rounded()))
        }
    }

    /// Adaptive font size: shrinks as the amount string grows longer
    var amountFontSize: CGFloat {
        let displayLength = formattedAmount.count + selectedCurrency.count + 1
        switch displayLength {
        case ..<8:  return 64
        case 8..<10: return 56
        case 10..<12: return 48
        case 12..<14: return 40
        default: return 34
        }
    }

    // MARK: - Payer Helpers

    /// Total amount the user ("me") is paying
    var myPaidAmount: Double {
        // Single payer "me" always pays the full current amount
        if payers.count == 1 && payers.first?.id == "me" {
            return parsedAmount
        }
        return payers.first(where: { $0.id == "me" })?.amount ?? 0
    }

    /// The parsed total amount
    var parsedAmount: Double {
        Double(amount.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    /// My fair share of the total (evenly split)
    var myShareAmount: Double {
        guard totalParticipantCount > 0 else { return parsedAmount }
        if !youIncludedInSplit { return 0 }
        return parsedAmount / Double(totalParticipantCount)
    }

    /// Net lent amount: positive = I lent, negative = I borrowed
    var netLentAmount: Double {
        myPaidAmount - myShareAmount
    }

    /// Formatted net lent/owed amount
    var netLentAmountFormatted: String {
        let value = abs(netLentAmount)
        let intPart = NumberFormatting.integerPart(value)
        let decimal = value - Double(Int(value))
        if decimal == 0 {
            return intPart
        } else {
            return intPart + String(format: ".%02d", Int((decimal * 100).rounded()))
        }
    }

    /// Set default payer to "You" paying the full amount
    func setDefaultPayer() {
        payers = [Payer(id: "me", name: "You", amount: parsedAmount)]
    }

    /// Update payer amounts when the total amount changes (keep proportions)
    func updatePayerAmountsForTotal() {
        guard !payers.isEmpty else { return }
        let total = parsedAmount
        if payers.count == 1 {
            payers[0].amount = total
        }
        // For multi-payer, keep existing amounts (user-set)
    }

    // MARK: - Keypad Actions

    func handleBackspace() {
        playHaptic(style: .light)
        if !amount.isEmpty {
            amount.removeLast()
        }
    }

    func handleKeyPress(
        _ key: String,
        onSave: @escaping () -> Void
    ) {
        if key == "✔︎" {
            if isAmountValid {
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)
                onSave()
            }
            return
        }

        playHaptic(style: .light)

        if key == "." {
            if amount.isEmpty { amount = "0."; return }
            if !amount.contains(".") { amount.append(".") }
        } else if Int(key) != nil {
            let parts = amount.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = parts.first ?? ""
            if !amount.contains(".") {
                if intPart.count >= 8 { return }
            } else {
                if parts.count > 1 {
                    let decimals = parts[1]
                    if decimals.count >= maxDecimalDigits { return }
                }
            }
            if amount == "0" {
                amount = key
            } else {
                amount.append(key)
            }
        }
    }

    // MARK: - Save

    /// Build a transaction. Uses the `payers` array for split payment info.
    /// Build a `Transaction` from the current form state.
    ///
    /// - Parameter editingId: the SQLite primary key when updating an
    ///   existing row; `nil` for inserts (the store assigns the next
    ///   autoincrement id).
    /// - Parameter syncID: stable cross-version identifier. When `nil`
    ///   the default `Transaction.init` mints a fresh `UUID`. Callers
    ///   doing a delete-then-insert "replace" of a recurring parent
    ///   should pass the old transaction's `syncID` here so that any
    ///   sheet/state still bound to the old record can resolve to the
    ///   new one (otherwise the breakdown card stacked over the
    ///   reminder renders empty after replace because both `id` and
    ///   `syncID` would have rotated).
    func buildTransaction(editingId: Int?, syncID: String? = nil) -> Transaction? {
        guard let selectedCategory else { return nil }
        let total = parsedAmount
        let txId = editingId ?? 0

        // Build split info if in split mode
        var splitInfo: SplitInfo? = nil
        if isSplitMode && (totalParticipantCount > 0) {
            let totalPeople = Double(totalParticipantCount)
            let perPerson = total / totalPeople
            let myShare = youIncludedInSplit ? perPerson : 0

            let paidByMe = myPaidAmount
            let lentAmount = max(paidByMe - myShare, 0)

            // Build friend shares from selectedFriends with actual payer amounts
            let friendShares = selectedFriends.map { friend in
                let paidAmount = payers.first(where: { $0.id == friend.id })?.amount ?? 0
                return FriendShare(friendID: friend.id, share: perPerson, paidAmount: paidAmount)
            }

            // Also include payers who are NOT in selectedFriends (e.g. "someone else paid")
            let selectedFriendIDs = Set(selectedFriends.map(\.id))
            let extraPayerShares = payers
                .filter { $0.id != "me" && !selectedFriendIDs.contains($0.id) }
                .map { payer in
                    FriendShare(friendID: payer.id, share: 0, paidAmount: payer.amount)
                }

            splitInfo = SplitInfo(
                totalAmount: total,
                paidByMe: paidByMe,
                myShare: myShare,
                lentAmount: lentAmount,
                friends: friendShares + extraPayerShares,
                splitMode: splitMode
            )
        }

        // The recorded amount is what I actually paid (paidByMe for splits)
        let recordedAmount = splitInfo?.paidByMe ?? total

        let tx = Transaction(
            id: txId,
            syncID: syncID ?? UUID().uuidString,
            emoji: selectedCategory.emoji,
            category: selectedCategory.title,
            title: title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "My \(selectedCategory.title)"
                : title.trimmingCharacters(in: .whitespacesAndNewlines),
            description: note.isEmpty ? nil : note,
            amount: recordedAmount,
            currency: selectedCurrency,
            date: date,
            type: isIncome ? .income : .expenses,
            tags: nil,
            repeatInterval: repeatInterval,
            splitInfo: splitInfo
        )
        // For splits where I paid 0, amount is 0 — still valid
        if splitInfo != nil {
            return tx
        }
        return tx.isValid ? tx : nil
    }

    // MARK: - Auto Category Selection

    func updateCategoryForCurrentType(
        transactions: [Transaction],
        categories: [Category]
    ) {
        let filteredTxs = transactions.filter { $0.isIncome == isIncome }
        let categoryCounts = Dictionary(grouping: filteredTxs, by: { $0.category }).mapValues { $0.count }

        if let mostPopularName = categoryCounts.max(by: { $0.value < $1.value })?.key,
           let cat = categories.first(where: { $0.title == mostPopularName }) {
            selectedCategory = cat
        } else {
            let fallbackTitle = isIncome ? "Income" : "Food"
            selectedCategory = categories.first(where: { $0.title == fallbackTitle })
                               ?? categories.first
        }
    }

    // MARK: - Populate for Editing

    func populate(from tx: Transaction, categories: [Category], friendResolver: ((String) -> Friend?)? = nil) {
        isIncome = tx.isIncome
        title = tx.title
        note = tx.description ?? ""
        selectedCurrency = tx.currency
        date = tx.date
        repeatInterval = tx.repeatInterval

        selectedCategory = categories.first(where: { $0.title == tx.category })
            ?? CategoryStore.uncategorized

        // Restore split state
        if let split = tx.splitInfo, let resolver = friendResolver {
            let totalAmount = split.totalAmount
            // Use totalAmount for the amount field (not paidByMe)
            if totalAmount.truncatingRemainder(dividingBy: 1) == 0 {
                amount = String(format: "%.0f", totalAmount)
            } else {
                amount = String(totalAmount)
            }

            isSplitMode = true
            splitMode = split.splitMode

            // Resolve friends — only those with a share (split participants)
            let splitParticipants = split.friends.filter { $0.share > 0 }
            let friends = splitParticipants.compactMap { resolver($0.friendID) }
            selectedFriends = friends

            // Determine if "You" was included in the split
            youIncludedInSplit = split.myShare > 0

            // Reconstruct payers from stored data
            var reconstructedPayers: [Payer] = []
            if split.paidByMe > 0 {
                reconstructedPayers.append(Payer(id: "me", name: "You", amount: split.paidByMe))
            }
            // Add friends who paid (using stored paidAmount)
            for f in split.friends where f.paidAmount > 0 {
                let name = resolver(f.friendID)?.name ?? "Friend"
                reconstructedPayers.append(Payer(id: f.friendID, name: name, amount: f.paidAmount))
            }
            // If nobody paid (edge case), default to "me"
            if reconstructedPayers.isEmpty {
                reconstructedPayers.append(Payer(id: "me", name: "You", amount: totalAmount))
            }
            payers = reconstructedPayers
        } else {
            if tx.amount.truncatingRemainder(dividingBy: 1) == 0 {
                amount = String(format: "%.0f", tx.amount)
            } else {
                amount = String(tx.amount)
            }
        }
    }

    // MARK: - Split Helpers

    private static let lastSplitModeKey = "lastUsedSplitMode"

    /// Resolves the default split mode based on selected friends.
    func resolvedSplitMode() -> SplitMode {
        // Single friend with assigned split mode → use that
        if selectedFriends.count == 1, let mode = selectedFriends.first?.splitMode {
            return mode
        }
        // Otherwise → last used, or fallback to 50/50
        if let raw = UserDefaults.standard.string(forKey: Self.lastSplitModeKey),
           let mode = SplitMode(rawValue: raw) {
            return mode
        }
        return .fiftyFifty
    }

    /// Called after friend picker confirms selection.
    func selectFriendsAndResolveSplitMode(_ friends: [Friend]) {
        selectedFriends = friends
        splitMode = resolvedSplitMode()
        isSplitMode = true
    }

    /// Remove a friend from the split. If none left, exit split mode.
    /// Payers are NOT touched — they are independent of split participants.
    func removeFriend(_ friend: Friend) {
        selectedFriends.removeAll { $0.id == friend.id }
        if selectedFriends.isEmpty {
            isSplitMode = false
            splitMode = nil
            payers = []
        }
    }

    /// Persist the last-used split mode for future defaults.
    func persistLastUsedSplitMode() {
        guard let mode = splitMode else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.lastSplitModeKey)
    }

    /// Returns the set of friend IDs most frequently used together in split transactions,
    /// or nil if there are no past splits.
    /// Picks the friend-ID combination that appears most often.
    static func mostFrequentSplitFriendIDs(from transactions: [Transaction]) -> [String]? {
        let splitTxs = transactions.filter { $0.splitInfo != nil }
        guard !splitTxs.isEmpty else { return nil }

        // Build frequency map: sorted friend-ID set → count
        var freq: [String: (ids: [String], count: Int)] = [:]
        for tx in splitTxs {
            guard let info = tx.splitInfo else { continue }
            let ids = info.friends.map(\.friendID).sorted()
            let key = ids.joined(separator: ",")
            if let existing = freq[key] {
                freq[key] = (ids: existing.ids, count: existing.count + 1)
            } else {
                freq[key] = (ids: ids, count: 1)
            }
        }

        guard let best = freq.values.max(by: { $0.count < $1.count }) else { return nil }
        return best.ids
    }

    // MARK: - Receipt Items

    /// Apply items extracted from a scanned receipt: store the items locally
    /// for persistence on commit, fill the amount field with their total, and
    /// — if the parser detected a known currency — switch to it (only when
    /// the user hasn't typed an amount yet, so we never overwrite manual
    /// edits).
    func applyReceiptItems(_ items: [ReceiptItem], total: Double, currency: String?) {
        pendingReceiptItems = items
        // Clamp to >= 0 — `total` may be the net of items minus discounts,
        // and a negative net is nonsensical for the amount keypad. Negative
        // discount items themselves are still preserved in `pendingReceiptItems`.
        amount = Self.formatAmount(max(0, total))
        if let currency, !currency.isEmpty, CurrencyInfo.byCode[currency] != nil {
            selectedCurrency = currency
        }
        if isSplitMode {
            updatePayerAmountsForTotal()
        }
    }

    /// Drop a previously-captured receipt — used if the user wipes the amount
    /// or scans a new image.
    func clearPendingReceiptItems() {
        pendingReceiptItems = []
    }

    /// Format a `Double` total into the keypad-friendly string the amount
    /// field expects: integer with no trailing decimals when possible, two
    /// decimals otherwise. Locale-independent (always `.` separator).
    private static func formatAmount(_ value: Double) -> String {
        let rounded = (value * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        return String(format: "%.2f", rounded)
    }

    // MARK: - Haptic

    func playHaptic(style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        let generator = UIImpactFeedbackGenerator(style: style)
        generator.impactOccurred()
    }
}

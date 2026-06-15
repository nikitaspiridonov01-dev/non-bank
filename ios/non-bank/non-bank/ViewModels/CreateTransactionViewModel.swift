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

    // MARK: - Composed controllers

    /// Receipt-item state and the WhoPaid paid-extra reconciliation —
    /// owned by a dedicated controller so the receipt logic can be
    /// unit-tested in isolation and the VM stays focused on form
    /// orchestration. Re-publishes its `objectWillChange` upward via
    /// Combine so existing `@ObservedObject var vm` consumers still
    /// re-render when receipt state changes — no SwiftUI binding
    /// changes needed at callsites.
    let receipt = ReceiptItemController()

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward inner controller's change notifications so SwiftUI
        // views observing the VM repaint on receipt-state mutations.
        receipt.objectWillChange
            .sink { [weak self] in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

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

    /// Manually-entered per-participant shares for `splitMode == .byAmount`.
    /// Keyed by participant ID — `"me"` for the user (matches the
    /// `WhoPaidPicker` sentinel), `Friend.id` for everyone else. Empty
    /// means "user hasn't opened the share picker yet"; in that state
    /// `buildTransaction` falls back to an even split so the user can
    /// still save without a picker round-trip.
    @Published var byAmountShares: [String: Double] = [:]

    /// True when the saved `byAmountShares` sum to the current
    /// `parsedAmount` within the same tolerance the picker enforces.
    /// Drives the indicator next to the split-mode chip — green check
    /// when balanced, warning glyph when stale (e.g. user typed a new
    /// amount on the numpad after entering shares, leaving them out of
    /// sync with the new total).
    var byAmountSharesBalanced: Bool {
        guard !byAmountShares.isEmpty else { return false }
        let sum = byAmountShares.values.reduce(0, +)
        let tolerance = 0.01 * Double(max(byAmountShares.count, 1))
        return abs(sum - parsedAmount) <= tolerance
    }

    /// True when at least one receipt item carries an item-assignee.
    /// Used in tandem with `splitMode == .byItems` to drive the chip
    /// indicator and re-open behaviour.
    var byItemsHasAssignments: Bool {
        pendingReceiptItems.contains { !$0.assignedParticipantIDs.isEmpty }
    }

    /// True when the computed by-items shares (via
    /// `SplitShareCalculator`) sum to within tolerance of the current
    /// `parsedAmount`. False when the receipt total has drifted from
    /// the transaction amount — the most common cause is the user
    /// editing items via the badge after assignment, which Phase 4.6
    /// will auto-chain into a re-balance prompt.
    var byItemsBalanced: Bool {
        guard byItemsHasAssignments else { return false }
        var participantIDs: Set<String> = Set(selectedFriends.map(\.id))
        if youIncludedInSplit {
            participantIDs.insert(ReceiptItem.selfParticipantID)
        }
        let computed = SplitShareCalculator.compute(
            items: pendingReceiptItems,
            participants: participantIDs
        )
        let sum = computed.values.reduce(0, +)
        let tolerance = 0.01 * Double(max(computed.count, 1))
        return abs(sum - parsedAmount) <= tolerance
    }

    // MARK: - Receipt State

    /// Items captured during the optional receipt scan flow. Persisted to
    /// `receipt_items` after the parent transaction is saved (see
    /// `CreateTransactionModal.commitTransaction`).
    ///
    /// **Shim** — actual storage lives on `receipt.items`. Kept as a
    /// computed get/set proxy so the ~24 existing callsites
    /// (`vm.pendingReceiptItems`, including the one assignment at
    /// `CreateTransactionModal:1303`) keep compiling unchanged. The
    /// `receipt` controller forwards `objectWillChange` upward, so
    /// SwiftUI views still repaint on mutation.
    var pendingReceiptItems: [ReceiptItem] {
        get { receipt.items }
        set { receipt.items = newValue }
    }

    static let maxDecimalDigits = 2
    var maxDecimalDigits: Int { Self.maxDecimalDigits }

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

    /// Paste a freeform amount string from the clipboard (or any
    /// other source) into the numpad's `amount` state.
    ///
    /// Delegates the messy parsing — currency symbols, ISO codes,
    /// thousands separators, no-break spaces, accounting parens — to
    /// `ImportFieldParser.parseAmountString`, then re-formats the
    /// result to the `"123.45"` shape the keypad expects and clamps
    /// it to the same magnitude/precision bounds tap-input enforces
    /// (max 8 integer digits, `maxDecimalDigits` after the dot).
    ///
    /// The sign is intentionally discarded: income/expense is a
    /// separate control on the create screen, and silently flipping
    /// the user's choice during a paste would be surprising. Returns
    /// `true` on success, `false` when the input can't be parsed as
    /// a number or overflows the 8-digit integer budget — caller
    /// uses the flag to decide between a success / error haptic.
    @discardableResult
    func pasteAmount(_ raw: String) -> Bool {
        guard let value = ImportFieldParser.parseAmountString(raw) else {
            playHaptic(style: .rigid)
            return false
        }
        // `abs()` because the sign is owned by `isIncome` on this
        // form, not by the amount string.
        let magnitude = abs(value)
        guard let formatted = Self.formatAmountForKeypad(magnitude) else {
            playHaptic(style: .rigid)
            return false
        }
        amount = formatted
        playHaptic(style: .light)
        return true
    }

    /// Re-render a parsed `Double` as the keypad's `"123.45"` /
    /// `"123"` string form, applying the same limits the digit
    /// handler enforces. Returns `nil` when the magnitude exceeds
    /// what the form allows (more than 8 integer digits) so the
    /// caller can surface an error rather than silently chopping
    /// off the most-significant digits.
    private static func formatAmountForKeypad(_ value: Double) -> String? {
        let rounded = (value * 100).rounded() / 100
        // Decimal-place truncation: same `.2` precision the rest of
        // the app stores. We render with the C printf path to avoid
        // locale-based grouping/decimal-comma surprises.
        let asString = String(format: "%.\(Self.maxDecimalDigits)f", rounded)
        let parts = asString.split(separator: ".", omittingEmptySubsequences: false)
        var intPart = String(parts.first ?? "0")
        var decPart = parts.count > 1 ? String(parts[1]) : ""

        // Strip insignificant leading zeros so "0007.50" doesn't
        // come out of paste — we want "7.50".
        while intPart.count > 1 && intPart.hasPrefix("0") {
            intPart.removeFirst()
        }
        // 8-digit integer cap: matches the tap-input guard at
        // `handleKeyPress` so paste can never produce a value the
        // keypad couldn't.
        guard intPart.count <= 8 else { return nil }

        // Mirror the keypad's own convention of trimming trailing
        // zeros — a freshly entered "7" stays "7" not "7.00", and a
        // pasted "100.50" lands as "100.5" not "100.50". Without
        // this the round-trip introduces a phantom trailing zero
        // and the cents-font ".50" looks wider than what the user
        // pasted. Middle zeros stay put ("100.05" → "100.05").
        while decPart.hasSuffix("0") {
            decPart.removeLast()
        }
        return decPart.isEmpty ? intPart : "\(intPart).\(decPart)"
    }

    /// Clears the amount field. Mirrors the long-press → "Clear"
    /// context-menu action on the amount block. Separate from
    /// backspace because Clear should drop the whole value at once
    /// (no per-digit haptic spam).
    func clearAmount() {
        guard !amount.isEmpty else { return }
        amount = ""
        playHaptic(style: .light)
    }

    func handleKeyPress(
        _ key: String,
        onSave: @escaping () -> Void
    ) {
        if key == "✔︎" {
            if isAmountValid {
                // The save path itself plays the ramping "counter spin-up"
                // haptic (BalanceSavePulse.fire → CounterHaptics), in sync
                // with the Home balance count-up — so we no longer fire a
                // one-shot `.success` notification here, which would clash
                // with the ramp's opening ticks.
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
            // Per-participant shares depend on the chosen split mode.
            // `.byAmount` honours the picker-entered dictionary when
            // populated; otherwise (and for `.byItems` until Phase 4
            // wires assignment-based math) we fall back to even split,
            // so the create flow always has a sane saveable state.
            let resolvedMode = splitMode ?? .evenly
            let myShare: Double
            let friendShares: [FriendShare]

            if resolvedMode == .byAmount && !byAmountShares.isEmpty {
                myShare = youIncludedInSplit ? (byAmountShares["me"] ?? 0) : 0
                friendShares = selectedFriends.map { friend in
                    let paidAmount = payers.first(where: { $0.id == friend.id })?.amount ?? 0
                    return FriendShare(
                        friendID: friend.id,
                        share: byAmountShares[friend.id] ?? 0,
                        paidAmount: paidAmount
                    )
                }
            } else if resolvedMode == .byItems && pendingReceiptItems.contains(where: { !$0.assignedParticipantIDs.isEmpty }) {
                // `byItems` math runs through the calculator —
                // assignments live on each `ReceiptItem` and items use
                // `ReceiptItem.selfParticipantID` for the user (NOT the
                // `"me"` sentinel that `WhoPaidPicker` uses, since
                // those were introduced separately and we kept each
                // domain's convention rather than refactoring callers).
                var participantIDs: Set<String> = Set(selectedFriends.map(\.id))
                if youIncludedInSplit {
                    participantIDs.insert(ReceiptItem.selfParticipantID)
                }
                let computed = SplitShareCalculator.compute(
                    items: pendingReceiptItems,
                    participants: participantIDs
                )
                myShare = youIncludedInSplit ? (computed[ReceiptItem.selfParticipantID] ?? 0) : 0
                friendShares = selectedFriends.map { friend in
                    let paidAmount = payers.first(where: { $0.id == friend.id })?.amount ?? 0
                    return FriendShare(
                        friendID: friend.id,
                        share: computed[friend.id] ?? 0,
                        paidAmount: paidAmount
                    )
                }
            } else if resolvedMode == .settleUp {
                // Settle-up has a unique shape: ONE party pays the
                // full amount and ONE (different) party receives the
                // full amount. The `payers` array carries who paid;
                // by the invariant established at commitSettleUp /
                // prefill time it has exactly one entry. The
                // RECEIVER is whichever party isn't the payer — and
                // that party may be "me" OR a third friend, so we
                // can't infer it from `!mePays` alone.
                //
                // Three shapes to encode (see `commitSettleUp`):
                //   - me→friend   (mePays, `selectedFriends == [recipient]`)
                //   - friend→me   (!mePays && youIncludedInSplit, `selectedFriends == [payer]`)
                //   - friend→friend (!mePays && !youIncludedInSplit, `selectedFriends == [payer, recipient]`)
                //
                // We compute shares deterministically here rather
                // than letting the evenly fallback split the total
                // 50/50 — that produced the "you pay for yourself"
                // bug: with equal shares (50 vs 50) the downstream
                // `normaliseSettleUp` tie-broke the receiver back to
                // "me", which collapsed the settle-up into a solo
                // self-paid expense. The earlier version of this
                // branch then over-corrected by hardcoding `myShare
                // = total` whenever `!mePays`, which silently
                // injected the user into friend→friend transfers on
                // save and made the round-trip render "Meur pays for
                // you" after re-open.
                let payerID = payers.first?.id ?? "me"
                let mePays = payerID == "me"
                let meReceives = !mePays && youIncludedInSplit
                myShare = meReceives ? total : 0
                friendShares = selectedFriends.map { friend in
                    let friendIsPayer = friend.id == payerID
                    let friendIsReceiver: Bool
                    if meReceives {
                        // friend→me: the friend is the payer, not
                        // the receiver. Their share is zero.
                        friendIsReceiver = false
                    } else if mePays {
                        // me→friend: the single friend in
                        // `selectedFriends` is the receiver by
                        // construction.
                        friendIsReceiver = true
                    } else {
                        // friend→friend: receiver is whichever
                        // friend isn't the payer.
                        friendIsReceiver = !friendIsPayer
                    }
                    return FriendShare(
                        friendID: friend.id,
                        share: friendIsReceiver ? total : 0,
                        paidAmount: friendIsPayer ? total : 0
                    )
                }
            } else {
                let totalPeople = Double(totalParticipantCount)
                let perPerson = total / totalPeople
                myShare = youIncludedInSplit ? perPerson : 0
                friendShares = selectedFriends.map { friend in
                    let paidAmount = payers.first(where: { $0.id == friend.id })?.amount ?? 0
                    return FriendShare(friendID: friend.id, share: perPerson, paidAmount: paidAmount)
                }
            }

            let paidByMe = myPaidAmount
            let lentAmount = max(paidByMe - myShare, 0)

            // Also include payers who are NOT in selectedFriends (e.g. "someone else paid")
            let selectedFriendIDs = Set(selectedFriends.map(\.id))
            let extraPayerShares = payers
                .filter { $0.id != "me" && !selectedFriendIDs.contains($0.id) }
                .map { payer in
                    FriendShare(friendID: payer.id, share: 0, paidAmount: payer.amount)
                }

            // Coerce to `.settleUp` whenever the resulting shape matches:
            // exactly one party paid, exactly one (different) party
            // bears the full share. The user might land here either by
            // explicitly picking settle-up in the mode picker or by
            // sculpting another mode into a 100/0 configuration — UX
            // expectations are the same in both cases ("X pays for Y"),
            // so the stored mode reflects the resolved intent rather
            // than the original picker pick.
            let allFriendShares = friendShares + extraPayerShares
            let resolvedSplitMode = SplitMathHelpers.resolveStoredSplitMode(
                requested: splitMode,
                paidByMe: paidByMe,
                myShare: myShare,
                friends: allFriendShares
            )

            // Hard settle-up invariant. When the resolved mode is
            // `.settleUp`, normalise the payload so:
            //   - exactly one party has `paidAmount = totalAmount`,
            //   - exactly one (different) party has `share = totalAmount`,
            //   - everyone else is zeroed.
            // Without this clamp a stale `vm.payers` from a previous
            // mode (e.g. the user picked evenly with 2 friends, then
            // switched to settle-up and re-picked the payer / receiver)
            // could leave the second friend with a non-zero
            // `paidAmount` from the old draft — and `resolveStoredSplitMode`
            // would still coerce to `.settleUp` based on the legitimate
            // payer/receiver pair, while the spurious second payer
            // silently halves the debt later because the debt math
            // credits both "payers". This branch is the single source
            // of truth that the write path can't violate the shape.
            let finalSplitInfo: SplitInfo
            if resolvedSplitMode == .settleUp {
                finalSplitInfo = SplitMathHelpers.normaliseSettleUp(
                    total: total,
                    paidByMe: paidByMe,
                    myShare: myShare,
                    friends: allFriendShares
                )
            } else {
                finalSplitInfo = SplitInfo(
                    totalAmount: total,
                    paidByMe: paidByMe,
                    myShare: myShare,
                    lentAmount: lentAmount,
                    friends: allFriendShares,
                    splitMode: resolvedSplitMode
                )
            }
            splitInfo = finalSplitInfo
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

            // Resolve friends. For non-settle-up modes "selectedFriends"
            // means split participants (positive share); paid-upfront
            // friends with no share are reconstructed into `payers`
            // below via the `paidAmount > 0` branch and intentionally
            // stay out of `selectedFriends`.
            //
            // Settle-up is the exception: `commitSettleUp` puts BOTH
            // payer (share=0, paid=total) and recipient (share=total,
            // paid=0) into `selectedFriends`, so the orchestrator's
            // re-entry can prefill the picker. Filtering by
            // `share > 0` would silently drop the payer friend on
            // every reload and break the friend-picker prefill in
            // the friend→me and friend→friend shapes.
            let candidateFriends: [FriendShare]
            if split.splitMode == .settleUp {
                candidateFriends = split.friends.filter {
                    $0.share > 0 || $0.paidAmount > 0
                }
            } else {
                candidateFriends = split.friends.filter { $0.share > 0 }
            }
            let friends = candidateFriends.compactMap { resolver($0.friendID) }
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

            // Settle-up guard. Reading a corrupted (pre-fix) row that
            // somehow has two non-zero `paidAmount`s would otherwise
            // surface as two payers on the edit screen, and saving
            // again would write the same shape back. Snap the array
            // to a single payer (largest `amount` wins, ties → me)
            // when the stored mode is `.settleUp` so editing a
            // damaged transaction silently heals it.
            if split.splitMode == .settleUp && reconstructedPayers.count > 1 {
                let winner = reconstructedPayers.max(by: { $0.amount < $1.amount })
                if let winner {
                    reconstructedPayers = [
                        Payer(
                            id: winner.id,
                            name: winner.name,
                            amount: totalAmount  // canonical: the single payer covers the whole sum
                        )
                    ]
                }
            }
            payers = reconstructedPayers

            // Reconstruct `byAmountShares` for `byAmount` transactions so
            // re-opening the share picker shows the saved amounts. For
            // every other mode the dictionary stays empty (which means
            // "use even split" downstream).
            if split.splitMode == .byAmount {
                var shares: [String: Double] = [:]
                if split.myShare > 0 {
                    shares["me"] = split.myShare
                }
                for f in split.friends where f.share > 0 {
                    shares[f.friendID] = f.share
                }
                byAmountShares = shares
            } else {
                byAmountShares = [:]
            }
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

    /// Resolves the default split mode for a freshly created split.
    /// `byAmount` is intentionally never returned as a default — it
    /// requires per-participant amounts that the user can only enter
    /// AFTER the friend picker, so the create flow always lands on
    /// `evenly` (or `byItems` once Phase 4 lands) and lets the user
    /// promote to `byAmount` via the share picker. Existing
    /// `byAmount` transactions still load their saved mode through the
    /// edit-prefill path; this helper only governs new-split defaults.
    func resolvedSplitMode() -> SplitMode {
        // Single friend with assigned split mode → use that, unless
        // they had `byAmount` saved (the friend-level default also
        // can't be byAmount — same per-participant-amount problem).
        if selectedFriends.count == 1,
           let mode = selectedFriends.first?.splitMode,
           mode != .byAmount {
            return mode
        }
        // Otherwise → last used, but skip byAmount for the same reason.
        if let raw = UserDefaults.standard.string(forKey: Self.lastSplitModeKey),
           let mode = SplitMode(rawValue: raw),
           mode != .byAmount {
            return mode
        }
        return .evenly
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

    /// Persist the last-used split mode for future defaults. Skips
    /// `byAmount` — that mode requires per-participant amounts that
    /// can't be defaulted at create-time, so it must never be the
    /// "remembered" choice for a fresh transaction (see
    /// `resolvedSplitMode` for the symmetric guard on the read side).
    func persistLastUsedSplitMode() {
        guard let mode = splitMode, mode != .byAmount else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.lastSplitModeKey)
    }

    // MARK: - Receipt Items

    /// Apply items extracted from a scanned receipt: store the items locally
    /// for persistence on commit, fill the amount field with their total, and
    /// — if the parser detected a known currency — switch to it (only when
    /// the user hasn't typed an amount yet, so we never overwrite manual
    /// edits). When the cloud parser supplies a `suggestedCategory`, we try
    /// to match it against the user's existing category list and pre-select
    /// it; nothing happens if there's no match (we never invent a new one).
    func applyReceiptItems(
        _ items: [ReceiptItem],
        total: Double,
        currency: String?,
        suggestedCategory: String? = nil,
        availableCategories: [Category] = []
    ) {
        pendingReceiptItems = items
        // Clamp to >= 0 — `total` may be the net of items minus discounts,
        // and a negative net is nonsensical for the amount keypad. Negative
        // discount items themselves are still preserved in `pendingReceiptItems`.
        amount = Self.formatAmount(max(0, total))
        if let currency, !currency.isEmpty, CurrencyInfo.byCode[currency] != nil {
            selectedCurrency = currency
        }
        // Auto-pick a matching category if the cloud LLM suggested one.
        // Only override when the user hasn't manually picked something —
        // a manual pick should always win, even after a re-scan.
        if let suggestion = suggestedCategory,
           !suggestion.isEmpty,
           !userHasManuallySelectedCategory,
           let match = matchCategory(named: suggestion, in: availableCategories) {
            selectedCategory = match
        }
        if isSplitMode {
            updatePayerAmountsForTotal()
        }
    }

    /// Tolerant title match — exact (case-insensitive) first, then a
    /// best-effort substring fallback so "Restaurants" still matches the
    /// user's "Food & Restaurants" or vice versa. Returns `nil` if nothing
    /// is a clear winner — better to leave the user's default in place than
    /// to silently put a transaction in the wrong category.
    private func matchCategory(named query: String, in pool: [Category]) -> Category? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return nil }
        if let exact = pool.first(where: { $0.title.lowercased() == q }) {
            return exact
        }
        let contains = pool.filter {
            let t = $0.title.lowercased()
            return t.contains(q) || q.contains(t)
        }
        // Only return a substring match when it's unambiguous.
        return contains.count == 1 ? contains.first : nil
    }

    /// Drop a previously-captured receipt — used if the user wipes the amount
    /// or scans a new image. Delegates to the receipt controller.
    func clearPendingReceiptItems() {
        receipt.clear()
    }

    // MARK: - Paid-extra placeholder (driven by WhoPaid exceed flow)
    //
    // Logic lives on `ReceiptItemController` so it's unit-testable
    // without spinning up the full create-transaction VM. The shim
    // below preserves the existing `vm.reconcilePaidExtra(...)`
    // callsite shape used by `TransactionModeFlowSheet`.

    func reconcilePaidExtra(payerName: String, newTotal: Double) {
        receipt.reconcilePaidExtra(payerName: payerName, newTotal: newTotal)
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

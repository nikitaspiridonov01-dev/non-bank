import Foundation
import Combine

/// Owns the in-flight receipt-item state for the create-transaction
/// flow: the list of items captured from a scan, plus the
/// "paid-extra placeholder" reconciliation that the WhoPaid picker
/// drives when a payer's contribution exceeds the receipt total.
///
/// Extracted from `CreateTransactionViewModel` (which had grown to
/// 900 LOC mixing form / split / receipt concerns) so:
///   - the receipt logic can be unit-tested in isolation,
///   - the create-VM's surface area shrinks toward its core
///     responsibility (form state + orchestration),
///   - future expansion (assignment, item edit) has a clear home.
///
/// External callers still talk to `CreateTransactionViewModel`
/// (`vm.pendingReceiptItems`, `vm.applyReceiptItems`,
/// `vm.reconcilePaidExtra`) — those are kept as shims that delegate
/// here, so this extraction is a pure refactor with zero callsite
/// churn outside the VM.
@MainActor
final class ReceiptItemController: ObservableObject {

    /// Items captured during the optional receipt scan flow.
    /// Persisted to `receipt_items` after the parent transaction is
    /// saved (see `CreateTransactionModal.commitTransaction`).
    @Published var items: [ReceiptItem] = []

    /// Replace the entire item list. Used by the receipt-scan
    /// completion path on the VM.
    func replaceAll(_ items: [ReceiptItem]) {
        self.items = items
    }

    /// Drop every item — invoked when the user wipes the amount or
    /// rescans an image.
    func clear() {
        items = []
    }

    // MARK: - Paid-extra placeholder

    /// Suffix that marks an item auto-inserted by the WhoPaid
    /// exceed flow.
    ///
    /// Two shapes:
    /// - Friend exceeded → `"{name}'s extra"` (suffix-based match)
    /// - User exceeded   → `"Extra"` (exact match — no possessive form
    ///   reads naturally on the user's own row)
    ///
    /// Used by `reconcilePaidExtra` to find/replace the previous
    /// placeholder across repeated exceed-confirms instead of
    /// stacking duplicates. Renaming an auto-added item via the items
    /// editor "graduates" it to a normal user-owned line — subsequent
    /// exceeds will add a fresh placeholder rather than rewrite the
    /// renamed one.
    static let paidExtraSuffix = "'s extra"
    static let paidExtraSelfName = "Extra"

    static func isPaidExtraItem(_ item: ReceiptItem) -> Bool {
        item.name == paidExtraSelfName || item.name.hasSuffix(paidExtraSuffix)
    }

    /// Reconcile the placeholder so that
    ///   Σ (items, including the placeholder) == newTotal.
    /// Called from `WhoPaidPickerView` callbacks after the user confirms
    /// payers (whether they exceeded the receipt total or not). The caller
    /// picks `payerName` per its own attribution rule:
    ///   • exceed-confirm path → the row that drove the overage (the
    ///     picker locks every other row once the sum hits the target so
    ///     there's a single unambiguous exceeder per edit session)
    ///   • non-exceed path → fallback to the largest payer (re-attribution
    ///     when payers change without re-triggering exceed)
    /// Idempotent — the amount is recomputed from the non-placeholder items
    /// every time, so re-confirming exceed updates the placeholder rather
    /// than accumulating bad totals.
    func reconcilePaidExtra(payerName: String, newTotal: Double) {
        guard !items.isEmpty else { return }
        let baseSum = items
            .filter { !Self.isPaidExtraItem($0) }
            .reduce(0) { $0 + $1.lineTotal }
        let excess = newTotal - baseSum
        // Tolerance matches the editor's `exactMatchEpsilon` so we don't
        // create a "0.001 paid extra" line from float noise.
        if excess > 0.005 {
            upsertPaidExtraItem(payerName: payerName, amount: excess)
        } else {
            // newTotal landed at or below the receipt items' actual sum —
            // any leftover placeholder from a prior exceed is now stale.
            items.removeAll { Self.isPaidExtraItem($0) }
        }
    }

    private func upsertPaidExtraItem(payerName: String, amount: Double) {
        // Self ("me" payer, conventionally named "You") reads better as
        // a bare "Extra" row — possessive "You's extra" is awkward.
        // Friends use `{name}'s extra`.
        let name: String
        if payerName == "You" {
            name = Self.paidExtraSelfName
        } else {
            name = "\(payerName)\(Self.paidExtraSuffix)"
        }
        if let idx = items.firstIndex(where: { Self.isPaidExtraItem($0) }) {
            // In-place update — preserve persistence fields (`syncID`,
            // `position`) so the SQLite layer treats this as an edit, not
            // a delete-then-insert that would rotate the row id.
            let existing = items[idx]
            items[idx] = ReceiptItem(
                name: name,
                quantity: nil,
                price: nil,
                total: amount,
                persistedID: existing.persistedID,
                transactionID: existing.transactionID,
                syncID: existing.syncID,
                position: existing.position,
                lastModified: Date()
            )
        } else {
            items.append(
                ReceiptItem(
                    name: name,
                    quantity: nil,
                    price: nil,
                    total: amount,
                    position: items.count
                )
            )
        }
        // Either branch leaves the placeholder unassigned (ADD appends a
        // fresh row, UPDATE rebuilds the row without preserving
        // `assignedParticipantIDs`) — and on UPDATE the exceeding payer
        // may even differ from the previous one, so the prior assignee
        // would be wrong anyway. Drop every assignment so the create
        // screen's orange-warning fires (`byItemsNeedsAssignments`) and
        // re-entering the orchestrator seeds back to `.itemAssignment(0)`
        // for a fresh walk that covers the new row alongside everything
        // else.
        for index in items.indices {
            items[index].assignedParticipantIDs = []
        }
    }
}

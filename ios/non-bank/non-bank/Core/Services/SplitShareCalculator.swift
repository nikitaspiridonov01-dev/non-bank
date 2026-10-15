import Foundation

/// Computes per-participant shares for the `byItems` split mode from
/// receipt items + per-item assignments.
///
/// Algorithm — two passes over the items:
///
/// 1. **Direct items** (`kind == .item`) are distributed by their
///    explicit assignees. An item with a single assignee adds the full
///    `lineTotal` to that participant; an item with multiple assignees
///    splits its `lineTotal` equally between them. Items with no
///    assignees contribute to no participant — the create flow surfaces
///    a warning before save when this is the case, so reaching the
///    calculator with unassigned items would only happen from a saved
///    transaction.
///
/// 2. **Proportional charges** (`fee`/`tip`) and **discounts**
///    (`kind == .discount`) are distributed proportionally to each
///    participant's running item-share total from pass 1. A participant
///    who took no items in pass 1 (their share is 0) thus gets a 0 cut
///    of the charges too — matching the TZ rule "skipped participants
///    are excluded from fees". Tax/VAT lines are filtered out before
///    they reach the calculator (see `ReceiptLineFilter`), so the
///    charge bucket is `fee`/`tip` only.
///
/// Returns a dictionary keyed by participant ID (`Friend.id` or
/// `ReceiptItem.selfParticipantID` for the user). Participants present
/// in the input set always appear in the output, even if their share is
/// 0 — callers can decide whether to filter zero rows out (a 0-share
/// participant means "skipped" and should be excluded from
/// `SplitInfo.friends` per the TZ).
enum SplitShareCalculator {

    /// Tolerance for the "did this participant take any items" check.
    /// 1¢ at typical receipt totals stays well below the smallest item
    /// in any practical receipt; cents-level arithmetic noise from
    /// dividing items by N assignees can otherwise round a real-zero
    /// participant up by a fraction.
    private static let zeroEpsilon: Double = 0.001

    /// Order in which charge kinds are distributed. Shared with
    /// `SplitItemBreakdown.chargeOrder`; changing one without the other
    /// makes the breakdown rows stop reconciling with the shares.
    static let chargeOrder: [ReceiptItem.Kind] = [.fee, .tip, .discount]

    /// Computes shares for a `byItems` split.
    ///
    /// - Parameters:
    ///   - items: All receipt lines (regular items + discounts + fee/
    ///     tip). Items must already have their kind classified
    ///     (caller relies on `ReceiptItem.kind`'s built-in classifier).
    ///   - participants: IDs that should appear in the output. Items
    ///     assigned to IDs outside this set are ignored — defensive
    ///     guard against stale assignments after a participant was
    ///     removed from the split.
    ///
    /// - Returns: Per-participant shares, each a whole number of cents.
    ///   Their sum equals the items' net total (sum of all assigned
    ///   `lineTotal`s plus charges) rounded to cents, exactly: item slices
    ///   and proportional cuts are allocated with `MoneyMath`, so no cent
    ///   is lost to `x / n` arithmetic.
    static func compute(
        items: [ReceiptItem],
        participants: Set<String>
    ) -> [String: Double] {
        var shares: [String: Double] = [:]
        for id in participants { shares[id] = 0 }
        guard !participants.isEmpty else { return shares }

        var directItemTotal: Double = 0

        // Pass 1 — direct items, equal-split between assignees.
        // Each line is split into whole cents (`MoneyMath.splitEvenly`),
        // so a 10.00 item shared by three is 3.34 + 3.33 + 3.33, not three
        // times 3.333…; the leftover cent goes to the first assignee.
        for item in items where item.kind == .item {
            let assignees = item.assignedParticipantIDs.filter(participants.contains)
            guard !assignees.isEmpty else { continue }
            let slices = MoneyMath.splitEvenly(item.lineTotal, count: assignees.count)
            for (id, slice) in zip(assignees, slices) {
                shares[id, default: 0] += slice
            }
            directItemTotal += item.lineTotal
        }

        // Pass 2 — proportional distribution of charges and discounts.
        // Skip when no item-share base exists (everyone took zero direct
        // items): we can't proportion without a denominator, and the UI
        // shouldn't have allowed this state to save anyway. Returning
        // the zero-shares dict matches what the natural fall-through
        // would produce.
        guard directItemTotal > zeroEpsilon else { return shares }

        // Each charge kind is distributed separately, in a fixed order,
        // in proportion to the pass-1 item base. Cuts are whole cents
        // (largest remainder); participants are visited in sorted-ID
        // order so the cent that cannot be split fairly lands on the
        // same person every time. `SplitItemBreakdown` repeats exactly
        // this sequence so its per-kind rows add up to these shares.
        let orderedIDs = participants.sorted()
        let base = orderedIDs.map { shares[$0] ?? 0 }
        for kind in chargeOrder {
            let kindSum = items.filter { $0.kind == kind }.reduce(0) { $0 + $1.lineTotal }
            guard abs(kindSum) > zeroEpsilon else { continue }
            let cuts = MoneyMath.allocate(kindSum, weights: base)
            for (id, cut) in zip(orderedIDs, cuts) {
                shares[id, default: 0] += cut
            }
        }

        return shares
    }
}

import Foundation

/// Display-only, per-participant **and** per-item breakdown of a
/// `byItems` split.
///
/// It mirrors `SplitShareCalculator.compute` exactly — pass 1 splits each
/// item's `lineTotal` equally between its assignees, pass 2 distributes
/// fee/tip/discount proportionally to each participant's item subtotal —
/// so every number it surfaces reconciles to the persisted `SplitInfo`
/// shares to the cent.
///
/// Unlike `SplitShareCalculator` (which aggregates everything into a flat
/// `[id: Double]`), this keeps the intermediate detail the UI needs: each
/// participant's per-item slices and their proportional cut of each charge
/// KIND, so the between-people sheet can render explicit "Service fee
/// (your share)" / "Discount (your share)" rows. Pure value type — it
/// never reads stores or writes anything.
enum SplitItemBreakdown {

    /// One participant's slice of a single `.item` line.
    struct ItemSlice: Identifiable, Equatable {
        let item: ReceiptItem
        /// `item.lineTotal / co-assignees` — this participant's portion.
        let slice: Double
        var id: UUID { item.id }
    }

    /// One participant's proportional cut of a charge kind (fee/tip/
    /// discount). `amount` is signed — discounts are negative. `name` is
    /// the source line's own receipt name (e.g. "Тариф за сервис") so the
    /// per-person breakdown labels charges exactly like the general receipt
    /// items list, instead of a generic "Service fee". Falls back to a
    /// generic kind label only when several differently-named lines of the
    /// same kind were summed into this one cut.
    struct ChargeCut: Identifiable, Equatable {
        let kind: ReceiptItem.Kind
        let name: String
        let amount: Double
        var id: String { kind.rawValue }
    }

    /// Generic label for a charge kind — used only as the multi-source
    /// fallback for `ChargeCut.name`.
    static func genericChargeName(_ kind: ReceiptItem.Kind) -> String {
        switch kind {
        case .fee:      return "Service fee"
        case .tip:      return "Tip"
        case .discount: return "Discount"
        case .item:     return ""
        }
    }

    /// Full breakdown for one participant.
    struct ParticipantBreakdown: Equatable {
        /// Per-item slices for the items this participant is assigned to.
        let items: [ItemSlice]
        /// Proportional cut of each present charge kind (fee/tip/discount).
        let charges: [ChargeCut]
        /// `Σ item slices + Σ charge cuts`. Equals this participant's
        /// `SplitShareCalculator` share (and thus their `SplitInfo.share`).
        let total: Double
    }

    /// Matches `SplitShareCalculator.zeroEpsilon` so the two stay in lockstep.
    private static let zeroEpsilon: Double = 0.001

    /// Deterministic charge-row order for the UI.
    private static let chargeOrder: [ReceiptItem.Kind] = [.fee, .tip, .discount]

    /// Per-participant breakdown for a `byItems` split.
    ///
    /// - Parameters:
    ///   - items: all receipt lines (items + fee/tip/discount).
    ///   - participants: the active roster (`Friend.id` /
    ///     `ReceiptItem.selfParticipantID`). Assignments to IDs outside
    ///     this set are ignored — the same stale-assignment guard
    ///     `SplitShareCalculator` applies.
    static func compute(
        items: [ReceiptItem],
        participants: Set<String>
    ) -> [String: ParticipantBreakdown] {
        guard !participants.isEmpty else { return [:] }

        // Pass 1 — direct items, equal-split between assignees.
        var perItems: [String: [ItemSlice]] = [:]
        var directBase: [String: Double] = [:]
        for id in participants { directBase[id] = 0 }
        var directItemTotal: Double = 0

        for item in items where item.kind == .item {
            let assignees = item.assignedParticipantIDs.filter(participants.contains)
            guard !assignees.isEmpty else { continue }
            let perAssignee = item.lineTotal / Double(assignees.count)
            for id in assignees {
                perItems[id, default: []].append(ItemSlice(item: item, slice: perAssignee))
                directBase[id, default: 0] += perAssignee
            }
            directItemTotal += item.lineTotal
        }

        // Charge sums + source line names per kind (signed; discount negative).
        var chargeByKind: [ReceiptItem.Kind: Double] = [:]
        var chargeNamesByKind: [ReceiptItem.Kind: [String]] = [:]
        for item in items where chargeOrder.contains(item.kind) {
            chargeByKind[item.kind, default: 0] += item.lineTotal
            chargeNamesByKind[item.kind, default: []].append(item.name)
        }
        let chargeSum = chargeByKind.values.reduce(0, +)
        // Same gating as SplitShareCalculator: no item base or no charges
        // → no proportional distribution.
        let canProportion = directItemTotal > zeroEpsilon && abs(chargeSum) > zeroEpsilon

        var result: [String: ParticipantBreakdown] = [:]
        for id in participants {
            let base = directBase[id] ?? 0
            let proportion = canProportion ? base / directItemTotal : 0

            // The total uses the FULL charge sum (not the filtered display
            // rows) so it stays bit-identical to SplitShareCalculator —
            // `Σ_kind (sum_kind × proportion) == chargeSum × proportion`.
            let chargeCutTotal = chargeSum * proportion

            var charges: [ChargeCut] = []
            if canProportion {
                for kind in chargeOrder {
                    guard let sum = chargeByKind[kind], abs(sum) > zeroEpsilon else { continue }
                    let cut = sum * proportion
                    // A zero-item participant gets a ~0 cut — omit the row.
                    guard abs(cut) > zeroEpsilon else { continue }
                    // Use the source line's own name when this kind came from
                    // a single distinctly-named line (the common case — one
                    // "Тариф за сервис"); otherwise a generic kind label.
                    let names = Set(
                        (chargeNamesByKind[kind] ?? [])
                            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                    )
                    let label = names.count == 1 ? names.first! : Self.genericChargeName(kind)
                    charges.append(ChargeCut(kind: kind, name: label, amount: cut))
                }
            }

            result[id] = ParticipantBreakdown(
                items: perItems[id] ?? [],
                charges: charges,
                total: base + chargeCutTotal
            )
        }
        return result
    }

    /// Who shares a single `.item` line (intersected with the active
    /// roster) and each one's equal slice. Drives the per-item "who shares
    /// this" detail sheet. Returns `[]` for non-item rows or rows with no
    /// assignees within the roster.
    static func claimants(
        of item: ReceiptItem,
        participants: Set<String>
    ) -> [(participantID: String, slice: Double)] {
        guard item.kind == .item else { return [] }
        let assignees = item.assignedParticipantIDs.filter(participants.contains)
        guard !assignees.isEmpty else { return [] }
        let perAssignee = item.lineTotal / Double(assignees.count)
        // Preserve assignment order so avatar ordering is stable.
        return assignees.map { (participantID: $0, slice: perAssignee) }
    }
}

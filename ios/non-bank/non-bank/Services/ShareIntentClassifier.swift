import Foundation

// MARK: - Share Intent

/// What the receiver-side flow should do with an incoming payload, given
/// the current state of their transactions. Computed by
/// `ShareIntentClassifier` — the UI layer just switches on the result and
/// presents the right surface (auto-create, picker, alert, no-op).
///
/// Marked `nonisolated` because the project's default actor isolation
/// is `MainActor` — without this, the synthesised `Equatable`
/// conformance is treated as main-actor-isolated and unit tests
/// (running on the test runner's actor, not main) can't compare values.
nonisolated enum ShareIntent: Equatable {
    /// No prior import for this `syncID`, and we can pin down which
    /// participant the receiver is **without** asking. Two ways this
    /// happens:
    ///   1. The payload has exactly one other participant — by
    ///      elimination, that's the receiver (`participantIndex = 0`).
    ///   2. The payload has multiple participants but one of them
    ///      carries an `id` matching the receiver's
    ///      `UserIDService.currentID()` — the sharer must have
    ///      previously imported a share from THIS receiver and stored
    ///      their real userID as a Friend, so they're identifiable
    ///      across this round-trip.
    /// Either way we skip the picker and feed `participantIndex` straight
    /// into `ReceivedTransactionMapper`.
    case createAuto(participantIndex: Int)

    /// No prior import for this `syncID`, the payload has multiple
    /// participants AND no `id` matched the receiver — we can't know
    /// which one is them. UI shows the "Who are you?" picker; the
    /// picked index then feeds into `ReceivedTransactionMapper`.
    case createWithPicker

    /// We already imported a transaction with this `syncID` and the
    /// stored checksum matches the new payload bit-for-bit. Nothing to
    /// do; just navigate to the existing transaction. Carries the local
    /// transaction ID so the UI can deep-link.
    case identical(existingID: Int)

    /// We already imported a transaction with this `syncID`, but the
    /// payload checksum is different — the sharer must have edited
    /// something. UI shows the "Friend wants to update this transaction"
    /// alert. The optional `knownParticipantIndex` is set when the
    /// receiver's `id` is in `payload.f[]` — on accept, we can commit
    /// directly without re-asking the picker. When `nil` and the split
    /// has multiple participants, the UI re-shows the picker.
    case updatePrompt(existingID: Int, knownParticipantIndex: Int?)

    /// Payload is structurally invalid (no participants, etc.). UI shows
    /// a generic "couldn't open the link" error.
    case malformed
}

// MARK: - Classifier

/// Pure function that reads the receiver-side state and decides what
/// `ShareIntent` to surface. No I/O, no `@MainActor`, no store access —
/// the caller passes a snapshot of the relevant transactions and a
/// closure for retrieving the previously-stored share checksum.
///
/// Why a closure for the checksum? Stored transactions don't carry the
/// payload directly — they're a `Transaction` record that was *built
/// from* a payload. We compare the *incoming payload's checksum* against
/// whatever the storage layer chose to record at import time (Phase 4b
/// stores `payloadChecksum` alongside the transaction). The closure
/// indirection lets this classifier ship before the storage layer is
/// final — tests pass a fixed dictionary, real wiring will pull from
/// the persistence column.
enum ShareIntentClassifier {
    static func classify(
        payload: SharedTransactionPayload,
        receiverID: String,
        existingTransactions: [Transaction],
        checksumOf: (Transaction) -> String?
    ) -> ShareIntent {
        // Fast-fail on structurally invalid payloads. With `f.isEmpty`
        // there's nobody to pair with — the UI should treat this as a
        // bad link rather than auto-create a one-person "split".
        guard !payload.f.isEmpty else { return .malformed }

        // Self-share short-circuit: the receiver IS the sharer (they
        // tapped their own link, e.g. testing the share flow on the
        // same device). The encoder excludes the sharer from `f[]`, so
        // the receiver isn't there to pick — and there's nothing to
        // create anyway, the transaction already exists in their store
        // (they made it). We just navigate to it.
        if receiverID == payload.s {
            if let existing = existingTransactions.first(where: { $0.syncID == payload.id }) {
                return .identical(existingID: existing.id)
            }
            // Edge case: user shared a transaction, then deleted it,
            // then tapped their own old link. Nothing to identify with —
            // surface the bad-link path rather than try to recreate
            // their own data from scratch.
            return .malformed
        }

        // Try to find the receiver in the participant list by their
        // real `UserIDService.currentID()`. This succeeds when the
        // sharer previously imported a share-link FROM this receiver
        // and stored their real userID as a Friend — at that point the
        // receiver becomes identifiable across the round-trip and we
        // can skip the "Who are you?" picker entirely.
        let knownIndex = payload.f.firstIndex(where: { $0.id == receiverID })

        // Look for an existing transaction with the same `syncID`. We
        // use first-match because a `syncID` is meant to be unique per
        // transaction; if multiple matches exist, that's a separate bug
        // we don't paper over here.
        if let existing = existingTransactions.first(where: { $0.syncID == payload.id }) {
            if let storedChecksum = checksumOf(existing),
               storedChecksum == payload.checksum {
                return .identical(existingID: existing.id)
            }
            return .updatePrompt(existingID: existing.id, knownParticipantIndex: knownIndex)
        }

        // No prior import. Auto-create when the receiver is
        // unambiguous — either:
        //   - we matched them by ID (knownIndex set, any participant count), or
        //   - exactly one participant exists (knownIndex unused, must be 0)
        // Otherwise fall back to the picker.
        if let idx = knownIndex {
            return .createAuto(participantIndex: idx)
        }
        if payload.f.count == 1 {
            return .createAuto(participantIndex: 0)
        }
        return .createWithPicker
    }
}

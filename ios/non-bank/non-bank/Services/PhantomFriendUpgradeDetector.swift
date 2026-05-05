import Foundation

// MARK: - Phantom Friend Upgrade Detector

/// Detects when an incoming share-link update lets us "upgrade" a
/// locally-created phantom Friend to a real, verified userID.
///
/// ## The scenario
///
/// 1. User A creates Friend "Bob" manually in the app. The Friend gets a
///    random `FriendIDGenerator` ID — call it `phantom_Bob`.
/// 2. User A creates a split with phantom_Bob, shares the link to the
///    real Bob (e.g. via iMessage).
/// 3. Real Bob taps the link. His app receives the share with
///    `payload.f = [{id: phantom_Bob, n: "Bob"}]` and creates his local
///    transaction with User A as a Friend (with A's real userID).
/// 4. Bob edits the transaction and shares back to A. His re-share's
///    `payload.s = bob_real_userID` and `payload.f = [{id: a_userID}]`
///    (phantom_Bob is GONE from the round-trip — it was just A's
///    locally-invented stand-in for Bob).
/// 5. User A receives the update. Without this detector we'd create a
///    NEW Friend with `bob_real_userID` and leave the old phantom_Bob
///    record orphaned, with all old transactions still referencing it.
///
/// ## What we detect
///
/// We compare the OLD transaction's friends (local data) with the NEW
/// payload's `f[]` (sender-side participants). Anyone in OLD but NOT in
/// NEW (excluding the receiver, who's "you" in their copy) is a
/// "phantom candidate" that disappeared in the round-trip — so they
/// must be the new sharer.
///
/// We require **exactly one** phantom missing. If multiple phantoms are
/// gone, the mapping is ambiguous — caller falls back to creating a new
/// Friend without merging.
enum PhantomFriendUpgradeDetector {

    /// Result of a detection pass.
    struct Upgrade: Equatable {
        /// The phantom Friend's current ID — what we'll replace
        /// everywhere.
        let phantomID: String
        /// The real userID we'll replace it with — equals `payload.s`.
        let realID: String
    }

    /// Returns the single phantom→real mapping if one can be inferred
    /// unambiguously, otherwise `nil`. Inputs are pure data — caller
    /// (the coordinator) provides:
    ///
    /// - `oldFriendIDsInTransaction`: receiver's existing copy of the
    ///   transaction's `splitInfo.friends.map(\.friendID)`. This is the
    ///   set of friends as the receiver currently sees them.
    /// - `newPayloadParticipantIDs`: `payload.f[].id` from the incoming
    ///   share-link.
    /// - `receiverID`: receiver's own `UserIDService.currentID()`. Used
    ///   to ignore the receiver in `newPayloadParticipantIDs` (they're
    ///   "you" in the new view, not a friend).
    /// - `sharerID`: `payload.s`. The candidate replacement ID.
    static func detectUpgrade(
        oldFriendIDsInTransaction: Set<String>,
        newPayloadParticipantIDs: [String],
        receiverID: String,
        sharerID: String
    ) -> Upgrade? {
        // The new sharer mustn't already be in the receiver's old
        // friend list under their real ID — that would mean the
        // round-trip didn't change anything (no phantom to upgrade).
        guard !oldFriendIDsInTransaction.contains(sharerID) else {
            return nil
        }

        // What the OLD transaction had as friends, minus anyone who's
        // also in the NEW payload (those people stayed put across the
        // round-trip — Charlie remained Charlie). Receiver isn't in
        // OLD friends to begin with (they're "you"), so we don't need
        // to subtract them here.
        let newIDsExcludingReceiver = Set(newPayloadParticipantIDs.filter { $0 != receiverID })
        let phantomCandidates = oldFriendIDsInTransaction
            .subtracting(newIDsExcludingReceiver)
            // Defensive: if the sharerID somehow already appeared in
            // OLD, exclude it — we'd be "upgrading" them to themselves.
            .subtracting([sharerID])

        // Auto-merge only when there's a single unambiguous candidate.
        // Two or more missing phantoms = we can't tell which is the
        // sharer; caller leaves them all alone and just creates a new
        // Friend record for the sharer.
        guard phantomCandidates.count == 1, let phantomID = phantomCandidates.first else {
            return nil
        }
        return Upgrade(phantomID: phantomID, realID: sharerID)
    }
}

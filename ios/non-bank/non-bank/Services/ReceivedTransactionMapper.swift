import Foundation

// MARK: - Resolved Share

/// What the mapper produces from an incoming payload + receiver's
/// context. The caller (Phase 4c-e UI integration) takes this and
/// commits the changes to the relevant stores in one batch.
///
/// We deliberately split "create new Friend / Category" from "create
/// Transaction" because:
///  - The receiver's `FriendStore` / `CategoryStore` operate
///    independently from `TransactionStore` and need to be updated
///    first (Transaction references Category by title and Friends by
///    ID, both of which must already exist).
///  - The UI may want to show a "you'll also create a new friend / new
///    category" disclosure before the user confirms.
struct ResolvedShare: Equatable {
    /// Ready-to-insert `Transaction`. Carries the receiver-perspective
    /// `splitInfo` (with the sharer as a Friend, not as the user).
    let transaction: Transaction

    /// Friends that don't exist on the receiver's side yet and must be
    /// inserted before the transaction. The sharer is always at index
    /// 0 when included so callers can show them prominently in any
    /// "you'll add these contacts" disclosure.
    let newFriends: [Friend]

    /// Category to create on the receiver's side. `nil` when the
    /// payload's category title matches an existing one (we reuse it
    /// even if the emoji differs — title equality wins over icon).
    let newCategory: Category?

    /// SHA-256 checksum of the payload that produced this resolution.
    /// Caller stores this alongside the transaction so future imports
    /// of the same `syncID` can detect "byte-identical" and short-circuit.
    let payloadChecksum: String
}

// MARK: - Errors

enum ReceivedTransactionMapperError: LocalizedError {
    /// Picker UI returned an out-of-bounds index. Should never happen if
    /// the picker reads `payload.f.count` to bound itself.
    case invalidParticipantIndex(picked: Int, available: Int)

    var errorDescription: String? {
        switch self {
        case .invalidParticipantIndex(let picked, let available):
            return "Couldn't apply the share link: invalid participant index \(picked) of \(available)."
        }
    }
}

// MARK: - Mapper

/// Pure function that converts an incoming `SharedTransactionPayload`
/// into a `ResolvedShare` from the receiver's perspective.
///
/// ## Identity flip
/// In the sharer's app, the sharer is "you" and `f[]` is "everyone
/// else". On the receiver's side, the *receiver* is "you" — so we:
///   1. Pull the receiver out of `f[]` (their share / paidAmount become
///      the new transaction's `myShare` / `paidByMe`).
///   2. Insert the **sharer** into the new `splitInfo.friends[]` with a
///      placeholder name (`"Friend"` for v1; product will polish later).
///   3. Keep the other `f[]` entries as friends with their original names.
///
/// ## Idempotent friend / category creation
/// Receiver may already know some of the friends or have the same
/// category. The mapper:
///   - Reports only friends/categories that need to be CREATED.
///   - Reuses existing records (matched by ID for friends, by exact
///     title for categories).
///
/// ## Emoji uniqueness for new categories
/// User explicitly asked for this: when the payload's category title
/// doesn't match any of the receiver's, we create a new one and pick a
/// **non-conflicting** emoji. Sharer's emoji is preferred; if it
/// collides with another category the receiver owns, we walk a small
/// fallback list.
enum ReceivedTransactionMapper {

    /// Fallback emoji pool for new categories whose payload-supplied
    /// emoji collides with an existing one on the receiver's side.
    /// Ordered from most-generic to most-specific so the substitution
    /// stays readable. None of these are in the standard category seed
    /// set, so collisions are unlikely with the seeded categories.
    private static let fallbackEmojis: [String] = [
        "📦", "🏷️", "🎁", "🛒", "💼", "📋",
        "🎯", "⭐️", "💡", "📌", "🔖", "🗂️", "🧾"
    ]

    /// Map an incoming payload + receiver context into the changes
    /// needed on the receiver's side. Doesn't touch any stores — the
    /// caller commits the resulting `ResolvedShare`.
    ///
    /// - Parameter receiverParticipantIndex: which index of `payload.f[]`
    ///   the receiver is. For `.createAuto` (1-participant case) pass
    ///   `0`; for `.createWithPicker` pass whatever the user picked.
    /// - Parameter existingTransaction: the receiver-side transaction
    ///   record for re-import / update flows. **When non-nil the
    ///   mapper preserves the user's `title`, `category`, and `emoji`
    ///   from this record** — so a sharer renaming the line or moving
    ///   it to a different category on their side doesn't overwrite
    ///   the receiver's personal taxonomy. Pass `nil` for first-time
    ///   imports so all metadata comes from the payload.
    /// - Parameter sharerPlaceholderName: name to use when the payload
    ///   doesn't carry an `sn` value (older app versions, or sharers
    ///   who haven't set their profile name yet). Spec is `"Friend"` —
    ///   when `payload.sn` IS set, we use that real name instead.
    static func map(
        payload: SharedTransactionPayload,
        receiverParticipantIndex: Int,
        existingFriends: [Friend],
        existingCategories: [Category],
        nextTransactionID: Int,
        existingTransaction: Transaction? = nil,
        sharerPlaceholderName: String = "Friend"
    ) throws -> ResolvedShare {
        guard payload.f.indices.contains(receiverParticipantIndex) else {
            throw ReceivedTransactionMapperError.invalidParticipantIndex(
                picked: receiverParticipantIndex,
                available: payload.f.count
            )
        }

        let receiverParticipant = payload.f[receiverParticipantIndex]
        let otherParticipants = payload.f.enumerated()
            .filter { $0.offset != receiverParticipantIndex }
            .map(\.element)

        // ── Friends to ensure on receiver's side ─────────────────────
        let existingFriendIDs = Set(existingFriends.map(\.id))
        var newFriends: [Friend] = []

        // Sharer first — they become a Friend in the receiver's app.
        // Stable ID = sharer's `UserIDService` value (carried in
        // `payload.s`), so re-shares from the same person reuse the
        // same Friend record without duplicates. If the payload carries
        // a real display name (`sn`), we use that — otherwise the
        // generic placeholder. The new Friend is marked
        // `isConnected = true` because the share-link round-trip proves
        // they're a real user with a real userID, not a manual contact.
        if !existingFriendIDs.contains(payload.s) {
            let sharerName = (payload.sn?.isEmpty == false) ? payload.sn! : sharerPlaceholderName
            newFriends.append(Friend(id: payload.s, name: sharerName, isConnected: true))
        }

        // Then the other participants — in payload order, skipping the
        // receiver themselves (they're "you" now).
        for participant in otherParticipants where !existingFriendIDs.contains(participant.id) {
            // Avoid double-adding if the same ID appears twice in the
            // newFriends list (defensive — the encoder shouldn't emit
            // duplicates, but worth a check).
            guard !newFriends.contains(where: { $0.id == participant.id }) else { continue }
            newFriends.append(Friend(id: participant.id, name: participant.n))
        }

        // ── Category resolution ──────────────────────────────────────
        // Branches by import vs update:
        //  - **Update** (existingTransaction != nil): keep the user's
        //    chosen category. Look it up by the existing transaction's
        //    category title; on miss (the receiver deleted the
        //    category between import and update) re-create it from
        //    the existing record's stored emoji/title rather than
        //    falling through to the payload — the user's taxonomy
        //    still wins.
        //  - **Create** (existingTransaction == nil): match payload's
        //    category title to receiver's; on miss create new with
        //    a non-conflicting emoji (current behaviour).
        let resolvedCategory: Category
        let newCategory: Category?
        if let existing = existingTransaction {
            if let receiverCategory = existingCategories.first(where: { $0.title == existing.category }) {
                resolvedCategory = receiverCategory
                newCategory = nil
            } else {
                let restored = Category(emoji: existing.emoji, title: existing.category)
                resolvedCategory = restored
                newCategory = restored
            }
        } else if let existing = existingCategories.first(where: { $0.title == payload.cn }) {
            resolvedCategory = existing
            newCategory = nil
        } else {
            let emoji = uniqueEmoji(
                preferred: payload.ce,
                takenBy: existingCategories
            )
            let created = Category(emoji: emoji, title: payload.cn)
            resolvedCategory = created
            newCategory = created
        }

        // ── Receiver-perspective SplitInfo ───────────────────────────
        let receiverPaid = receiverParticipant.pa
        let receiverShare = receiverParticipant.sh
        let receiverLent = receiverPaid - receiverShare

        // Sharer's contribution as the receiver sees it: paid `payload.pa`
        // out of pocket, owes `payload.ms` as their fair share.
        let sharerAsFriend = FriendShare(
            friendID: payload.s,
            share: payload.ms,
            paidAmount: payload.pa
        )
        // Other participants are kept verbatim — same IDs, same shares.
        let otherShares: [FriendShare] = otherParticipants.map {
            FriendShare(friendID: $0.id, share: $0.sh, paidAmount: $0.pa)
        }
        let receiverFriends = [sharerAsFriend] + otherShares

        let receiverSplit = SplitInfo(
            totalAmount: payload.ta,
            paidByMe: receiverPaid,
            myShare: receiverShare,
            lentAmount: receiverLent,
            friends: receiverFriends,
            splitMode: payload.sm.flatMap(SplitMode.init(rawValue:))
        )

        // ── Transaction itself ───────────────────────────────────────
        // Title / category / emoji are taken from `existingTransaction`
        // when this is an update, so the user's local edits to those
        // fields survive the re-import. For first-time create they
        // come from the payload (and the resolved category record).
        let txTitle = existingTransaction?.title ?? payload.t
        let txCategory = existingTransaction?.category ?? resolvedCategory.title
        let txEmoji = existingTransaction?.emoji ?? resolvedCategory.emoji

        let transaction = Transaction(
            id: nextTransactionID,
            syncID: payload.id,
            emoji: txEmoji,
            category: txCategory,
            title: txTitle,
            description: nil,
            amount: receiverPaid,
            currency: payload.c,
            date: Date(timeIntervalSince1970: payload.d),
            type: payload.k == "inc" ? .income : .expenses,
            tags: nil,
            splitInfo: receiverSplit
        )

        return ResolvedShare(
            transaction: transaction,
            newFriends: newFriends,
            newCategory: newCategory,
            payloadChecksum: payload.checksum
        )
    }

    // MARK: - Emoji uniqueness helper

    /// Pick an emoji for a new category that doesn't collide with any of
    /// the receiver's existing categories. Prefer the sharer's choice;
    /// fall back to a curated pool; as a last resort return the
    /// preferred glyph anyway and let the user resolve manually.
    static func uniqueEmoji(preferred: String, takenBy categories: [Category]) -> String {
        let taken = Set(categories.map(\.emoji))
        if !taken.contains(preferred) { return preferred }
        for candidate in fallbackEmojis where !taken.contains(candidate) {
            return candidate
        }
        // Truly exhausted — just return the preferred glyph and accept
        // the collision. Two categories with the same emoji is ugly but
        // not broken; the user can edit one of them in Settings.
        return preferred
    }
}

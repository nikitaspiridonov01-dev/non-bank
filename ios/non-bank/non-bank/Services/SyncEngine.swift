import Foundation

/// Server-mediated sync orchestrator (Phase 1). Glues the pieces built in
/// A/B/C1 together:
///   * UPLOAD — when a split transaction is saved/edited, push an
///     encrypted delivery to every PAIRED participant (`SyncDeliveryService`
///     + `SyncDeliveryCrypto`, addressed by `SyncPairing.pairHMAC`).
///   * PULL  — on app foreground, fetch this device's inbox, decrypt each
///     delivery (by trying each paired friend's key), apply it headlessly
///     through the SAME pipeline the manual share-link import uses
///     (`ShareIntentClassifier` + `ReceivedTransactionMapper`), then ack.
///
/// Weak store refs are wired in `MainTabView.onAppear` (mirroring
/// `SyncManager`). Everything is best-effort and never blocks the UI: a
/// transaction is always saved locally first, so a sync failure is a missed
/// delivery (retried next foreground), never data loss.
///
/// Version safety: uploads carry `transaction.editVersion`; the server
/// UPSERT and the recipient's `ShareIntentClassifier` both refuse to apply
/// anything not strictly newer, so concurrent / out-of-order edits can't
/// clobber a fresher copy (see Phase A/B).
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    weak var transactionStore: TransactionStore?
    weak var friendStore: FriendStore?
    weak var categoryStore: CategoryStore?
    weak var receiptItemStore: ReceiptItemStore?

    /// Invoked on the main actor with a transaction's syncID when an
    /// auto-upload to a PAIRED recipient fails (offline / server error), so
    /// the UI can offer the manual share link as a fallback. Wired in
    /// `MainTabView`; uploads are only ever triggered by a user save/edit,
    /// so this fires in a context where a share prompt is appropriate.
    var onUploadFailure: ((String) -> Void)?

    /// Re-entrancy guard so overlapping foregrounds don't double-pull.
    private var isPulling = false

    private init() {}

    // MARK: - Upload (sender side)

    /// Push the given transaction to every paired participant. No-op for
    /// non-split transactions or when no participant is a connected
    /// (paired) friend. Fire-and-forget per recipient.
    func uploadSplit(_ transaction: Transaction) {
        guard transaction.splitInfo != nil,
              let friendStore, let categoryStore else { return }

        let myID = UserIDService.currentID()
        let myName = UserProfileService.displayName()
        guard let category = categoryStore.categories.first(where: { $0.title == transaction.category })
        else { return }

        // Build the payload once (sharer perspective). payload.f carries
        // every participant by id, so a paired recipient finds themselves
        // by their userID on the other side.
        guard let payload = try? SharedTransactionLink.buildPayload(
            transaction: transaction,
            sharerID: myID,
            sharerName: myName,
            friends: friendStore.friends,
            category: category
        ) else { return }

        let pairedRecipients = (transaction.splitInfo?.friends ?? []).compactMap { share -> Friend? in
            guard let f = friendStore.friends.first(where: { $0.id == share.friendID }),
                  f.isConnected, f.id != myID else { return nil }
            return f
        }
        guard !pairedRecipients.isEmpty else { return }

        for recipient in pairedRecipients {
            let pairHMAC = SyncPairing.pairHMAC(myID, recipient.id)
            guard let cipher = try? SyncDeliveryCrypto.encrypt(payload, myID: myID, peerID: recipient.id)
            else { continue }
            let recipientID = recipient.id
            let syncID = transaction.syncID
            let version = transaction.editVersion
            let checksum = payload.checksum
            Task.detached {
                let ok = await SyncDeliveryService.upload(
                    pairHMAC: pairHMAC, recipientID: recipientID, txSyncID: syncID,
                    version: version, op: "upsert", payloadCiphertext: cipher, checksum: checksum
                )
                if !ok {
                    // Offline / server error reaching a paired friend — let the
                    // UI offer the manual share link as a fallback.
                    await MainActor.run { SyncEngine.shared.onUploadFailure?(syncID) }
                }
            }
        }

        // byItems carries its receipt items over the SAME encrypted
        // share-items channel the manual share uses (keyed by the payload
        // checksum), so a synced byItems split stays byItems on the other
        // side instead of degrading to byAmount.
        uploadItemsIfNeeded(transaction)
    }

    /// Upload a byItems transaction's receipt items to the share-items
    /// channel keyed by the current payload checksum, so a paired recipient
    /// can reconstruct the per-item split. No-op for non-byItems / when the
    /// store has no items for this tx. Idempotent (UPSERT). Re-uploaded on
    /// every edit because the checksum changes with the content.
    func uploadItemsIfNeeded(_ transaction: Transaction) {
        guard transaction.splitInfo?.splitMode == .byItems,
              let receiptItemStore, let friendStore, let categoryStore else { return }
        let items = receiptItemStore.items(forTransactionID: transaction.id)
        guard !items.isEmpty else { return }
        let myID = UserIDService.currentID()
        guard let category = categoryStore.categories.first(where: { $0.title == transaction.category }),
              let payload = try? SharedTransactionLink.buildPayload(
                transaction: transaction, sharerID: myID,
                sharerName: UserProfileService.displayName(),
                friends: friendStore.friends, category: category),
              let url = try? SharedTransactionLink.buildURL(payload: payload),
              let urlPayload = SharedTransactionLink.urlPayloadString(of: url)
        else { return }
        let shareID = payload.checksum
        Task {
            do {
                let cipher = try ShareItemsCrypto.encryptItems(items, urlPayload: urlPayload)
                try await ShareItemsService.shared.upload(shareID: shareID, ciphertextBase64: cipher)
            } catch {
                // Best-effort — if this fails the recipient simply degrades
                // to byAmount for now and re-syncs on the next edit.
            }
        }
    }

    /// Tell paired participants to delete their copy (tombstone). Called
    /// when the user deletes a shared split transaction. Best-effort.
    func uploadDelete(syncID: String, participantIDs: [String]) {
        guard let friendStore else { return }
        let myID = UserIDService.currentID()
        let recipients = participantIDs.compactMap { id -> Friend? in
            guard let f = friendStore.friends.first(where: { $0.id == id }),
                  f.isConnected, f.id != myID else { return nil }
            return f
        }
        for recipient in recipients {
            let pairHMAC = SyncPairing.pairHMAC(myID, recipient.id)
            let recipientID = recipient.id
            Task.detached {
                await SyncDeliveryService.upload(
                    pairHMAC: pairHMAC, recipientID: recipientID, txSyncID: syncID,
                    // A high version keeps the tombstone monotonic vs the
                    // last edit the recipient saw; the server still guards
                    // with `>` so a replayed older op can't resurrect it.
                    version: Int.max, op: "delete", payloadCiphertext: "", checksum: nil
                )
            }
        }
    }

    // MARK: - Pull + apply (recipient side)

    /// Fetch + apply this device's inbox, then ack what we applied. Safe to
    /// call on every foreground; guarded against overlap.
    func pullAndApply() async {
        guard !isPulling else { return }
        guard let transactionStore, let friendStore,
              let categoryStore, let receiptItemStore else { return }
        isPulling = true
        defer { isPulling = false }

        let myID = UserIDService.currentID()
        let deliveries = await SyncDeliveryService.fetchInbox(recipientID: myID)
        guard !deliveries.isEmpty else { return }

        // Candidate senders: our connected (paired) friends. We don't know
        // the sender id from the row, so we try each one's key — the
        // AES-GCM tag authenticates exactly the right one.
        let pairedFriends = friendStore.friends.filter { $0.isConnected }
        var acks: [(txSyncID: String, version: Int)] = []

        for delivery in deliveries {
            if delivery.op == "pair" {
                // Reciprocal pairing handshake from someone who opened OUR
                // share link: it tells us their real user id so we can upgrade
                // the phantom friend we created for them to a connected
                // real-id friend — after which our uploads actually reach them.
                if await applyPairHandshake(delivery, myID: myID, friendStore: friendStore, transactionStore: transactionStore) {
                    acks.append((delivery.tx_sync_id, delivery.version))
                }
                continue
            }
            if delivery.op == "delete" {
                if let existing = transactionStore.transactions.first(where: { $0.syncID == delivery.tx_sync_id }) {
                    transactionStore.delete(id: existing.id)
                }
                acks.append((delivery.tx_sync_id, delivery.version))
                continue
            }

            var payload: SharedTransactionPayload?
            for friend in pairedFriends {
                if let decoded = SyncDeliveryCrypto.tryDecrypt(
                    base64: delivery.payload, myID: myID, candidatePeerID: friend.id
                ) {
                    payload = decoded
                    break
                }
            }
            // Couldn't decrypt with any paired friend's key — likely the
            // sender was removed locally. Leave it un-acked; it TTLs out
            // server-side. (Don't ack what we didn't apply.)
            guard let payload else { continue }

            // Sync context: WE are the recipient (this inbox is ours), so we
            // resolve our own participant index directly rather than via the
            // picker-oriented `ShareIntentClassifier`. The classifier returns
            // `.createWithPicker` (which a headless pull can only SKIP)
            // whenever the sharer addressed us by a phantom id instead of our
            // real userID — and that silent skip is exactly why pushed
            // deliveries never applied (they only landed via the manual web
            // link, which has the picker). Here we instead match ourselves by
            // real id, or — in an unambiguous 2-person split — as the single
            // non-sharer participant. Update-vs-create is decided by whether we
            // already hold this syncID, so an edit UPDATES instead of creating
            // a duplicate.
            let existing = transactionStore.transactions.first { $0.syncID == delivery.tx_sync_id }

            // Idempotent re-pull / stale-edit guard: we already hold this
            // version (or newer — e.g. we edited locally) → just ack so the
            // server stops re-delivering. delivery.version == payload.ev.
            if let existing, delivery.version <= existing.editVersion {
                acks.append((delivery.tx_sync_id, delivery.version))
                continue
            }

            let myIndex = payload.f.firstIndex(where: { $0.id == myID })
            let nonSharerIndices = payload.f.indices.filter { payload.f[$0].id != payload.s }
            guard let index = myIndex ?? (nonSharerIndices.count == 1 ? nonSharerIndices.first : nil) else {
                // Genuinely ambiguous (3+ participants and we aren't id-matched)
                // — can't pick "us" headlessly. Leave un-acked for the manual
                // link flow (which has the picker); it TTLs out server-side.
                continue
            }

            if await applyHeadless(payload: payload, index: index,
                                   existingID: existing?.id, isUpdate: existing != nil,
                                   transactionStore: transactionStore, friendStore: friendStore,
                                   categoryStore: categoryStore, receiptItemStore: receiptItemStore) {
                acks.append((delivery.tx_sync_id, delivery.version))
            }
        }

        await SyncDeliveryService.ack(recipientID: myID, acks: acks)
    }

    /// Apply a reciprocal pairing handshake. We don't know the sender's real
    /// id, so we try each of our friends' ids as the handshake key
    /// (HKDF(sorted(myID, friend.id))) — the one that authenticates is the
    /// phantom friend the sender opened our link as. Upgrade that phantom to
    /// the sender's real id (carried in the handshake) and mark it connected,
    /// so our future uploadSplit reaches them. Returns true if matched/applied.
    private func applyPairHandshake(
        _ delivery: SyncDeliveryService.InboxDelivery,
        myID: String,
        friendStore: FriendStore,
        transactionStore: TransactionStore
    ) async -> Bool {
        for friend in friendStore.friends {
            guard let handshake = SyncDeliveryCrypto.tryDecryptHandshake(
                base64: delivery.payload, keyA: myID, keyB: friend.id
            ) else { continue }
            // Matched: `friend` is the phantom; `handshake.rid` is their real id.
            if friend.id != handshake.rid {
                await friendStore.upgradePhantom(phantomID: friend.id, realID: handshake.rid)
                await transactionStore.upgradePhantomFriendID(from: friend.id, to: handshake.rid)
            } else {
                friendStore.markConnected(id: friend.id)
            }
            return true
        }
        // No matching friend (maybe they aren't in our list yet) — leave it
        // un-acked so a later pull can retry once the friend exists.
        return false
    }

    /// Headless apply — the non-UI sibling of
    /// `ShareLinkCoordinator.pickedParticipant`. Reuses the same mapper +
    /// store writes, minus the routing state, the picker, and the separate
    /// share-items channel (synced deliveries carry only the financial
    /// summary; a `.byItems` split degrades to `.byAmount` on apply, the
    /// mapper's documented no-items fallback). Returns whether it applied.
    private func applyHeadless(
        payload: SharedTransactionPayload,
        index: Int,
        existingID: Int?,
        isUpdate: Bool,
        transactionStore: TransactionStore,
        friendStore: FriendStore,
        categoryStore: CategoryStore,
        receiptItemStore: ReceiptItemStore
    ) async -> Bool {
        // Phantom-upgrade pass (update path only) — mirror the coordinator
        // so a manually-added contact gets unified with the real userID.
        if isUpdate, let txID = existingID,
           let existing = transactionStore.transactions.first(where: { $0.id == txID }),
           let split = existing.splitInfo {
            if let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
                oldFriendIDsInTransaction: Set(split.friends.map(\.friendID)),
                newPayloadParticipantIDs: payload.f.map(\.id),
                receiverID: UserIDService.currentID(),
                sharerID: payload.s
            ) {
                await friendStore.upgradePhantom(phantomID: upgrade.phantomID, realID: upgrade.realID)
                await transactionStore.upgradePhantomFriendID(from: upgrade.phantomID, to: upgrade.realID)
            }
        }

        let existingTx: Transaction? = isUpdate
            ? transactionStore.transactions.first(where: { $0.id == existingID })
            : nil
        let receiverHasLocalItems: Bool = {
            guard let txID = existingTx?.id else { return false }
            return !receiptItemStore.items(forTransactionID: txID).isEmpty
        }()

        // Fetch the byItems receipt items from the share-items channel, the
        // same one the manual import uses (keyed by the payload checksum).
        // A byItems split degrades to byAmount ONLY when the channel has
        // nothing / can't be decrypted — never by default.
        var fetchedItems: [ReceiptItem] = []
        if payload.sm == SplitMode.byItems.rawValue,
           let url = try? SharedTransactionLink.buildURL(payload: payload),
           let urlPayload = SharedTransactionLink.urlPayloadString(of: url),
           let base64 = try? await ShareItemsService.shared.fetch(shareID: payload.checksum),
           let decrypted = try? ShareItemsCrypto.decryptItems(base64: base64, urlPayload: urlPayload) {
            fetchedItems = decrypted
        }
        let itemsCameFromShare = !fetchedItems.isEmpty

        do {
            let resolved = try ReceivedTransactionMapper.map(
                payload: payload,
                receiverParticipantIndex: index,
                existingFriends: friendStore.friends,
                existingCategories: categoryStore.categories,
                nextTransactionID: existingID ?? 0,
                existingTransaction: existingTx,
                receiverHasLocalItemsForTx: receiverHasLocalItems,
                payloadCameWithItems: itemsCameFromShare
            )
            for friend in resolved.newFriends {
                await friendStore.add(friend)
            }
            if let cat = resolved.newCategory {
                categoryStore.addCategory(cat)
            }
            let appliedTxID: Int?
            if isUpdate {
                await transactionStore.updateAndWait(resolved.transaction)
                appliedTxID = existingID
            } else {
                appliedTxID = await transactionStore.addAndReturnID(resolved.transaction)
            }
            // Persist the synced items under the applied tx, rewriting
            // assignees from the sender's identity space into ours (same
            // helper the manual import uses).
            if itemsCameFromShare, let txID = appliedTxID {
                let rewritten = ReceivedTransactionMapper.rewriteItemAssignees(
                    items: fetchedItems, payload: payload, receiverParticipantIndex: index
                )
                await receiptItemStore.saveItems(rewritten, for: txID)
            }
            return appliedTxID != nil
        } catch {
            return false
        }
    }
}

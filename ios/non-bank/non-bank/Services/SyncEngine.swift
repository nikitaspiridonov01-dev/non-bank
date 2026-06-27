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

    /// Invoked on the main actor with a connected friend's display name when
    /// the SHARER side NEWLY connects a friend — via a reciprocal pairing
    /// handshake (`applyPairHandshake`) or the self-heal path
    /// (`selfHealPairing`). Wired in `MainTabView` to surface the "you're now
    /// synced" toast. The recipient's own import toast (`ShareLinkCoordinator`)
    /// is unaffected.
    var onPaired: ((String) -> Void)?

    /// Re-entrancy guard so overlapping foregrounds don't double-pull.
    private var isPulling = false

    /// DI-resolved analytics — telemetry ONLY, never gates or alters sync.
    /// Lazy so the singleton can exist before `non_bankApp.init` finishes
    /// registering services. `AnalyticsServiceProtocol` is `Sendable`, so a
    /// captured local can cross into `Task.detached` without isolation warnings.
    private lazy var analytics: AnalyticsServiceProtocol =
        DIContainer.shared.resolve(AnalyticsServiceProtocol.self)

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

        // ORDERING (race fix): a byItems split carries its receipt items over
        // a SEPARATE share-items channel keyed by the payload checksum. The
        // delivery (and its push) must NOT outrun the items — if it does, the
        // recipient's headless fetch 404s, `itemsCameFromShare` is false, and
        // the split degrades byItems→byAmount. So await the items upload FIRST
        // inside one Task, then fan the deliveries out concurrently. For
        // non-byItems splits `uploadItems` returns immediately (no latency).
        let recipientIDs = pairedRecipients.map(\.id)
        let syncID = transaction.syncID
        let version = transaction.editVersion
        let checksum = payload.checksum
        // Telemetry only (never gates the upload): one event per auto-synced
        // split, tagged with how many paired recipients it's dispatched to.
        // Captured so the detached per-recipient tasks below can log outcomes.
        let analytics = self.analytics
        analytics.track(.splitAutoSynced(recipientCount: recipientIDs.count))
        Task {
            // 1. Items first — block deliveries until they're in place.
            await self.uploadItems(transaction)
            // 2. Deliveries — fan out concurrently now that the items are
            //    fetchable the moment a delivery lands.
            for recipientID in recipientIDs {
                let pairHMAC = SyncPairing.pairHMAC(myID, recipientID)
                guard let cipher = try? SyncDeliveryCrypto.encrypt(payload, myID: myID, peerID: recipientID)
                else { continue }
                Task.detached {
                    switch await SyncDeliveryService.upload(
                        pairHMAC: pairHMAC, recipientID: recipientID, senderID: myID,
                        txSyncID: syncID,
                        version: version, op: "upsert", payloadCiphertext: cipher, checksum: checksum
                    ) {
                    case .ok:
                        break
                    case .pairingInactive:
                        // The recipient REVOKED this pairing (removed us as a
                        // friend), so the server rejects our delivery. Grey them
                        // locally so the "synced" indicator stops lying, then
                        // offer the manual share link so the user can re-share +
                        // re-pair. Next edit takes the clean unpaired path
                        // (no more silent 409s).
                        await MainActor.run {
                            friendStore.markDisconnected(id: recipientID)
                            SyncEngine.shared.onUploadFailure?(syncID)
                            analytics.track(.syncUploadFailed(reason: .pairingInactive))
                        }
                    case .failed:
                        // Transient (offline / 5xx) — keep the pairing; just
                        // offer the manual share link as a fallback.
                        await MainActor.run {
                            SyncEngine.shared.onUploadFailure?(syncID)
                            analytics.track(.syncUploadFailed(reason: .failed))
                        }
                    }
                }
            }
        }
    }

    /// Fire-and-forget wrapper around `uploadItems`. Kept for the
    /// `CreateTransactionModal` new-tx-with-receipt-scan path, which only
    /// learns the autoincrement transaction id (and so can link / upload its
    /// items) AFTER `uploadSplit` has already run — it tops up the
    /// share-items channel out-of-band there.
    func uploadItemsIfNeeded(_ transaction: Transaction) {
        Task { await uploadItems(transaction) }
    }

    /// Upload a byItems transaction's receipt items to the share-items
    /// channel keyed by the current payload checksum, so a paired recipient
    /// can reconstruct the per-item split. No-op for non-byItems / when the
    /// store has no items for this tx. Idempotent (UPSERT). Re-uploaded on
    /// every edit because the checksum changes with the content. `async` so
    /// the upload flow can AWAIT it before sending deliveries (race fix).
    func uploadItems(_ transaction: Transaction) async {
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
        do {
            let cipher = try ShareItemsCrypto.encryptItems(items, urlPayload: urlPayload)
            try await ShareItemsService.shared.upload(shareID: shareID, ciphertextBase64: cipher)
        } catch {
            // Best-effort — if this fails the recipient simply degrades
            // to byAmount for now and re-syncs on the next edit.
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
                    pairHMAC: pairHMAC, recipientID: recipientID, senderID: myID,
                    txSyncID: syncID,
                    // A high version keeps the tombstone monotonic vs the last
                    // edit the recipient saw; the server still guards with `>`
                    // so a replayed older op can't resurrect it. MUST be
                    // JSON-safe: `Int.max` overflowed `Int` on the recipient's
                    // decode and poisoned the whole inbox — see
                    // `SyncDeliveryService.tombstoneVersion`.
                    version: SyncDeliveryService.tombstoneVersion,
                    op: "delete", payloadCiphertext: "", checksum: nil
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

        // Wait for the local stores' initial load before processing the inbox.
        // On a COLD LAUNCH (e.g. tapping a push) this pull can otherwise run
        // while TransactionStore/FriendStore init load() is still in flight,
        // which breaks BOTH:
        //  • the transaction create-vs-update lookup (empty `transactions` → an
        //    incoming EDIT finds no existing row by syncID → applied as NEW →
        //    DUPLICATE on the recipient), and
        //  • the pair-handshake match (empty `friends` → applyPairHandshake's
        //    candidate set misses the phantom → the friend never COLOURS on a
        //    fresh link-open, only later via self-heal).
        // The manual link-import already gates on this (MainTabView's
        // `while !hasLoadedOnce`); the headless pull was missing it. Bounded
        // (~5s) so a never-loading store can't hang.
        var loadWaits = 0
        while (!transactionStore.hasLoadedOnce || !friendStore.hasLoadedOnce), loadWaits < 100 {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            loadWaits += 1
        }

        let myID = UserIDService.currentID()
        let deliveries = await SyncDeliveryService.fetchInbox(recipientID: myID)
        guard !deliveries.isEmpty else { return }
        // Telemetry only — never affects what we apply.
        analytics.track(.syncDeliveryReceived(countBucket: AnalyticsBuckets.count(deliveries.count)))

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
                    analytics.track(.syncDeliveryApplied(op: .pair, wasUpdate: false))
                }
                continue
            }
            if delivery.op == "delete" {
                // Read-only peek for telemetry; the delete logic below is unchanged.
                let existedLocally = transactionStore.transactions.contains { $0.syncID == delivery.tx_sync_id }
                if let existing = transactionStore.transactions.first(where: { $0.syncID == delivery.tx_sync_id }) {
                    // Apply the tombstone LOCALLY only — do NOT re-broadcast a
                    // delete. The sender already addressed every participant;
                    // re-uploading a tombstone here echoes it back to the sender
                    // and turns a single delete into a both-devices wipe.
                    transactionStore.delete(id: existing.id, propagateToFriends: false)
                }
                acks.append((delivery.tx_sync_id, delivery.version))
                analytics.track(.syncDeliveryApplied(op: .delete, wasUpdate: existedLocally))
                continue
            }

            // Decrypt. Prefer the envelope sender id (cleartext, new in the
            // 0009 migration): it lets us derive the pairwise key for a sender
            // we still hold only as an un-upgraded phantom — the basis for the
            // self-heal below. Fall back to trying each connected friend's key
            // (legacy deliveries / senders that predate the sender_id field).
            var payload: SharedTransactionPayload?
            var decryptedPeerID: String?
            if let senderID = delivery.sender_id, !senderID.isEmpty,
               let decoded = SyncDeliveryCrypto.tryDecrypt(
                   base64: delivery.payload, myID: myID, candidatePeerID: senderID
               ) {
                payload = decoded
                decryptedPeerID = senderID
            } else {
                for friend in pairedFriends {
                    if let decoded = SyncDeliveryCrypto.tryDecrypt(
                        base64: delivery.payload, myID: myID, candidatePeerID: friend.id
                    ) {
                        payload = decoded
                        decryptedPeerID = friend.id
                        break
                    }
                }
            }
            // Couldn't decrypt with the sender id or any paired friend's key —
            // likely the sender was removed locally. Leave it un-acked; it TTLs
            // out server-side. (Don't ack what we didn't apply.)
            guard let payload else {
                analytics.track(.syncDeliveryFailed(reason: .decryptFailed))
                continue
            }

            let existing = transactionStore.transactions.first { $0.syncID == delivery.tx_sync_id }

            // SELF-HEALING PAIRING: decrypting via the envelope sender id proves
            // the sender's real user id. If we still hold them as an un-upgraded
            // phantom on this split, connect them NOW (before the version guard,
            // so even an idempotent re-pull heals) — so our uploads start
            // reaching them and future deliveries match/decrypt by real id. This
            // makes pairing converge from ordinary traffic instead of depending
            // on the single fire-and-forget reciprocal pair handshake landing.
            if let peerID = decryptedPeerID {
                await selfHealPairing(
                    senderRealID: peerID, senderName: payload.sn, localTx: existing,
                    friendStore: friendStore, transactionStore: transactionStore
                )
            }

            // Sync context: WE are the recipient (this inbox is ours), so we
            // resolve our own participant index directly rather than via the
            // picker-oriented `ShareIntentClassifier`. We match ourselves by
            // real id, or — in an unambiguous split — as the single non-sharer
            // participant. Update-vs-create is decided by whether we already
            // hold this syncID, so an edit UPDATES instead of duplicating.

            // Idempotent re-pull / stale-edit guard: we already hold this
            // version (or newer — e.g. we edited locally) → just ack so the
            // server stops re-delivering. delivery.version == payload.ev.
            if let existing, delivery.version <= existing.editVersion {
                acks.append((delivery.tx_sync_id, delivery.version))
                analytics.track(.syncDeliveryFailed(reason: .versionStale))
                continue
            }

            let myIndex = payload.f.firstIndex(where: { $0.id == myID })
            // Phantom candidates (`cn != true`): the only participants we
            // could legitimately be once an id-match fails — connected
            // friends were addressed by their REAL userID, so if we were one
            // we'd have id-matched above. Same invariant the picker-side
            // `ShareIntentClassifier` uses. For legacy payloads (`cn == nil`)
            // every participant is a candidate, so this degrades to the
            // historical "single non-sharer" behavior (payload.f excludes the
            // sharer by construction).
            let phantomIndices = payload.f.indices.filter { payload.f[$0].cn != true }
            // Resolve "us": real-id match → the single phantom candidate → and,
            // as a final fallback, the sole non-sharer participant. `payload.f`
            // excludes the sharer, so a 2-person split has exactly one entry;
            // this last fallback restores the pre-`cn` behavior that a 2-person
            // headless apply must ALWAYS work even after we've marked the peer
            // connected — at which point its payloads carry `cn == true` (so
            // `phantomIndices` empties) while we may still address it by a
            // phantom id (so `myIndex` is nil). Without it a legitimate 2-person
            // upsert is silently skipped (the cn-guard regression).
            let resolvedIndex = myIndex
                ?? (phantomIndices.count == 1 ? phantomIndices.first : nil)
                ?? (payload.f.count == 1 ? payload.f.indices.first : nil)
            guard let index = resolvedIndex else {
                // Genuinely ambiguous (3+ participants, no id-match, multiple
                // phantom candidates) — can't pick "us" headlessly. Leave
                // un-acked for the manual link flow (which has the picker);
                // it TTLs out server-side.
                continue
            }

            if await applyHeadless(payload: payload, index: index,
                                   existingID: existing?.id, isUpdate: existing != nil,
                                   transactionStore: transactionStore, friendStore: friendStore,
                                   categoryStore: categoryStore, receiptItemStore: receiptItemStore) {
                acks.append((delivery.tx_sync_id, delivery.version))
                analytics.track(.syncDeliveryApplied(op: .upsert, wasUpdate: existing != nil))
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
        // Candidate phantom ids to try as the handshake key: our friends' ids
        // PLUS every split-participant id across transactions. The recipient
        // encrypted with the id WE assigned them (payload.f[index].id =
        // FriendShare.friendID). That's normally also a Friend record, but a
        // participant added ad-hoc to a split might live only on the
        // transaction — include those ids too so the match never misses.
        var candidateIDs: [String] = friendStore.friends.map(\.id)
        var seen = Set(candidateIDs)
        for tx in transactionStore.transactions {
            for share in tx.splitInfo?.friends ?? [] where !seen.contains(share.friendID) {
                seen.insert(share.friendID)
                candidateIDs.append(share.friendID)
            }
        }
        for candidateID in candidateIDs {
            guard let handshake = SyncDeliveryCrypto.tryDecryptHandshake(
                base64: delivery.payload, keyA: myID, keyB: candidateID
            ) else { continue }
            // Matched: `candidateID` is the phantom; `handshake.rid` is real.
            // Was this person ALREADY a connected friend? Then they just
            // re-opened our link while still paired (e.g. tapped it by
            // accident) — nothing actually changes, so we ack the no-op
            // handshake but must NOT fire the "you're now synced" toast. A
            // genuine re-pair after a delete leaves them un-connected here, so
            // it still notifies.
            let alreadyConnected = friendStore.friend(byID: handshake.rid)?.isConnected == true
            if candidateID == handshake.rid {
                friendStore.markConnected(id: candidateID)
            } else if friendStore.friend(byID: candidateID) != nil {
                await friendStore.upgradePhantom(phantomID: candidateID, realID: handshake.rid)
                await transactionStore.upgradePhantomFriendID(from: candidateID, to: handshake.rid)
            } else {
                // Phantom existed only as a split participant, not a Friend
                // record — create the connected friend under the REAL id, then
                // rewrite the transactions' participant id to it.
                let trimmed = handshake.n?.trimmingCharacters(in: .whitespacesAndNewlines)
                let name = (trimmed?.isEmpty == false) ? trimmed! : "Friend"
                await friendStore.add(Friend(id: handshake.rid, name: name, isConnected: true))
                await transactionStore.upgradePhantomFriendID(from: candidateID, to: handshake.rid)
            }
            if !alreadyConnected {
                // Genuine (re)connection — surface the sharer-side "you're now
                // synced" toast. Name priority: the name WE gave this friend in
                // our own list (preserved by `upgradePhantom`) → the name they
                // set for themselves (carried in the handshake) → "Friend".
                let pairedName = (friendStore.friend(byID: handshake.rid)?.name)
                        .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                    ?? (handshake.n?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                    ?? "Friend"
                await MainActor.run { self.onPaired?(pairedName) }
                analytics.track(.pairingEstablished(via: .handshake))
            }
            return true
        }
        // No matching candidate (the friend/participant isn't on this device
        // yet) — leave it un-acked so a later pull retries once it exists.
        return false
    }

    /// Self-healing pairing. Decrypting a delivery via its cleartext envelope
    /// sender id proves `senderRealID` is the sender's real user id. If we still
    /// hold that sender as an un-upgraded phantom on this split, connect them:
    /// upgrade the phantom Friend to the real id + mark connected, and migrate
    /// the transaction's participant id — so OUR uploads reach them and future
    /// deliveries match/decrypt by real id. Only acts in the UNAMBIGUOUS case
    /// (exactly one un-connected participant on our local copy — the common
    /// 2-person split); multi-phantom splits wait for the explicit pair
    /// handshake to avoid mapping the sender to the wrong phantom.
    private func selfHealPairing(
        senderRealID: String,
        senderName: String?,
        localTx: Transaction?,
        friendStore: FriendStore,
        transactionStore: TransactionStore
    ) async {
        let myID = UserIDService.currentID()
        guard !senderRealID.isEmpty, senderRealID != myID else { return }
        // Already connected under their real id → nothing to heal.
        if friendStore.friends.first(where: { $0.id == senderRealID })?.isConnected == true { return }
        guard let tx = localTx, let participants = tx.splitInfo?.friends else { return }

        // SAFETY: only self-heal a GENUINELY 2-person split — exactly one
        // non-owner participant, which therefore MUST be the sender. In a
        // 3+-person split the envelope sender id alone can't tell us which
        // participant is the sender, and mis-mapping would rewrite the WRONG
        // participant's id (silently corrupting the split + debt math). Those
        // defer to the explicit pair handshake, which carries the exact phantom
        // id. (`splitInfo.friends` is the non-owner side: our own copy of a
        // 2-person split holds exactly the one peer.)
        guard participants.count == 1 else { return }
        let phantomID = participants[0].friendID

        // REAL-but-disconnected reconnect — the case the phantom-upgrade guard
        // below structurally CAN'T handle. Here the lone participant id already
        // IS the sender's real id (so there's no phantom to upgrade), and we
        // hold them as a DISCONNECTED real friend. This is exactly the stuck
        // state after a remove + re-add where the one-shot op=pair handshake
        // never landed: without this, NO ordinary traffic ever re-colors them
        // (selfHeal only upgraded phantoms; the guard below returns), so the
        // user is stranded on the share sheet forever. Reconnect from the
        // friend's ordinary upsert instead of depending on the fragile
        // handshake. SAFE against resurrecting a deliberately-removed friend:
        // this fires only on an op=upsert delivery, which the server delivers
        // ONLY over an ACTIVE pairing (removal revokes it), and it flips an
        // EXISTING record — it never re-creates a deleted one.
        if phantomID == senderRealID,
           let existing = friendStore.friend(byID: senderRealID), !existing.isConnected {
            friendStore.markConnected(id: senderRealID)
            let pairedName = (existing.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : existing.name)
                ?? (senderName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? "Friend"
            await MainActor.run { self.onPaired?(pairedName) }
            analytics.track(.pairingEstablished(via: .selfHeal))
            return
        }

        // The lone participant is already the sender's real id (or us) → no
        // phantom to upgrade. Also require it be un-connected to act.
        guard phantomID != senderRealID, phantomID != myID,
              friendStore.friends.first(where: { $0.id == phantomID })?.isConnected != true
        else { return }

        // Connect the sender. Upgrade the phantom Friend if it exists; else
        // connect an already-present real-id record, or add a fresh one —
        // never a bare insert that could collide on the primary key.
        if friendStore.friend(byID: phantomID) != nil {
            await friendStore.upgradePhantom(phantomID: phantomID, realID: senderRealID)
        } else if friendStore.friend(byID: senderRealID) != nil {
            friendStore.markConnected(id: senderRealID)
        } else {
            let trimmed = senderName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (trimmed?.isEmpty == false) ? trimmed! : "Friend"
            await friendStore.add(Friend(id: senderRealID, name: name, isConnected: true))
        }
        await transactionStore.upgradePhantomFriendID(from: phantomID, to: senderRealID)
        // Reaching here means we DID newly connect (the early-returns above
        // cover the already-connected / no-op cases) — surface the sharer-side
        // "you're now synced" toast. Prefer the sender's name, else fallback.
        // Same priority as applyPairHandshake: our name for them → their
        // self-name → "Friend".
        let pairedName = (friendStore.friend(byID: senderRealID)?.name)
                .flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
            ?? (senderName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? "Friend"
        await MainActor.run { self.onPaired?(pairedName) }
        analytics.track(.pairingEstablished(via: .selfHeal))
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

        // Did the SHARER change content on this update? The recipient persists
        // `payloadChecksum` alongside the tx, so a mismatch vs the incoming
        // payload's checksum means the items the recipient already holds belong
        // to a STALE (previous) payload. First-time imports (no existingTx) and
        // unchanged re-shares (equal checksums) are NOT content changes.
        let payloadChecksumChanged = existingTx != nil
            && existingTx?.payloadChecksum != payload.checksum

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

        // STALE-ITEMS guard: on a CHANGED-checksum byItems update where THIS
        // payload's items didn't arrive (fetch 404'd / raced / failed to
        // decrypt), the recipient still holds the OLD checksum's items. Applying
        // now would keep stale items on screen or silently degrade to byAmount.
        // Bail WITHOUT acking: the delivery stays in the inbox and the next
        // natural pull retries once the sharer's items propagate (no busy-loop —
        // bounded by the pull cadence + the server-side delivery TTL).
        if payload.sm == SplitMode.byItems.rawValue,
           payloadChecksumChanged, !itemsCameFromShare {
            return false
        }

        do {
            // Decouple "has old local items" from "items for THIS payload are
            // usable": for a CHANGED-checksum update the local items are stale
            // and must NOT prop up the items-aware splitMode decision — only
            // freshly-fetched items do. (We already returned above when a
            // changed update brought no items, so reaching here on a changed
            // update implies itemsCameFromShare == true.) First imports and
            // unchanged re-shares keep trusting local items as before.
            let localItemsUsable = receiverHasLocalItems && !payloadChecksumChanged
            let resolved = try ReceivedTransactionMapper.map(
                payload: payload,
                receiverParticipantIndex: index,
                existingFriends: friendStore.friends,
                existingCategories: categoryStore.categories,
                nextTransactionID: existingID ?? 0,
                existingTransaction: existingTx,
                receiverHasLocalItemsForTx: localItemsUsable,
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
            analytics.track(.syncDeliveryFailed(reason: .applyError))
            return false
        }
    }
}

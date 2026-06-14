import Foundation
import Combine

// MARK: - Share Link Coordinator

/// App-level state machine for incoming share-transaction links. Sits in
/// the SwiftUI environment (`@EnvironmentObject`) so views can observe
/// `routingState` and present the right surface — but the coordinator
/// itself is the only thing allowed to drive transitions.
///
/// ## Why a state machine
/// The user flow has multiple branches (auto-create / picker /
/// update-confirm / identical-no-op / error) and several of them are
/// *modal* (block the next action until resolved). Modeling them as
/// distinct enum states means SwiftUI sheets/alerts bind cleanly to a
/// single `routingState` value and never get into a "two sheets at
/// once" tangle.
///
/// ## Stores aren't injected
/// The coordinator is created at app launch, before stores are ready,
/// so the action methods take `TransactionStore` / `FriendStore` /
/// `CategoryStore` as parameters. Views supply them from the
/// environment when calling.
@MainActor
final class ShareLinkCoordinator: ObservableObject {

    // MARK: - State

    /// What surface should be on screen right now. Single source of
    /// truth — UI binds sheets/alerts to specific cases.
    ///
    /// Conforms to `Equatable` via a hand-rolled `==` that compares
    /// case identity + payload IDs but treats `SharedTransactionError`
    /// (which doesn't itself conform) as "always different from any
    /// other errored state". That's fine for `.onChange(of:)` — every
    /// new error fires the change observer, which is what we want.
    enum RoutingState {
        /// Nothing in progress. Default state.
        case idle
        /// Receiver needs (or doesn't need) the picker. The
        /// `autoPickIndex` carries the inferred participant index when
        /// the classifier identified the receiver by ID — the UI layer
        /// then skips rendering the picker and commits directly. When
        /// `nil`, the picker is shown for real (multi-participant case
        /// without ID match).
        case showingPicker(
            payload: SharedTransactionPayload,
            isForUpdate: Bool,
            existingID: Int?,
            autoPickIndex: Int?
        )
        /// Same `syncID` already on device but the sharer changed the
        /// content. UI shows confirmation alert. `knownParticipantIndex`
        /// is set when the receiver was identified by ID — on accept,
        /// the coordinator commits directly without re-asking the
        /// picker. When nil, multi-participant updates fall through to
        /// the picker.
        case showingUpdateAlert(
            payload: SharedTransactionPayload,
            existingID: Int,
            knownParticipantIndex: Int?
        )
        /// Same `syncID` AND identical content — receiver already has
        /// this exact transaction. UI navigates to it (or shows toast).
        /// Carries `syncID` rather than the SQLite autoincrement id so
        /// the lookup stays valid across Replace-reminder flows that
        /// rotate the id, and against the staleness window between a
        /// DB write and the next `load()` cycle.
        case identical(syncID: String)
        /// Action complete. UI navigates to the resulting transaction
        /// and resets state. Carries `syncID` (see `.identical` above).
        case completed(syncID: String, kind: CompletionKind)
        /// Decode failed. UI shows error alert.
        case errored(SharedTransactionError)
    }

    enum CompletionKind: Equatable {
        case createdNew
        case updated
    }

    @Published var routingState: RoutingState = .idle

    /// Diagnostic — last URL we tried to process. Useful for #if DEBUG
    /// console output.
    private(set) var lastReceivedURL: URL?

    /// Receipt items pulled from the server-side items store for the
    /// current share. Populated by `pickedParticipant` once it awaits
    /// `itemsFetchTask`; consumed downstream by
    /// `persistFetchedReceiptItemsIfAny` to write the items into
    /// `ReceiptItemStore` alongside the imported transaction. `nil`
    /// means the server has no items for this share (older sender,
    /// outage, expired snapshot) — receiver falls back to `.byAmount`.
    @Published private(set) var fetchedReceiptItems: [ReceiptItem]?

    /// Handle for the in-flight fetch-and-decrypt task spawned by
    /// `fetchEncryptedItems`. `pickedParticipant` awaits this BEFORE
    /// computing `payloadCameWithItems` so the mapper sees the real
    /// answer rather than a racy snapshot. Earlier the fetch was
    /// fire-and-forget — items typically arrived in time, but a fast
    /// auto-pick (single-participant share, identity match) or a slow
    /// network could land `pickedParticipant` BEFORE the Task wrote
    /// back, dropping items on the floor and degrading the import to
    /// `.byAmount` even when the server had items ready to serve.
    private var itemsFetchTask: Task<[ReceiptItem]?, Never>?

    /// Resolved on first access from the DI container. Lazy so the
    /// coordinator (constructed in `non_bankApp.init`) doesn't need
    /// analytics in its own init signature — DI registration
    /// completes before any share link could possibly arrive.
    private lazy var analytics: AnalyticsServiceProtocol =
        DIContainer.shared.resolve(AnalyticsServiceProtocol.self)

    // MARK: - Init

    init() {}

    // MARK: - Entry from `onOpenURL`

    /// Decodes an incoming URL and either drives the state machine or
    /// records an error. Returns `true` if the URL was a share link
    /// (regardless of decode success), so callers can distinguish from
    /// other deep links the app may grow into.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard SharedTransactionLink.isShareURL(url) else { return false }
        lastReceivedURL = url
        // Fresh share → drop any items cached from a previous link so
        // we don't accidentally re-apply old items to a new transaction.
        // Cancel any still-in-flight fetch from a prior URL so we don't
        // race two responses into `fetchedReceiptItems`.
        itemsFetchTask?.cancel()
        itemsFetchTask = nil
        fetchedReceiptItems = nil
        do {
            let payload = try SharedTransactionLink.decode(url: url)
            #if DEBUG
            print("[ShareLink] decoded payload \(payload.id) from \(url.scheme ?? "?")")
            #endif
            // We don't have store access here — the actual classify step
            // happens once the UI tells us "stores are ready, here are
            // the existing transactions" via `startRouting(...)`.
            // Until then we sit on the payload by stashing it in the
            // showingUpdateAlert/showingPicker state via `startRouting`.
            // For now: kick the View to call `startRouting` with the
            // current TransactionStore snapshot.
            pendingPayload = payload
            // Kick the server-items fetch in parallel with the View's
            // classify + pick flow. `pickedParticipant` AWAITS the
            // resulting task before reading items, so even a fast
            // auto-pick or a slow network can't slip past — items
            // either arrive (and the mapper sees them) or the task
            // returns nil (server has none / decrypt failed), in which
            // case we fall back to the historical byAmount path.
            fetchEncryptedItems(forURL: url, payload: payload)
        } catch let error as SharedTransactionError {
            #if DEBUG
            print("[ShareLink] decode failed: \(error.localizedDescription)")
            #endif
            routingState = .errored(error)
        } catch {
            routingState = .errored(.malformedPayload(underlying: error))
        }
        return true
    }

    /// Pull encrypted items from the Worker's `/v1/share-items/
    /// {checksum}` store and decrypt with a key derived from the
    /// URL's payload. Stored on `itemsFetchTask` so `pickedParticipant`
    /// can await the result before deciding whether to import as
    /// byItems or fall back to byAmount. Any failure (no server row,
    /// decrypt error, decode error) resolves to `nil` — the caller
    /// treats `nil` as "no items available" and runs the historical
    /// fallback path.
    private func fetchEncryptedItems(forURL url: URL, payload: SharedTransactionPayload) {
        guard let urlPayload = SharedTransactionLink.urlPayloadString(of: url) else {
            itemsFetchTask = nil
            return
        }
        let shareID = payload.checksum
        itemsFetchTask = Task {
            do {
                guard let ciphertext = try await ShareItemsService.shared.fetch(shareID: shareID) else {
                    #if DEBUG
                    print("[ShareItems] server has no items for share \(shareID.prefix(8)) — using byAmount fallback")
                    #endif
                    return nil
                }
                return try ShareItemsCrypto.decryptItems(base64: ciphertext, urlPayload: urlPayload)
            } catch {
                #if DEBUG
                print("[ShareItems] fetch/decrypt failed: \(error.localizedDescription)")
                #endif
                return nil
            }
        }
    }

    /// Decoded but not-yet-classified payload. The view layer reads this
    /// once stores are ready and calls `startRouting(_:in:)`. Cleared
    /// once routing transitions out of `.idle`.
    @Published var pendingPayload: SharedTransactionPayload?

    // MARK: - Classification

    /// Runs the classifier against the receiver's current transaction
    /// list and transitions the state machine. Called by the View layer
    /// when `pendingPayload` flips non-nil and stores are loaded.
    func startRouting(_ payload: SharedTransactionPayload, in existingTransactions: [Transaction]) {
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: UserIDService.currentID(),
            existingTransactions: existingTransactions,
            checksumOf: { $0.payloadChecksum }
        )
        // Analytics: `share_link_opened` with the classifier's
        // verdict so we can see receive-side breakdown (auto-create
        // = identity matched, picker = ambiguous, update = re-share,
        // identical = no-op, malformed = bad payload).
        let outcome: ShareLinkOpenOutcome = {
            switch intent {
            case .createAuto:    return .autoCreate
            case .createWithPicker: return .pickerShown
            case .identical:     return .identical
            case .updatePrompt:  return .updatePrompt
            case .malformed:     return .malformed
            }
        }()
        analytics.track(.shareLinkOpened(outcome: outcome))
        switch intent {
        case .createAuto(let idx):
            // Receiver is unambiguous (single-participant or matched by
            // ID). Transition to `.showingPicker` with `autoPickIndex`
            // set — the View layer detects this and commits directly,
            // never rendering the picker UI.
            routingState = .showingPicker(
                payload: payload,
                isForUpdate: false,
                existingID: nil,
                autoPickIndex: idx
            )
        case .createWithPicker:
            routingState = .showingPicker(
                payload: payload,
                isForUpdate: false,
                existingID: nil,
                autoPickIndex: nil
            )
        case .identical(let id):
            // Translate the classifier's int id to syncID — the rest
            // of the state machine (and the View layer) keys off the
            // stable identifier so we don't have to refresh the int
            // id at every consumer when the row's autoincrement key
            // rotates (Replace-reminder flow).
            let syncID = existingTransactions.first(where: { $0.id == id })?.syncID ?? ""
            routingState = .identical(syncID: syncID)
        case .updatePrompt(let id, let knownIdx):
            routingState = .showingUpdateAlert(
                payload: payload,
                existingID: id,
                knownParticipantIndex: knownIdx
            )
        case .malformed:
            routingState = .errored(.malformedPayload(underlying: NSError(
                domain: "ShareLink", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Empty participant list"]
            )))
        }
        pendingPayload = nil
    }

    // MARK: - Actions from UI

    /// Called by the picker view (or by auto-create when `f.count == 1`).
    /// Builds the `ResolvedShare` and writes it to the stores. Transitions
    /// to `.completed` on success or `.errored` on mapper failure.
    ///
    /// `receiptItemStore` is read on the update path so the mapper can
    /// decide whether to keep the receiver's `.byItems` mode (items
    /// locally → keep) or accept the payload's mode verbatim (no items
    /// locally → no anchor for `.byItems`, take what's on the wire).
    func pickedParticipant(
        index: Int,
        payload: SharedTransactionPayload,
        existingID: Int?,
        isUpdate: Bool,
        transactionStore: TransactionStore,
        friendStore: FriendStore,
        categoryStore: CategoryStore,
        receiptItemStore: ReceiptItemStore
    ) async {
        // Phantom-upgrade pass: only meaningful for the update path,
        // where the receiver already has a local copy of the
        // transaction. If their old copy referenced a phantom Friend
        // (manually-typed contact with a random ID) and the new
        // sharer is the same person, we rewrite the phantom's ID to
        // the real userID + flag the Friend as `isConnected`. This
        // happens BEFORE `mapper.map` so the mapper finds the
        // already-upgraded Friend instead of creating a new one.
        if isUpdate, let txID = existingID,
           let existing = transactionStore.transactions.first(where: { $0.id == txID }),
           let split = existing.splitInfo {
            if let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
                oldFriendIDsInTransaction: Set(split.friends.map(\.friendID)),
                newPayloadParticipantIDs: payload.f.map(\.id),
                receiverID: UserIDService.currentID(),
                sharerID: payload.s
            ) {
                #if DEBUG
                print("[ShareLink] phantom upgrade: \(upgrade.phantomID) → \(upgrade.realID)")
                #endif
                await friendStore.upgradePhantom(
                    phantomID: upgrade.phantomID,
                    realID: upgrade.realID
                )
                await transactionStore.upgradePhantomFriendID(
                    from: upgrade.phantomID,
                    to: upgrade.realID
                )
            }
        }
        // For updates, hand the mapper the receiver's existing record
        // so it can preserve the user's title + category instead of
        // overwriting from the payload (per spec: re-imports must NOT
        // clobber the receiver's local taxonomy / naming).
        let existingTx: Transaction? = isUpdate
            ? transactionStore.transactions.first(where: { $0.id == existingID })
            : nil

        // Items-aware splitMode: the mapper needs to know whether the
        // receiver has scanned items for this transaction locally.
        // Pre-check `id` rather than re-deriving inside the mapper so
        // the mapper stays pure (no `ReceiptItemStore` dependency).
        let receiverHasLocalItems: Bool = {
            guard let txID = existingTx?.id else { return false }
            return !receiptItemStore.items(forTransactionID: txID).isEmpty
        }()

        // The share-items channel may have delivered the sender's
        // item list + per-item assignments. Await the fetch task
        // started in `handle(url:)` BEFORE deciding — without the
        // await, a fast auto-pick (single-participant share, identity
        // match) or a slow network would slip past the in-flight task
        // and the mapper would see `payloadCameWithItems = false`
        // even when the server had items ready. A `nil` result here
        // is the genuine fallback: server has no items / decrypt
        // failed / payload couldn't derive a key.
        let fetchedItems = await itemsFetchTask?.value ?? nil
        // Mirror onto the published property so
        // `persistFetchedReceiptItemsIfAny` (which reads
        // `fetchedReceiptItems`) writes the same list the mapper
        // resolved against. Single source of truth for the rest of
        // this flow.
        fetchedReceiptItems = fetchedItems
        let itemsCameFromShare = !(fetchedItems?.isEmpty ?? true)

        do {
            let resolved = try ReceivedTransactionMapper.map(
                payload: payload,
                receiverParticipantIndex: index,
                existingFriends: friendStore.friends,
                existingCategories: categoryStore.categories,
                // For new creates SQLite assigns the autoincrement id —
                // any value here gets overwritten. For updates we feed
                // the existing id so `update(_:)` targets the right row.
                nextTransactionID: existingID ?? 0,
                existingTransaction: existingTx,
                receiverHasLocalItemsForTx: receiverHasLocalItems,
                payloadCameWithItems: itemsCameFromShare
            )
            // Side-effects in dependency order: friends and category
            // must exist before the transaction references them.
            for friend in resolved.newFriends {
                await friendStore.add(friend)
            }
            if let cat = resolved.newCategory {
                categoryStore.addCategory(cat)
            }

            if isUpdate, let txID = existingID {
                // Update path keeps the same SQLite primary key but
                // replaces every other field — including the freshly
                // computed `payloadChecksum`, which the classifier will
                // read back next time. `updateAndWait` blocks on the DB
                // write + `load()` so the View's lookup-by-syncID after
                // we transition to `.completed` reads the FRESH row,
                // not the pre-update copy that was sitting in
                // `transactions` while the async write was in flight.
                await transactionStore.updateAndWait(resolved.transaction)
                await persistFetchedReceiptItemsIfAny(
                    forTransactionID: txID,
                    payload: payload,
                    receiverParticipantIndex: index,
                    store: receiptItemStore
                )
                analytics.track(.shareLinkImported(
                    hadPicker: false,
                    numParticipantsBucket: AnalyticsBuckets.friendCount(payload.f.count),
                    isUpdate: true
                ))
                recordPairingBestEffort(sharerID: payload.s)
                routingState = .completed(syncID: resolved.transaction.syncID, kind: .updated)
            } else {
                // `addAndReturnID` already awaits the load; we use
                // its return value as both the success signal AND the
                // new SQLite primary key so we can attach any fetched
                // share-items to the freshly-inserted row.
                if let insertedID = await transactionStore.addAndReturnID(resolved.transaction) {
                    await persistFetchedReceiptItemsIfAny(
                        forTransactionID: insertedID,
                        payload: payload,
                        receiverParticipantIndex: index,
                        store: receiptItemStore
                    )
                    // `hadPicker` distinguishes "system auto-picked
                    // identity for us" from "user manually chose
                    // themselves from the participant list" — the
                    // first case is the friction-free happy path,
                    // the second exposes the friend-graph match-rate.
                    analytics.track(.shareLinkImported(
                        hadPicker: !payload.f.isEmpty && payload.f.count > 1,
                        numParticipantsBucket: AnalyticsBuckets.friendCount(payload.f.count),
                        isUpdate: false
                    ))
                    recordPairingBestEffort(sharerID: payload.s)
                    routingState = .completed(syncID: resolved.transaction.syncID, kind: .createdNew)
                } else {
                    // `addAndReturnID` looks up by syncID after the load
                    // — falling here means the insert silently failed.
                    routingState = .errored(.malformedPayload(underlying: NSError(
                        domain: "ShareLink", code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "Couldn't insert imported transaction"]
                    )))
                }
            }
        } catch let error as SharedTransactionError {
            routingState = .errored(error)
        } catch {
            routingState = .errored(.malformedPayload(underlying: error))
        }
    }

    /// User accepted the "Friend wants to update this" alert. Three
    /// branches:
    ///   1. `knownParticipantIndex` set (receiver matched by ID) →
    ///      commit directly, no picker.
    ///   2. Otherwise, single-participant split → commit with index 0.
    ///   3. Otherwise, multi-participant unmatched → re-show picker.
    func confirmedUpdate(
        payload: SharedTransactionPayload,
        existingID: Int,
        knownParticipantIndex: Int?,
        transactionStore: TransactionStore,
        friendStore: FriendStore,
        categoryStore: CategoryStore,
        receiptItemStore: ReceiptItemStore
    ) async {
        if let idx = knownParticipantIndex {
            await pickedParticipant(
                index: idx,
                payload: payload,
                existingID: existingID,
                isUpdate: true,
                transactionStore: transactionStore,
                friendStore: friendStore,
                categoryStore: categoryStore,
                receiptItemStore: receiptItemStore
            )
        } else if payload.f.count == 1 {
            await pickedParticipant(
                index: 0,
                payload: payload,
                existingID: existingID,
                isUpdate: true,
                transactionStore: transactionStore,
                friendStore: friendStore,
                categoryStore: categoryStore,
                receiptItemStore: receiptItemStore
            )
        } else {
            routingState = .showingPicker(
                payload: payload,
                isForUpdate: true,
                existingID: existingID,
                autoPickIndex: nil
            )
        }
    }

    /// Reset back to idle. Called when:
    ///  - User declines an update prompt.
    ///  - User cancels the picker.
    ///  - UI dismisses an error.
    ///  - Caller has finished navigating to a `.completed` / `.identical`
    ///    transaction and wants the state cleared.
    func reset() {
        routingState = .idle
        pendingPayload = nil
        fetchedReceiptItems = nil
    }

    /// Server sync, Phase 0: tell the Worker that the local user and the
    /// sharer are now paired, so a later phase can route sync updates
    /// between them. Fired only once a real-user inbound import has
    /// actually succeeded (both create and update paths) and the sharer
    /// id is known.
    ///
    /// Strictly additive and best-effort: dispatched on a *detached* Task
    /// so it never blocks, delays, or alters the import flow, and
    /// `SyncPairing.recordPairing` swallows every failure (network,
    /// attest, non-2xx). The detached task also reads
    /// `UserIDService.currentID()` off the main actor.
    ///
    /// Guard: `recordPairing` no-ops when the sharer id is empty or equals
    /// our own id (you can't pair with yourself). We don't add a separate
    /// local "paired" flag — `Friend.isConnected`, which the mapper and
    /// phantom-upgrade path already set to `true` for share-link friends,
    /// is the existing local signal that these two users are connected.
    private func recordPairingBestEffort(sharerID: String) {
        guard !sharerID.isEmpty else { return }
        Task.detached(priority: .utility) {
            let myID = UserIDService.currentID()
            await SyncPairing.recordPairing(myID: myID, sharerID: sharerID)
        }
    }

    /// Persist any items decrypted from the server-side store under the
    /// freshly-inserted (or just-updated) transaction's id. Rewrites
    /// `assignedParticipantIDs` from the sender's local-identity space
    /// (where `__me__` meant the sender) into the receiver's space
    /// (where `__me__` means the receiver) — see the doc on
    /// `ReceivedTransactionMapper.rewriteItemAssignees` for the swap
    /// rule. No-op when the fetch returned nil; the import flow stays
    /// on the historical byAmount path that pre-dated the items
    /// channel. Clears the cache after persistence so a subsequent
    /// share doesn't re-apply the same set.
    private func persistFetchedReceiptItemsIfAny(
        forTransactionID transactionID: Int,
        payload: SharedTransactionPayload,
        receiverParticipantIndex: Int,
        store: ReceiptItemStore
    ) async {
        guard let items = fetchedReceiptItems, !items.isEmpty else { return }
        let rewritten = ReceivedTransactionMapper.rewriteItemAssignees(
            items: items,
            payload: payload,
            receiverParticipantIndex: receiverParticipantIndex
        )
        await store.saveItems(rewritten, for: transactionID)
        fetchedReceiptItems = nil
    }
}

// MARK: - Equatable for RoutingState

extension ShareLinkCoordinator.RoutingState: Equatable {
    static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle):
            return true
        case let (.showingPicker(lp, lu, le, la), .showingPicker(rp, ru, re, ra)):
            return lp == rp && lu == ru && le == re && la == ra
        case let (.showingUpdateAlert(lp, le, lk), .showingUpdateAlert(rp, re, rk)):
            return lp == rp && le == re && lk == rk
        case let (.identical(l), .identical(r)):
            return l == r
        case let (.completed(ls, lk), .completed(rs, rk)):
            return ls == rs && lk == rk
        case (.errored, .errored):
            // SharedTransactionError doesn't conform to Equatable and
            // synthesising it would mean opening up `LocalizedError`
            // semantics across cases. We treat consecutive `.errored`
            // states as distinct so `.onChange(of:)` always fires —
            // good for showing fresh alert content even when the
            // wrapping case is the same.
            return false
        default:
            return false
        }
    }
}

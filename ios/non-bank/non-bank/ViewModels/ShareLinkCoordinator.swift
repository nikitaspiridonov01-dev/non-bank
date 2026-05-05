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
        case identical(existingID: Int)
        /// Action complete. UI navigates to the resulting transaction
        /// and resets state.
        case completed(transactionID: Int, kind: CompletionKind)
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
            routingState = .identical(existingID: id)
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
    func pickedParticipant(
        index: Int,
        payload: SharedTransactionPayload,
        existingID: Int?,
        isUpdate: Bool,
        transactionStore: TransactionStore,
        friendStore: FriendStore,
        categoryStore: CategoryStore
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
                existingTransaction: existingTx
            )
            // Side-effects in dependency order: friends and category
            // must exist before the transaction references them.
            for friend in resolved.newFriends {
                await friendStore.add(friend)
            }
            if let cat = resolved.newCategory {
                categoryStore.addCategory(cat)
            }

            if isUpdate, let existingID {
                // Update path keeps the same SQLite primary key but
                // replaces every other field — including the freshly
                // computed `payloadChecksum`, which the classifier will
                // read back next time.
                transactionStore.update(resolved.transaction)
                routingState = .completed(transactionID: existingID, kind: .updated)
            } else {
                if let newID = await transactionStore.addAndReturnID(resolved.transaction) {
                    routingState = .completed(transactionID: newID, kind: .createdNew)
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
        categoryStore: CategoryStore
    ) async {
        if let idx = knownParticipantIndex {
            await pickedParticipant(
                index: idx,
                payload: payload,
                existingID: existingID,
                isUpdate: true,
                transactionStore: transactionStore,
                friendStore: friendStore,
                categoryStore: categoryStore
            )
        } else if payload.f.count == 1 {
            await pickedParticipant(
                index: 0,
                payload: payload,
                existingID: existingID,
                isUpdate: true,
                transactionStore: transactionStore,
                friendStore: friendStore,
                categoryStore: categoryStore
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
        case let (.completed(li, lk), .completed(ri, rk)):
            return li == ri && lk == rk
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

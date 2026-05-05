import XCTest
@testable import non_bank

final class ShareIntentClassifierTests: XCTestCase {

    // MARK: - Fixtures

    private func makePayload(
        syncID: String = "tx-001",
        participantCount: Int = 1,
        sharerID: String = "sharer-A1B2"
    ) -> SharedTransactionPayload {
        let participants = (0..<participantCount).map { i in
            SharedTransactionPayload.Participant(
                id: "friend-\(i)", n: "Friend \(i)", sh: 10, pa: 0
            )
        }
        return SharedTransactionPayload(
            v: 1, id: syncID, s: sharerID,
            ta: Double(20 * participantCount), pa: Double(20 * participantCount),
            ms: 10, c: "EUR", d: 1_700_000_000, k: "exp",
            t: "Test", cn: "Food", ce: "🍕", sm: nil, sn: nil,
            f: participants
        )
    }

    private func makeStoredTransaction(syncID: String, id: Int = 42) -> Transaction {
        Transaction(
            id: id, syncID: syncID,
            emoji: "🍕", category: "Food", title: "Stored",
            description: nil, amount: 10, currency: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            type: .expenses, tags: nil
        )
    }

    /// Receiver's own user ID — by default doesn't match any of the
    /// participants in `makePayload`, so we get the unknown-receiver
    /// path. Tests that exercise the ID-match shortcut override this.
    private let receiverID = "receiver-XYZ-9999"

    // MARK: - First-import paths

    func testClassify_singleParticipant_noPriorImport_isCreateAutoWithIndexZero() {
        let payload = makePayload(participantCount: 1)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [],
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .createAuto(participantIndex: 0))
    }

    func testClassify_multipleParticipants_noIDMatch_isCreateWithPicker() {
        let payload = makePayload(participantCount: 3)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [],
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .createWithPicker)
    }

    // MARK: - Receiver-by-ID auto-resolve (the new optimization)

    func testClassify_receiverIDInParticipants_skipsPicker() {
        // Receiver was previously known to the sharer (sharer imported
        // a share-link FROM this receiver and stored their real userID
        // as a Friend). Now sharer's payload's `f[0].id` matches our
        // own UserIDService.currentID() — we can pin them down without
        // asking.
        let myID = "blue-otter-A2BC"
        let participants: [SharedTransactionPayload.Participant] = [
            .init(id: "boris-9X1Y", n: "Boris", sh: 30, pa: 0),
            .init(id: myID, n: "Me", sh: 30, pa: 0),
            .init(id: "cara-3M4N", n: "Cara", sh: 30, pa: 0)
        ]
        let payload = SharedTransactionPayload(
            v: 1, id: "tx-new", s: "sharer-A1B2",
            ta: 90, pa: 90, ms: 30, c: "EUR",
            d: 1_700_000_000, k: "exp",
            t: "Test", cn: "Food", ce: "🍕", sm: nil, sn: nil,
            f: participants
        )
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: myID,
            existingTransactions: [],
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .createAuto(participantIndex: 1))
    }

    func testClassify_receiverIDNotInParticipants_fallsBackToPicker() {
        // Same shape as above but receiver's ID isn't among the
        // participants — must show the picker.
        let participants: [SharedTransactionPayload.Participant] = [
            .init(id: "boris-9X1Y", n: "Boris", sh: 30, pa: 0),
            .init(id: "alex-Q2W3", n: "Alex", sh: 30, pa: 0),
            .init(id: "cara-3M4N", n: "Cara", sh: 30, pa: 0)
        ]
        let payload = SharedTransactionPayload(
            v: 1, id: "tx-new", s: "sharer-A1B2",
            ta: 90, pa: 90, ms: 30, c: "EUR",
            d: 1_700_000_000, k: "exp",
            t: "Test", cn: "Food", ce: "🍕", sm: nil, sn: nil,
            f: participants
        )
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: "wholly-unrelated-Z9Z9",
            existingTransactions: [],
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .createWithPicker)
    }

    // MARK: - Re-import paths

    func testClassify_priorImportSameChecksum_isIdentical() {
        let payload = makePayload(syncID: "tx-001")
        let stored = makeStoredTransaction(syncID: "tx-001", id: 7)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [stored],
            checksumOf: { _ in payload.checksum }  // pretend stored matches
        )
        XCTAssertEqual(intent, .identical(existingID: 7))
    }

    func testClassify_priorImportDifferentChecksum_isUpdatePromptWithoutKnownIndex() {
        let payload = makePayload(syncID: "tx-001")
        let stored = makeStoredTransaction(syncID: "tx-001", id: 7)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [stored],
            checksumOf: { _ in "stale-checksum-from-old-version" }
        )
        XCTAssertEqual(intent, .updatePrompt(existingID: 7, knownParticipantIndex: nil))
    }

    func testClassify_updatePrompt_carriesKnownIndexWhenIDMatches() {
        // Update path also benefits from the ID match — once user
        // accepts the alert we can commit without re-asking the picker.
        let myID = "warm-bear-F1G2"
        let participants: [SharedTransactionPayload.Participant] = [
            .init(id: "alex-Q2W3", n: "Alex", sh: 30, pa: 0),
            .init(id: myID, n: "Me", sh: 30, pa: 0)
        ]
        let payload = SharedTransactionPayload(
            v: 1, id: "tx-edited", s: "sharer-A1B2",
            ta: 60, pa: 60, ms: 30, c: "EUR",
            d: 1_700_000_000, k: "exp",
            t: "Test", cn: "Food", ce: "🍕", sm: nil, sn: nil,
            f: participants
        )
        let stored = makeStoredTransaction(syncID: "tx-edited", id: 42)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: myID,
            existingTransactions: [stored],
            checksumOf: { _ in "stale" }
        )
        XCTAssertEqual(intent, .updatePrompt(existingID: 42, knownParticipantIndex: 1))
    }

    func testClassify_priorImportButNoStoredChecksum_isUpdatePrompt() {
        // Receiver imported the transaction before we shipped the
        // checksum-storage column. Treat as "potentially updatable" —
        // err on the side of asking the user.
        let payload = makePayload(syncID: "tx-legacy")
        let stored = makeStoredTransaction(syncID: "tx-legacy", id: 12)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [stored],
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .updatePrompt(existingID: 12, knownParticipantIndex: nil))
    }

    // MARK: - Lookup correctness

    func testClassify_matchesBySyncIDIgnoresUnrelatedTransactions() {
        let payload = makePayload(syncID: "needle")
        let unrelated1 = makeStoredTransaction(syncID: "haystack-1", id: 1)
        let unrelated2 = makeStoredTransaction(syncID: "haystack-2", id: 2)
        let target = makeStoredTransaction(syncID: "needle", id: 99)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [unrelated1, target, unrelated2],
            checksumOf: { _ in payload.checksum }
        )
        XCTAssertEqual(intent, .identical(existingID: 99))
    }

    // MARK: - Self-share

    func testClassify_selfShare_findsExistingTx_returnsIdentical() {
        // User created a split, shared their own link to themselves
        // (testing flow / accidental re-tap). Sharer ID equals
        // receiver ID — the transaction is already in their store.
        // Expected: navigate to existing, no picker, no update prompt.
        let myID = "amber-lynx-7K2D"
        let payload = SharedTransactionPayload(
            v: 1, id: "tx-self-shared", s: myID,
            ta: 90, pa: 90, ms: 30, c: "EUR",
            d: 1_700_000_000, k: "exp",
            t: "Group dinner", cn: "Food", ce: "🍕", sm: nil, sn: nil,
            f: [
                .init(id: "boris-9X1Y", n: "Boris", sh: 30, pa: 0),
                .init(id: "cara-3M4N", n: "Cara", sh: 30, pa: 0)
            ]
        )
        let stored = makeStoredTransaction(syncID: "tx-self-shared", id: 50)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: myID,
            existingTransactions: [stored],
            checksumOf: { _ in nil }  // checksum doesn't matter for self-share
        )
        XCTAssertEqual(intent, .identical(existingID: 50))
    }

    func testClassify_selfShare_existingTxDeleted_returnsMalformed() {
        // User shared a transaction, deleted it locally, then opened
        // the now-stale share link. Without the source-of-truth
        // transaction we have nothing meaningful to do.
        let myID = "amber-lynx-7K2D"
        let payload = SharedTransactionPayload(
            v: 1, id: "tx-deleted", s: myID,
            ta: 90, pa: 90, ms: 30, c: "EUR",
            d: 1_700_000_000, k: "exp",
            t: "Whatever", cn: "Food", ce: "🍕", sm: nil, sn: nil,
            f: [.init(id: "boris-9X1Y", n: "Boris", sh: 60, pa: 0)]
        )
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: myID,
            existingTransactions: [],  // nothing matching
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .malformed)
    }

    // MARK: - Malformed payload

    func testClassify_emptyParticipantList_isMalformed() {
        let payload = makePayload(participantCount: 0)
        let intent = ShareIntentClassifier.classify(
            payload: payload,
            receiverID: receiverID,
            existingTransactions: [],
            checksumOf: { _ in nil }
        )
        XCTAssertEqual(intent, .malformed)
    }
}

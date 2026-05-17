import XCTest
@testable import non_bank

final class ReceivedTransactionMapperTests: XCTestCase {

    // MARK: - Fixtures

    private let sharerID = "sharer-A1B2"

    private func makePayload(
        syncID: String = "tx-001",
        totalAmount: Double = 100,
        sharerPaid: Double = 100,
        sharerShare: Double = 50,
        participants: [SharedTransactionPayload.Participant],
        cn: String = "Food",
        ce: String = "🍕",
        sm: String? = "50/50"
    ) -> SharedTransactionPayload {
        SharedTransactionPayload(
            v: 1, id: syncID, s: sharerID,
            ta: totalAmount, pa: sharerPaid, ms: sharerShare,
            c: "EUR", d: 1_711_000_000, k: "exp",
            t: "Pizza Friday", cn: cn, ce: ce, sm: sm, sn: nil,
            f: participants
        )
    }

    private let foodCategory = Category(emoji: "🍕", title: "Food")
    private let drinkCategory = Category(emoji: "🥤", title: "Drinks")

    // MARK: - 2-person split (auto-create)

    func testMap_twoPerson_auto_receiverGetsFlippedSplitInfo() throws {
        // Sharer paid 100 for a 50/50 split with one friend (the receiver).
        let receiverParticipant = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me-as-known-by-sharer", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [receiverParticipant])

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 1
        )

        // Identity flip: sharer becomes the friend, receiver becomes "you".
        XCTAssertEqual(resolved.transaction.amount, 0,
            "Receiver paid 0 up-front in this share")
        XCTAssertEqual(resolved.transaction.splitInfo?.paidByMe, 0)
        XCTAssertEqual(resolved.transaction.splitInfo?.myShare, 50)
        XCTAssertEqual(resolved.transaction.splitInfo?.lentAmount, -50,
            "Receiver paid less than their share — they owe 50")

        // The single friend in the new transaction is the sharer.
        let storedFriends = try XCTUnwrap(resolved.transaction.splitInfo?.friends)
        XCTAssertEqual(storedFriends.count, 1)
        XCTAssertEqual(storedFriends[0].friendID, sharerID)
        XCTAssertEqual(storedFriends[0].share, 50)
        XCTAssertEqual(storedFriends[0].paidAmount, 100)
    }

    func testMap_twoPerson_auto_createsSharerAsNewFriendWithPlaceholder() throws {
        let receiverParticipant = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [receiverParticipant])

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 1
        )

        XCTAssertEqual(resolved.newFriends.count, 1)
        XCTAssertEqual(resolved.newFriends[0].id, sharerID)
        XCTAssertEqual(resolved.newFriends[0].name, "Friend",
            "Spec says use placeholder name 'Friend' for v1")
    }

    func testMap_twoPerson_auto_reusesExistingSharerFriend() throws {
        let alreadyKnown = Friend(id: sharerID, name: "Alex (custom name)")
        let receiverParticipant = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [receiverParticipant])

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [alreadyKnown],
            existingCategories: [foodCategory],
            nextTransactionID: 1
        )

        XCTAssertTrue(resolved.newFriends.isEmpty,
            "Sharer is already a known friend; mapper must reuse, not duplicate")
    }

    // MARK: - 3-person split (picker)

    func testMap_threePerson_picker_keepsOtherFriendsWithOriginalNames() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 30, pa: 0
        )
        let other = SharedTransactionPayload.Participant(
            id: "boris-9X1Y", n: "Boris", sh: 30, pa: 0
        )
        let payload = makePayload(
            totalAmount: 90, sharerShare: 30,
            participants: [me, other]
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,  // I am `me`
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 5
        )

        // splitInfo.friends should contain: sharer + Boris (NOT me).
        let friends = try XCTUnwrap(resolved.transaction.splitInfo?.friends)
        XCTAssertEqual(friends.count, 2)
        XCTAssertEqual(Set(friends.map(\.friendID)), [sharerID, "boris-9X1Y"])

        // Boris keeps his name; sharer becomes "Friend".
        let newByID = Dictionary(uniqueKeysWithValues: resolved.newFriends.map { ($0.id, $0.name) })
        XCTAssertEqual(newByID[sharerID], "Friend")
        XCTAssertEqual(newByID["boris-9X1Y"], "Boris")
    }

    func testMap_threePerson_pickerSecondIndex_picksCorrectReceiver() throws {
        let alex = SharedTransactionPayload.Participant(
            id: "alex-Q2W3", n: "Alex", sh: 30, pa: 0
        )
        let boris = SharedTransactionPayload.Participant(
            id: "boris-9X1Y", n: "Boris", sh: 30, pa: 0
        )
        let payload = makePayload(
            totalAmount: 90, sharerShare: 30,
            participants: [alex, boris]
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 1,  // I am Boris
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 5
        )

        // Boris's perspective: paid 0, share 30, owes 30.
        XCTAssertEqual(resolved.transaction.splitInfo?.myShare, 30)
        // Friends in transaction = sharer + Alex (Boris excluded).
        let friendIDs = Set(resolved.transaction.splitInfo?.friends.map(\.friendID) ?? [])
        XCTAssertEqual(friendIDs, [sharerID, "alex-Q2W3"])
    }

    func testMap_invalidParticipantIndex_throws() {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 30, pa: 0
        )
        let payload = makePayload(participants: [me])

        XCTAssertThrowsError(try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 5,  // out of bounds
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 1
        )) { error in
            guard case ReceivedTransactionMapperError.invalidParticipantIndex = error else {
                XCTFail("Expected invalidParticipantIndex, got \(error)")
                return
            }
        }
    }

    // MARK: - Category matching

    func testMap_categoryMatchesExistingByTitle_noNewCategory() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        // Receiver already has "Food" category but with a different emoji.
        let receiverFood = Category(emoji: "🍔", title: "Food")
        let payload = makePayload(
            participants: [me], cn: "Food", ce: "🍕"
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [receiverFood],
            nextTransactionID: 1
        )

        XCTAssertNil(resolved.newCategory,
            "Receiver already has 'Food' — must reuse, not create")
        XCTAssertEqual(resolved.transaction.category, "Food")
        XCTAssertEqual(resolved.transaction.emoji, "🍔",
            "Use receiver's emoji, not sharer's")
    }

    func testMap_newCategoryWithUniqueEmoji_usesPayloadEmoji() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(
            participants: [me], cn: "Snacks", ce: "🍿"
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory, drinkCategory],
            nextTransactionID: 1
        )

        let newCat = try XCTUnwrap(resolved.newCategory)
        XCTAssertEqual(newCat.title, "Snacks")
        XCTAssertEqual(newCat.emoji, "🍿",
            "No collision — keep the sharer's chosen emoji")
        XCTAssertEqual(resolved.transaction.emoji, "🍿")
    }

    func testMap_newCategoryWithCollidingEmoji_picksFallback() throws {
        // Receiver already has 🍕 on the Food category. Sharer's
        // payload says "Snacks 🍕" — different name, same emoji. The
        // mapper must pick a different emoji from the fallback list.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(
            participants: [me], cn: "Snacks", ce: "🍕"
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory],  // takes 🍕
            nextTransactionID: 1
        )

        let newCat = try XCTUnwrap(resolved.newCategory)
        XCTAssertEqual(newCat.title, "Snacks")
        XCTAssertNotEqual(newCat.emoji, "🍕",
            "Must avoid colliding with existing Food 🍕")
        XCTAssertNotEqual(newCat.emoji, "🥤",
            "Don't pick an existing emoji from any other receiver category")
    }

    func testUniqueEmoji_directHelper() {
        let cats = [Category(emoji: "🍕", title: "Food")]
        XCTAssertEqual(
            ReceivedTransactionMapper.uniqueEmoji(preferred: "🥤", takenBy: cats),
            "🥤"
        )
        XCTAssertNotEqual(
            ReceivedTransactionMapper.uniqueEmoji(preferred: "🍕", takenBy: cats),
            "🍕"
        )
    }

    // MARK: - Transaction-level fields

    func testMap_preservesSyncIDAndDate() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(
            syncID: "tx-share-123", participants: [me]
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 99
        )

        XCTAssertEqual(resolved.transaction.id, 99)
        XCTAssertEqual(resolved.transaction.syncID, "tx-share-123")
        XCTAssertEqual(resolved.transaction.date.timeIntervalSince1970, 1_711_000_000)
    }

    func testMap_typeRoundTrip_expense() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me])  // k = "exp"
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertEqual(resolved.transaction.type, .expenses)
    }

    func testMap_typeRoundTrip_income() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        var payload = makePayload(participants: [me])
        payload = SharedTransactionPayload(
            v: payload.v, id: payload.id, s: payload.s,
            ta: payload.ta, pa: payload.pa, ms: payload.ms,
            c: payload.c, d: payload.d,
            k: "inc",
            t: payload.t, cn: payload.cn, ce: payload.ce, sm: payload.sm, sn: payload.sn,
            f: payload.f
        )
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertEqual(resolved.transaction.type, .income)
    }

    func testMap_payloadChecksumIsRecorded() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me])
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertEqual(resolved.payloadChecksum, payload.checksum)
        XCTAssertEqual(resolved.payloadChecksum.count, 64)  // SHA-256 hex
    }

    func testMap_splitMode_roundTrip() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byAmount")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byAmount)
    }

    func testMap_legacySplitModeNil_decodesAsNil() throws {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: nil)
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertNil(resolved.transaction.splitInfo?.splitMode)
    }

    func testMap_byItemsPayloadOnFirstImport_coercedToByAmount() throws {
        // Defensive: older sharers (pre-encoder-coercion) emitted
        // `"byItems"` literally even though receipt items don't ride
        // along in the URL. The receiver MUST coerce to `.byAmount`
        // so the local detail card / edit modal don't surface a
        // "Split by receipt" affordance for a transaction whose
        // items live on someone else's device.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byItems")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byAmount)
    }

    // MARK: - Items-aware splitMode rule (update path)
    //
    // The rule, applied by the mapper:
    //
    //   Receiver has items locally       Payload sm          → Result
    //   ─────────────────────────────────────────────────────────────
    //   true                             byItems/byAmount/nil → .byItems
    //   true                             evenly               → .evenly
    //   true                             settleUp             → .settleUp
    //   false                            byItems              → .byAmount (coerce)
    //   false                            anything else        → payload's mode
    //
    // Rationale: byItems is structurally local (items aren't on the
    // wire). Items locally + items-shape payload (byAmount is the
    // wire format for items-backed shares) → preserve the byItems
    // display. evenly / settleUp from the friend is an explicit
    // redistribute intent, so the receiver's items-based display
    // yields to it.

    private func makeExistingByItemsTx(
        syncID: String,
        sharerID: String = "sharer-A1B2"
    ) -> Transaction {
        let existingSplit = SplitInfo(
            totalAmount: 100, paidByMe: 0, myShare: 50, lentAmount: -50,
            friends: [FriendShare(friendID: sharerID, share: 50, paidAmount: 100)],
            splitMode: .byItems
        )
        return Transaction(
            id: 99, syncID: syncID,
            emoji: "🍕", category: "Food", title: "Pizza Friday",
            description: nil, amount: 0, currency: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            type: .expenses, tags: nil, splitInfo: existingSplit
        )
    }

    func testMap_updatePath_itemsLocal_byAmountPayload_keepsByItems() throws {
        // Receiver had `.byItems` locally with assigned items; sharer
        // re-shared with `.byAmount` on the wire (the canonical
        // post-encoder-coercion format for any items-backed share).
        // Items still anchor a byItems display on the receiver side.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byAmount")
        let existingTx = makeExistingByItemsTx(syncID: payload.id, sharerID: sharerID)
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 99,
            existingTransaction: existingTx,
            receiverHasLocalItemsForTx: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byItems)
    }

    func testMap_updatePath_itemsLocal_evenlyPayload_adoptsEvenly() throws {
        // Receiver had items + `.byItems`; sharer explicitly switched
        // to `.evenly` and re-shared. That's a deliberate redistribute
        // intent — receiver's view yields to it. Items stay in the
        // store (mapper doesn't touch ReceiptItemStore) but no longer
        // drive the display until the receiver flips back manually.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "50/50")
        let existingTx = makeExistingByItemsTx(syncID: payload.id, sharerID: sharerID)
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 99,
            existingTransaction: existingTx,
            receiverHasLocalItemsForTx: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .evenly)
    }

    func testMap_updatePath_itemsLocal_settleUpPayload_adoptsSettleUp() throws {
        // `.settleUp` parallels `.evenly`: explicit redistribute
        // intent from the sharer overrides the receiver's items
        // display.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 100, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "settleUp")
        let existingTx = makeExistingByItemsTx(syncID: payload.id, sharerID: sharerID)
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 99,
            existingTransaction: existingTx,
            receiverHasLocalItemsForTx: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .settleUp)
    }

    func testMap_updatePath_itemsLocal_byItemsPayload_keepsByItems() throws {
        // Sharer emitted "byItems" on the wire (the default post-fix
        // encoder behaviour). Receiver has items locally — keep
        // `.byItems`.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byItems")
        let existingTx = makeExistingByItemsTx(syncID: payload.id, sharerID: sharerID)
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 99,
            existingTransaction: existingTx,
            receiverHasLocalItemsForTx: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byItems)
    }

    func testMap_updatePath_noItemsLocal_evenlyPayload_takesEvenly() throws {
        // No items locally → payload's mode applies verbatim.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "50/50")
        let existingTx = makeExistingByItemsTx(syncID: payload.id, sharerID: sharerID)
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 99,
            existingTransaction: existingTx,
            receiverHasLocalItemsForTx: false
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .evenly)
    }

    // MARK: - Update path: receiver's title + category preserved

    func testMap_updatePath_preservesReceiverTitleCategoryEmoji() throws {
        // Receiver previously imported this transaction and customised
        // the title + moved it to their own category. The sharer then
        // edits THEIR copy (different title, different category) and
        // re-shares. Expected: amounts/dates update, but the receiver's
        // title and category survive.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(
            participants: [me],
            cn: "Food",       // ← sharer's category name
            ce: "🍕"           // ← sharer's category emoji
        )

        // Receiver's existing record has different title + category.
        let receiverCategory = Category(emoji: "🥑", title: "Healthy")
        let existingTx = Transaction(
            id: 99,
            syncID: payload.id,
            emoji: "🥑",
            category: "Healthy",
            title: "My renamed dinner",
            description: nil,
            amount: 0,
            currency: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            type: .expenses,
            tags: nil
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory, receiverCategory],
            nextTransactionID: 99,
            existingTransaction: existingTx
        )

        // Title and category survive the update.
        XCTAssertEqual(resolved.transaction.title, "My renamed dinner")
        XCTAssertEqual(resolved.transaction.category, "Healthy")
        XCTAssertEqual(resolved.transaction.emoji, "🥑")
        // No new category created — we used receiver's existing one.
        XCTAssertNil(resolved.newCategory)
        // But the rest of the payload IS applied: amounts, splitInfo, etc.
        XCTAssertEqual(resolved.transaction.amount, 0)  // receiver paid 0
        XCTAssertEqual(resolved.transaction.splitInfo?.totalAmount, 100)
        XCTAssertEqual(resolved.transaction.splitInfo?.myShare, 50)
    }

    func testMap_updatePath_categoryDeletedSinceImport_recreatesFromExistingTx() throws {
        // Edge case: between import and update the user deleted the
        // category their transaction was in. Re-creating it from the
        // existing record (rather than falling through to the payload's
        // category) keeps the user's emoji/title choice.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], cn: "Food", ce: "🍕")
        let existingTx = Transaction(
            id: 99, syncID: payload.id,
            emoji: "🥑", category: "Healthy",
            title: "Salad", description: nil,
            amount: 0, currency: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            type: .expenses, tags: nil
        )

        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory],  // "Healthy" no longer exists
            nextTransactionID: 99,
            existingTransaction: existingTx
        )

        // The transaction still uses "Healthy" / 🥑.
        XCTAssertEqual(resolved.transaction.category, "Healthy")
        XCTAssertEqual(resolved.transaction.emoji, "🥑")
        // And we report a new category to be re-created — caller can
        // commit it through CategoryStore.
        XCTAssertEqual(resolved.newCategory?.title, "Healthy")
        XCTAssertEqual(resolved.newCategory?.emoji, "🥑")
    }

    func testMap_createPath_stillUsesPayloadTitleCategory() throws {
        // Sanity: when `existingTransaction` is nil (first-time
        // import) we keep the original behaviour and pull title +
        // category from the payload.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], cn: "Food", ce: "🍕")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [],
            existingCategories: [foodCategory],
            nextTransactionID: 1,
            existingTransaction: nil
        )
        XCTAssertEqual(resolved.transaction.title, "Pizza Friday")
        XCTAssertEqual(resolved.transaction.category, "Food")
        XCTAssertEqual(resolved.transaction.emoji, "🍕")
    }

    // MARK: - Phase 10.1: byItems reconstruction via share-items channel

    func testMap_payloadCameWithItems_firstImport_resolvesToByItems() throws {
        // First-time import with items delivered via the share-items
        // channel must resolve to `.byItems` even though the wire mode
        // is `.byAmount` (the encoder always coerces). Without this
        // the recipient would see `.byAmount` and miss the per-item
        // breakdown the sender prepared.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byAmount")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1,
            payloadCameWithItems: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byItems)
    }

    func testMap_payloadCameWithItems_evenlyOverrides() throws {
        // Even with items in flight, an explicit `.evenly` payload
        // wins — that matches the local-items rule: the sender's
        // mode-change intent is honoured over the items-driven
        // display.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "50/50")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1,
            payloadCameWithItems: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .evenly)
    }

    func testMap_payloadCameWithItemsFalse_stillCoercesByItemsToByAmount() throws {
        // Sanity guard for the no-items fallback path: when the
        // share-items channel returns nothing, the old "byItems on
        // wire → coerce to byAmount" rule must still hold so the
        // recipient doesn't see an empty items list.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byItems")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1,
            payloadCameWithItems: false
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byAmount)
    }

    func testMap_byItemsWireFormat_withItemsChannel_resolvesToByItems() throws {
        // Post-encoder-fix: the sender's wire `sm` for byItems
        // transactions is now `"byItems"` (was coerced to `"byAmount"`
        // before Phase 10 / 10.1 landed). On first import, with the
        // share-items channel delivering items in the same hop, the
        // receiver should resolve to `.byItems` — both axes of the
        // decision matrix point that way (wire says byItems, items
        // are available).
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me], sm: "byItems")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload,
            receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1,
            payloadCameWithItems: true
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .byItems)
    }

    // MARK: - rewriteItemAssignees

    private func makeAssignedItem(name: String, total: Double, assignees: [String]) -> ReceiptItem {
        ReceiptItem(
            name: name, quantity: 1, price: total, total: total,
            assignedParticipantIDs: assignees
        )
    }

    func testRewriteItemAssignees_swapsSenderSelfWithReceiverSelf() {
        // Sender's perspective items:
        //   • Pizza assigned to "__me__" (= sender themselves)
        //   • Beer assigned to "rec-X1" (= receiver, per payload.f[0])
        // After receiver-side rewrite:
        //   • Pizza → sender's participant id (now a Friend on recipient)
        //   • Beer  → "__me__" (receiver claims it as their own)
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me])
        let items = [
            makeAssignedItem(name: "Pizza", total: 12, assignees: [ReceiptItem.selfParticipantID]),
            makeAssignedItem(name: "Beer", total: 5, assignees: ["rec-X1"]),
        ]
        let rewritten = ReceivedTransactionMapper.rewriteItemAssignees(
            items: items, payload: payload, receiverParticipantIndex: 0
        )
        XCTAssertEqual(rewritten[0].assignedParticipantIDs, [sharerID],
            "Pizza must be reassigned to sharer (now a Friend on recipient side)")
        XCTAssertEqual(rewritten[1].assignedParticipantIDs, [ReceiptItem.selfParticipantID],
            "Beer must flip to recipient's local `__me__` sentinel")
    }

    func testRewriteItemAssignees_preservesOtherFriends() {
        // 3-way split: sender + receiver + a third friend Anna.
        // Items assigned to Anna stay with Anna's id (the mapper
        // will create a Friend record for her on the receiver side).
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 30, pa: 0
        )
        let anna = SharedTransactionPayload.Participant(
            id: "anna-id-Z9", n: "Anna", sh: 30, pa: 0
        )
        let payload = makePayload(
            participants: [me, anna], sm: "byAmount"
        )
        let items = [
            makeAssignedItem(name: "Salad", total: 8, assignees: ["anna-id-Z9"]),
            makeAssignedItem(name: "Pasta", total: 10, assignees: [ReceiptItem.selfParticipantID, "anna-id-Z9"]),
        ]
        let rewritten = ReceivedTransactionMapper.rewriteItemAssignees(
            items: items, payload: payload, receiverParticipantIndex: 0
        )
        XCTAssertEqual(rewritten[0].assignedParticipantIDs, ["anna-id-Z9"])
        XCTAssertEqual(rewritten[1].assignedParticipantIDs, [sharerID, "anna-id-Z9"],
            "Multi-assignee items must keep order and rewrite each id independently")
    }

    func testRewriteItemAssignees_leavesUnassignedItemsAlone() {
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me])
        let items = [
            makeAssignedItem(name: "Tip", total: 5, assignees: []),
            makeAssignedItem(name: "Service fee", total: 3, assignees: []),
        ]
        let rewritten = ReceivedTransactionMapper.rewriteItemAssignees(
            items: items, payload: payload, receiverParticipantIndex: 0
        )
        XCTAssertTrue(rewritten.allSatisfy { $0.assignedParticipantIDs.isEmpty })
    }

    func testRewriteItemAssignees_invalidIndex_returnsItemsUnchanged() {
        // Defensive: a stale picker index that's out-of-bounds for the
        // payload's participant list should NOT crash or partially
        // rewrite. Return the items verbatim and let the caller's
        // upstream guard (the mapper itself) surface the real error.
        let me = SharedTransactionPayload.Participant(
            id: "rec-X1", n: "Me", sh: 50, pa: 0
        )
        let payload = makePayload(participants: [me])
        let items = [
            makeAssignedItem(name: "Pizza", total: 12, assignees: [ReceiptItem.selfParticipantID]),
        ]
        let rewritten = ReceivedTransactionMapper.rewriteItemAssignees(
            items: items, payload: payload, receiverParticipantIndex: 99
        )
        XCTAssertEqual(rewritten[0].assignedParticipantIDs, [ReceiptItem.selfParticipantID])
    }
}

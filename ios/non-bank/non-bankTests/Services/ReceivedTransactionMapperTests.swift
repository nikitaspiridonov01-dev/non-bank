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
        let payload = makePayload(participants: [me], sm: "Unequally, exact amounts")
        let resolved = try ReceivedTransactionMapper.map(
            payload: payload, receiverParticipantIndex: 0,
            existingFriends: [], existingCategories: [foodCategory],
            nextTransactionID: 1
        )
        XCTAssertEqual(resolved.transaction.splitInfo?.splitMode, .unequalExact)
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
}

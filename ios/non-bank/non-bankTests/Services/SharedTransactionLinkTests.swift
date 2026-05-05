import XCTest
@testable import non_bank

final class SharedTransactionLinkTests: XCTestCase {

    // MARK: - Fixtures

    private let sharerID = "amber-lynx-7K2D"

    private let sampleCategory = Category(
        id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        emoji: "🍕",
        title: "Food",
        lastModified: Date(timeIntervalSince1970: 1_700_000_000)
    )

    /// Builds a 2-person split: sharer paid 100, splits 50/50 with one friend.
    private func makeTwoPersonSplit() -> (Transaction, [Friend]) {
        let friend = Friend(id: "blue-otter-A2BC", name: "Alex", lastModified: Date(timeIntervalSince1970: 1_700_000_000))
        let split = SplitInfo(
            totalAmount: 100,
            paidByMe: 100,
            myShare: 50,
            lentAmount: 50,
            friends: [FriendShare(friendID: friend.id, share: 50, paidAmount: 0)],
            splitMode: .fiftyFifty
        )
        let tx = Transaction(
            id: 1,
            syncID: "tx-sync-001",
            emoji: "🍕",
            category: "Food",
            title: "Pizza Friday",
            description: nil,
            amount: 100,
            currency: "EUR",
            date: Date(timeIntervalSince1970: 1_711_500_000),
            type: .expenses,
            tags: nil,
            splitInfo: split
        )
        return (tx, [friend])
    }

    /// Builds a 3-person split with custom shares: sharer paid 90, friends owe 30 each.
    private func makeThreePersonSplit() -> (Transaction, [Friend]) {
        let f1 = Friend(id: "calm-finch-9X1Y", name: "Boris")
        let f2 = Friend(id: "deep-owl-3M4N", name: "Cara")
        let split = SplitInfo(
            totalAmount: 90,
            paidByMe: 90,
            myShare: 30,
            lentAmount: 60,
            friends: [
                FriendShare(friendID: f1.id, share: 30, paidAmount: 0),
                FriendShare(friendID: f2.id, share: 30, paidAmount: 0)
            ],
            splitMode: .unequalExact
        )
        let tx = Transaction(
            id: 2,
            syncID: "tx-sync-003",
            emoji: "🍕",
            category: "Food",
            title: "Dinner",
            description: nil,
            amount: 90,
            currency: "RSD",
            date: Date(timeIntervalSince1970: 1_711_400_000),
            type: .expenses,
            tags: nil,
            splitInfo: split
        )
        return (tx, [f1, f2])
    }

    // MARK: - Encode happy path

    func testEncode_twoPersonSplit_customScheme_buildsExpectedURLShape() throws {
        let (tx, friends) = makeTwoPersonSplit()
        let url = try SharedTransactionLink.encode(
            transaction: tx,
            sharerID: sharerID, sharerName: nil,
            friends: friends,
            category: sampleCategory,
            style: .customScheme
        )
        let absolute = url.absoluteString
        XCTAssertTrue(
            absolute.hasPrefix("nonbank://share?p="),
            "Unexpected URL shape: \(absolute)"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let pValue = components?.queryItems?.first(where: { $0.name == "p" })?.value
        XCTAssertNotNil(pValue)
        XCTAssertFalse(pValue!.isEmpty)
        // base64url alphabet — no `+`, `/`, `=`.
        XCTAssertNil(pValue?.firstIndex(of: "+"))
        XCTAssertNil(pValue?.firstIndex(of: "/"))
        XCTAssertNil(pValue?.firstIndex(of: "="))
    }

    func testEncode_universalLinkStyle_buildsHTTPSURL() throws {
        let (tx, friends) = makeTwoPersonSplit()
        let url = try SharedTransactionLink.encode(
            transaction: tx,
            sharerID: sharerID, sharerName: nil,
            friends: friends,
            category: sampleCategory,
            style: .universalLink
        )
        XCTAssertTrue(
            url.absoluteString.hasPrefix("https://nikitaspiridonov01-dev.github.io/transaction/?p="),
            "Unexpected URL shape: \(url.absoluteString)"
        )
    }

    // MARK: - URL routing helpers

    func testIsShareURL_recognisesBothSchemes() {
        XCTAssertTrue(SharedTransactionLink.isShareURL(URL(string: "nonbank://share?p=abc")!))
        XCTAssertTrue(SharedTransactionLink.isShareURL(URL(string: "https://nikitaspiridonov01-dev.github.io/transaction/?p=abc")!))
        XCTAssertFalse(SharedTransactionLink.isShareURL(URL(string: "https://example.com/transaction/?p=abc")!))
        XCTAssertFalse(SharedTransactionLink.isShareURL(URL(string: "nonbank://other?p=abc")!))
        XCTAssertFalse(SharedTransactionLink.isShareURL(URL(string: "myapp://share?p=abc")!))
    }

    func testDecode_acceptsBothSchemes() throws {
        // Build a payload, encode in both styles, decode each. Same
        // payload contents must round-trip from either URL flavour.
        let (tx, friends) = makeTwoPersonSplit()
        let custom = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends,
            category: sampleCategory, style: .customScheme
        )
        let universal = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends,
            category: sampleCategory, style: .universalLink
        )
        let p1 = try SharedTransactionLink.decode(url: custom)
        let p2 = try SharedTransactionLink.decode(url: universal)
        XCTAssertEqual(p1, p2)
    }

    func testEncode_throwsForNonSplitTransaction() {
        let tx = Transaction(
            id: 99,
            emoji: "🍕",
            category: "Food",
            title: "Lone latte",
            description: nil,
            amount: 4,
            currency: "EUR",
            date: Date(),
            type: .expenses,
            tags: nil
        )
        XCTAssertThrowsError(
            try SharedTransactionLink.encode(
                transaction: tx,
                sharerID: sharerID, sharerName: nil,
                friends: [],
                category: sampleCategory
            )
        ) { error in
            guard case SharedTransactionError.notASplitTransaction = error else {
                XCTFail("Expected notASplitTransaction, got \(error)")
                return
            }
        }
    }

    func testEncode_unknownFriendID_fallsBackToIDAsName() throws {
        // Sender has a FriendShare referencing a friend record that's no
        // longer in their FriendStore (deleted, never synced, etc.).
        // Round-trips fine — receiver just sees the ID as the display
        // name and can rename later.
        let split = SplitInfo(
            totalAmount: 50, paidByMe: 50, myShare: 25, lentAmount: 25,
            friends: [FriendShare(friendID: "ghost-fox-Z9Z9", share: 25, paidAmount: 0)],
            splitMode: .fiftyFifty
        )
        let tx = Transaction(
            id: 3, syncID: "tx-sync-orphan",
            emoji: "🍕", category: "Food", title: "Whatever",
            description: nil, amount: 50, currency: "EUR",
            date: Date(timeIntervalSince1970: 1_700_000_000),
            type: .expenses, tags: nil, splitInfo: split
        )
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: [], category: sampleCategory
        )
        let payload = try SharedTransactionLink.decode(url: url)
        XCTAssertEqual(payload.f.first?.n, "ghost-fox-Z9Z9")
    }

    // MARK: - Round-trip

    func testRoundTrip_preservesAllFields() throws {
        let (tx, friends) = makeTwoPersonSplit()
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )
        let payload = try SharedTransactionLink.decode(url: url)

        XCTAssertEqual(payload.v, 1)
        XCTAssertEqual(payload.id, "tx-sync-001")
        XCTAssertEqual(payload.s, sharerID)
        XCTAssertEqual(payload.ta, 100)
        XCTAssertEqual(payload.pa, 100)
        XCTAssertEqual(payload.ms, 50)
        XCTAssertEqual(payload.c, "EUR")
        XCTAssertEqual(payload.d, 1_711_500_000)
        XCTAssertEqual(payload.k, "exp")
        XCTAssertEqual(payload.t, "Pizza Friday")
        XCTAssertEqual(payload.cn, "Food")
        XCTAssertEqual(payload.ce, "🍕")
        XCTAssertEqual(payload.sm, "50/50")
        XCTAssertEqual(payload.f.count, 1)
        XCTAssertEqual(payload.f[0].id, "blue-otter-A2BC")
        XCTAssertEqual(payload.f[0].n, "Alex")
        XCTAssertEqual(payload.f[0].sh, 50)
        XCTAssertEqual(payload.f[0].pa, 0)
    }

    func testRoundTrip_threePersonSplit_preservesOrderAndShares() throws {
        let (tx, friends) = makeThreePersonSplit()
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )
        let payload = try SharedTransactionLink.decode(url: url)
        XCTAssertEqual(payload.f.map(\.n), ["Boris", "Cara"])
        XCTAssertEqual(payload.f.map(\.sh), [30, 30])
        XCTAssertEqual(payload.sm, "Unequally, exact amounts")
    }

    func testRoundTrip_cyrillicAndEmojiInTextFields() throws {
        // Cyrillic title and emoji-laden category name — URLs must
        // survive without re-encoding chaos.
        let f = Friend(id: "warm-bear-F1G2", name: "Михаил")
        let split = SplitInfo(
            totalAmount: 1500, paidByMe: 1500, myShare: 750, lentAmount: 750,
            friends: [FriendShare(friendID: f.id, share: 750, paidAmount: 0)],
            splitMode: .fiftyFifty
        )
        let tx = Transaction(
            id: 4, syncID: "tx-sync-rus",
            emoji: "🥟", category: "Еда",
            title: "Ужин в ресторане Ёж&Ужин",
            description: nil, amount: 1500, currency: "RSD",
            date: Date(timeIntervalSince1970: 1_711_300_000),
            type: .expenses, tags: nil, splitInfo: split
        )
        let category = Category(emoji: "🥟", title: "Еда")
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: [f], category: category
        )
        let payload = try SharedTransactionLink.decode(url: url)
        XCTAssertEqual(payload.t, "Ужин в ресторане Ёж&Ужин")
        XCTAssertEqual(payload.cn, "Еда")
        XCTAssertEqual(payload.ce, "🥟")
        XCTAssertEqual(payload.f.first?.n, "Михаил")
    }

    func testRoundTrip_legacySplitWithoutMode_decodesNilSplitMode() throws {
        let f = Friend(id: "old-vole-2K2K", name: "Legacy")
        let split = SplitInfo(
            totalAmount: 20, paidByMe: 20, myShare: 10, lentAmount: 10,
            friends: [FriendShare(friendID: f.id, share: 10, paidAmount: 0)],
            splitMode: nil  // legacy
        )
        let tx = Transaction(
            id: 5, syncID: "tx-sync-legacy",
            emoji: "🍕", category: "Food", title: "X",
            description: nil, amount: 20, currency: "EUR",
            date: Date(), type: .expenses, tags: nil, splitInfo: split
        )
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: [f], category: sampleCategory
        )
        let payload = try SharedTransactionLink.decode(url: url)
        XCTAssertNil(payload.sm)
    }

    // MARK: - Decode error paths

    func testDecode_missingPayloadParam_throws() {
        let url = URL(string: "https://share.nonbank.app/s/")!
        XCTAssertThrowsError(try SharedTransactionLink.decode(url: url)) { error in
            guard case SharedTransactionError.missingPayload = error else {
                XCTFail("Expected missingPayload, got \(error)")
                return
            }
        }
    }

    func testDecode_emptyPayloadParam_throws() {
        let url = URL(string: "https://share.nonbank.app/s/?p=")!
        XCTAssertThrowsError(try SharedTransactionLink.decode(url: url)) { error in
            guard case SharedTransactionError.missingPayload = error else {
                XCTFail("Expected missingPayload, got \(error)")
                return
            }
        }
    }

    func testDecode_invalidBase64_throws() {
        // `!` isn't part of base64 or base64url alphabet.
        let url = URL(string: "https://share.nonbank.app/s/?p=not!valid!base64")!
        XCTAssertThrowsError(try SharedTransactionLink.decode(url: url)) { error in
            guard case SharedTransactionError.invalidEncoding = error else {
                XCTFail("Expected invalidEncoding, got \(error)")
                return
            }
        }
    }

    func testDecode_validBase64ButNotJSON_throws() {
        // Encodes the literal text "hello world" as base64url.
        let raw = Data("hello world".utf8)
        let b64url = SharedTransactionLink.base64URLEncode(raw)
        let url = URL(string: "https://share.nonbank.app/s/?p=\(b64url)")!
        XCTAssertThrowsError(try SharedTransactionLink.decode(url: url)) { error in
            guard case SharedTransactionError.malformedPayload = error else {
                XCTFail("Expected malformedPayload, got \(error)")
                return
            }
        }
    }

    func testDecode_unsupportedSchemaVersion_throws() throws {
        // Manually craft a v=99 payload — current decoder must refuse.
        let futurePayload = SharedTransactionPayload(
            v: 99, id: "x", s: "y", ta: 0, pa: 0, ms: 0,
            c: "EUR", d: 0, k: "exp", t: "x", cn: "x", ce: "x",
            sm: nil, sn: nil, f: []
        )
        let url = try SharedTransactionLink.buildURL(payload: futurePayload)
        XCTAssertThrowsError(try SharedTransactionLink.decode(url: url)) { error in
            guard case SharedTransactionError.unsupportedVersion(let v) = error else {
                XCTFail("Expected unsupportedVersion, got \(error)")
                return
            }
            XCTAssertEqual(v, 99)
        }
    }

    // MARK: - Checksum

    func testChecksum_sameContents_sameDigest() throws {
        let (tx, friends) = makeTwoPersonSplit()
        let url1 = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )
        let url2 = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )
        let p1 = try SharedTransactionLink.decode(url: url1)
        let p2 = try SharedTransactionLink.decode(url: url2)
        XCTAssertEqual(p1.checksum, p2.checksum)
    }

    func testChecksum_differingAmount_differsDigest() throws {
        let (tx, friends) = makeTwoPersonSplit()
        let url1 = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )

        // Build a slightly different transaction (amount changed).
        var diffSplit = tx.splitInfo!
        diffSplit = SplitInfo(
            totalAmount: 200,  // was 100
            paidByMe: 200, myShare: 100, lentAmount: 100,
            friends: diffSplit.friends, splitMode: diffSplit.splitMode
        )
        let txB = Transaction(
            id: tx.id, syncID: tx.syncID,
            emoji: tx.emoji, category: tx.category, title: tx.title,
            description: tx.description, amount: 200,
            currency: tx.currency, date: tx.date, type: tx.type, tags: tx.tags,
            splitInfo: diffSplit
        )
        let url2 = try SharedTransactionLink.encode(
            transaction: txB, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )

        let p1 = try SharedTransactionLink.decode(url: url1)
        let p2 = try SharedTransactionLink.decode(url: url2)
        XCTAssertNotEqual(p1.checksum, p2.checksum)
    }

    func testChecksum_isHexFormat() throws {
        let (tx, friends) = makeTwoPersonSplit()
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )
        let payload = try SharedTransactionLink.decode(url: url)
        XCTAssertEqual(payload.checksum.count, 64)  // SHA-256 = 32 bytes = 64 hex chars
        XCTAssertTrue(payload.checksum.allSatisfy { $0.isHexDigit })
    }

    // MARK: - Base64URL helpers

    func testBase64URL_roundTrip() {
        let original = Data((0..<200).map { UInt8($0 % 256) })
        let encoded = SharedTransactionLink.base64URLEncode(original)
        XCTAssertNil(encoded.firstIndex(of: "+"))
        XCTAssertNil(encoded.firstIndex(of: "/"))
        XCTAssertNil(encoded.firstIndex(of: "="))
        let decoded = SharedTransactionLink.base64URLDecode(encoded)
        XCTAssertEqual(decoded, original)
    }

    // MARK: - Practical URL size

    func testEncode_threePersonSplit_urlBelow1000Chars() throws {
        // Sanity check on link length — typical case must comfortably fit
        // in iMessage previews and not look horrifying when pasted.
        let (tx, friends) = makeThreePersonSplit()
        let url = try SharedTransactionLink.encode(
            transaction: tx, sharerID: sharerID, sharerName: nil, friends: friends, category: sampleCategory
        )
        XCTAssertLessThan(url.absoluteString.count, 1000,
            "Share URL got too long: \(url.absoluteString.count) chars")
    }
}

import XCTest
@testable import non_bank

final class PhantomFriendUpgradeDetectorTests: XCTestCase {

    private let myID = "alice-cat-A1B2"

    // MARK: - Two-person split

    func testDetect_twoPersonSplit_bobUpgradesPhantom() {
        // Alice had phantom Bob locally (id=PHANTOM). Created split
        // Bob:50/me:50, shared to real Bob. Real Bob received, edited,
        // shared back. Alice's app sees:
        //   OLD friends in tx: [PHANTOM_BOB]
        //   NEW payload.f: [me]
        //   sharer: BOB_REAL_ID
        // Detector concludes phantom_bob ≡ bob_real.
        let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
            oldFriendIDsInTransaction: ["phantom-bob"],
            newPayloadParticipantIDs: [myID],
            receiverID: myID,
            sharerID: "bob-real-X7Y8"
        )
        XCTAssertEqual(upgrade, .init(phantomID: "phantom-bob", realID: "bob-real-X7Y8"))
    }

    // MARK: - Three-person split

    func testDetect_threePersonSplit_charlieStayed_bobUpgrades() {
        // Alice's tx had [PHANTOM_BOB, CHARLIE_REAL]. Bob receives,
        // edits, shares back. Bob's payload.f after his identity flip:
        //   [me, CHARLIE_REAL] (Bob is now sharer, excluded from f).
        let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
            oldFriendIDsInTransaction: ["phantom-bob", "charlie-real"],
            newPayloadParticipantIDs: [myID, "charlie-real"],
            receiverID: myID,
            sharerID: "bob-real-X7Y8"
        )
        XCTAssertEqual(upgrade, .init(phantomID: "phantom-bob", realID: "bob-real-X7Y8"))
    }

    // MARK: - Ambiguity (multiple phantoms missing)

    func testDetect_twoPhantomsMissing_returnsNil() {
        // Alice had [phantom-bob, phantom-charlie]. New payload from
        // some sharer says [me]. We can't tell which phantom is the
        // new sharer — too ambiguous. Don't auto-merge.
        let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
            oldFriendIDsInTransaction: ["phantom-bob", "phantom-charlie"],
            newPayloadParticipantIDs: [myID],
            receiverID: myID,
            sharerID: "someone-real-Z9Z9"
        )
        XCTAssertNil(upgrade)
    }

    // MARK: - No phantoms missing (everyone preserved)

    func testDetect_noPhantomsMissing_returnsNil() {
        // OLD = NEW (besides me). Everyone's ID stayed the same — no
        // phantom got upgraded.
        let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
            oldFriendIDsInTransaction: ["bob-real", "charlie-real"],
            newPayloadParticipantIDs: [myID, "charlie-real"],
            receiverID: myID,
            sharerID: "bob-real"
        )
        XCTAssertNil(upgrade)
    }

    // MARK: - Sharer already in old friends (defensive)

    func testDetect_sharerAlreadyInOldFriends_returnsNil() {
        // Sharer's real ID was already a Friend in receiver's tx
        // (e.g. they share-linked at some point in the past). The
        // round-trip didn't introduce anyone new — bail out, no
        // phantom to upgrade.
        let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
            oldFriendIDsInTransaction: ["bob-real", "phantom-charlie"],
            newPayloadParticipantIDs: [myID, "phantom-charlie"],
            receiverID: myID,
            sharerID: "bob-real"
        )
        XCTAssertNil(upgrade)
    }

    // MARK: - Edge: identical phantom and real (theoretical)

    func testDetect_phantomEqualsReal_returnsNil() {
        // Sanity check: if for whatever reason the phantom ID == real
        // ID (they shouldn't, but defend against it), don't try to
        // "upgrade" them to themselves.
        let upgrade = PhantomFriendUpgradeDetector.detectUpgrade(
            oldFriendIDsInTransaction: ["bob-X1"],
            newPayloadParticipantIDs: [myID],
            receiverID: myID,
            sharerID: "bob-X1"  // same as the old friend
        )
        XCTAssertNil(upgrade)
    }
}

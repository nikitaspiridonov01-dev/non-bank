import XCTest
@testable import non_bank

/// Round-trip + key-isolation tests for the server-sync delivery E2E
/// crypto. The wire format is opaque to the Worker; these guard that two
/// paired devices derive the same key (order-independent) and that a
/// wrong/other peer's key can't open a delivery.
final class SyncDeliveryCryptoTests: XCTestCase {

    private func samplePayload(ev: Int = 3) -> SharedTransactionPayload {
        SharedTransactionPayload(
            v: 1,
            id: "tx-sync-123",
            s: "brave-otter-2931",
            ta: 4200, pa: 4200, ms: 2100,
            c: "EUR",
            d: 1_780_000_000,
            k: "exp",
            t: "Dinner",
            cn: "Food", ce: "🍔",
            sm: "evenly",
            sn: "Sam",
            f: [.init(id: "amber-lynx-7K2D", n: "Alex", sh: 2100, pa: 0)],
            r: nil,
            ev: ev
        )
    }

    func test_roundTrip_sameKeyBothDirections() throws {
        let me = "amber-lynx-7K2D"
        let peer = "brave-otter-2931"
        let payload = samplePayload()

        // Sender encrypts (me -> peer); recipient decrypts (peer -> me).
        let cipher = try SyncDeliveryCrypto.encrypt(payload, myID: me, peerID: peer)
        let decoded = try SyncDeliveryCrypto.decrypt(base64: cipher, myID: peer, peerID: me)

        XCTAssertEqual(decoded, payload)
        XCTAssertEqual(decoded.ev, 3)
    }

    func test_keyIsOrderIndependent() {
        let a = SyncDeliveryCrypto.deriveKey("zeta-9", "alpha-1")
        let b = SyncDeliveryCrypto.deriveKey("alpha-1", "zeta-9")
        XCTAssertEqual(a, b, "sorted-pair derivation must be order-independent")
    }

    func test_wrongPeerCannotDecrypt() throws {
        let me = "amber-lynx-7K2D"
        let peer = "brave-otter-2931"
        let stranger = "wily-fox-0000"
        let cipher = try SyncDeliveryCrypto.encrypt(samplePayload(), myID: me, peerID: peer)

        // A stranger's key must NOT authenticate the ciphertext.
        XCTAssertNil(SyncDeliveryCrypto.tryDecrypt(base64: cipher, myID: me, candidatePeerID: stranger))
        // The real peer's key does.
        XCTAssertNotNil(SyncDeliveryCrypto.tryDecrypt(base64: cipher, myID: me, candidatePeerID: peer))
    }

    func test_decrypt_rejectsGarbageBase64() {
        XCTAssertThrowsError(
            try SyncDeliveryCrypto.decrypt(base64: "%%%not-base64%%%", myID: "a", peerID: "b")
        )
    }

    // MARK: - Pairing handshake (the sharer→recipient connection fix)

    func test_handshake_roundTrip() throws {
        // Recipient encrypts with (sharerID, the phantom id the sharer gave them).
        let sharerID = "brave-otter-2931"
        let phantomID = "amber-lynx-7K2D"   // the id the sharer assigned the recipient
        let recipientRealID = "swift-puma-5F3A"
        let h = SyncDeliveryCrypto.PairHandshake(rid: recipientRealID, n: "Sam")

        let cipher = try SyncDeliveryCrypto.encryptHandshake(h, keyA: sharerID, keyB: phantomID)

        // Sharer recovers it by trying its own id + the friend's (phantom) id.
        let recovered = SyncDeliveryCrypto.tryDecryptHandshake(base64: cipher, keyA: sharerID, keyB: phantomID)
        XCTAssertEqual(recovered, h)
        XCTAssertEqual(recovered?.rid, recipientRealID)
    }

    func test_handshake_sharerRecoversByTryingFriendIDs() throws {
        // Models the real pull path: the sharer doesn't know which friend it
        // is, so it tries each friend id as keyB until one opens.
        let sharerID = "brave-otter-2931"
        let realPhantom = "amber-lynx-7K2D"
        let cipher = try SyncDeliveryCrypto.encryptHandshake(
            .init(rid: "swift-puma-5F3A", n: nil), keyA: sharerID, keyB: realPhantom
        )
        let friendIDs = ["wrong-1", "wrong-2", realPhantom, "wrong-3"]
        var matched: SyncDeliveryCrypto.PairHandshake?
        for fid in friendIDs {
            if let h = SyncDeliveryCrypto.tryDecryptHandshake(base64: cipher, keyA: sharerID, keyB: fid) {
                matched = h; break
            }
        }
        XCTAssertEqual(matched?.rid, "swift-puma-5F3A", "only the real phantom id should authenticate")
    }

    func test_handshake_wrongPhantomFails() throws {
        let cipher = try SyncDeliveryCrypto.encryptHandshake(
            .init(rid: "real-id", n: nil), keyA: "sharer-1", keyB: "phantom-1"
        )
        XCTAssertNil(SyncDeliveryCrypto.tryDecryptHandshake(base64: cipher, keyA: "sharer-1", keyB: "phantom-2"))
    }
}

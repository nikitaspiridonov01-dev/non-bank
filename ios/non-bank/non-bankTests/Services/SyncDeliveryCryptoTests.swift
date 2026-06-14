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
}

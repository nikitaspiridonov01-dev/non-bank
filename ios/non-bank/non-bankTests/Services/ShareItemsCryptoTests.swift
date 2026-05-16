import XCTest
@testable import non_bank

/// Tests for `ShareItemsCrypto` — the E2E encryption that protects
/// receipt items in transit through the Cloudflare-D1 share-items
/// store. The contract:
///
///   - Round-trip through encrypt → decrypt yields identical items
///   - The same plaintext + same URL payload encrypts to DIFFERENT
///     ciphertexts on every call (random nonce), but both decrypt
///     correctly
///   - Decrypting with the wrong URL payload throws (server-stored
///     ciphertexts can't be decrypted by anyone without the URL)
///   - Tampering with the ciphertext throws (GCM auth tag rejects)
final class ShareItemsCryptoTests: XCTestCase {

    private func makeItem(name: String, total: Double, assignees: [String] = []) -> ReceiptItem {
        ReceiptItem(
            name: name,
            quantity: 1,
            price: total,
            total: total,
            assignedParticipantIDs: assignees
        )
    }

    private func sampleItems() -> [ReceiptItem] {
        [
            makeItem(name: "Pizza", total: 12.50, assignees: ["__me__"]),
            makeItem(name: "Beer", total: 5.00, assignees: ["friend-id-1"]),
            makeItem(name: "Tip", total: 2.50, assignees: []),
        ]
    }

    // MARK: - Round-trip

    func testRoundTrip_preservesItems() throws {
        let original = sampleItems()
        let ciphertext = try ShareItemsCrypto.encryptItems(original, urlPayload: "abc.def")
        let decrypted = try ShareItemsCrypto.decryptItems(base64: ciphertext, urlPayload: "abc.def")

        XCTAssertEqual(decrypted.count, original.count)
        for (got, want) in zip(decrypted, original) {
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.quantity, want.quantity)
            XCTAssertEqual(got.price, want.price)
            XCTAssertEqual(got.total, want.total)
            XCTAssertEqual(got.assignedParticipantIDs, want.assignedParticipantIDs)
        }
    }

    func testRoundTrip_handlesUnicodeAndEmoji() throws {
        let original = [
            makeItem(name: "🍕 Маргарита", total: 1500),
            makeItem(name: "Šljivovica & espresso", total: 850),
        ]
        let ciphertext = try ShareItemsCrypto.encryptItems(original, urlPayload: "p")
        let decrypted = try ShareItemsCrypto.decryptItems(base64: ciphertext, urlPayload: "p")
        XCTAssertEqual(decrypted.map(\.name), original.map(\.name))
    }

    func testRoundTrip_handlesEmptyItems() throws {
        let ciphertext = try ShareItemsCrypto.encryptItems([], urlPayload: "p")
        let decrypted = try ShareItemsCrypto.decryptItems(base64: ciphertext, urlPayload: "p")
        XCTAssertEqual(decrypted, [])
    }

    // MARK: - Determinism / non-determinism

    func testEncryption_differentCiphertextEachTime() throws {
        // AES-GCM uses a random nonce per encryption — two encrypts of
        // the same plaintext under the same key must produce DIFFERENT
        // ciphertexts. Otherwise a passive observer could detect
        // re-shares of the same TX by ciphertext equality.
        let items = sampleItems()
        let c1 = try ShareItemsCrypto.encryptItems(items, urlPayload: "abc")
        let c2 = try ShareItemsCrypto.encryptItems(items, urlPayload: "abc")
        XCTAssertNotEqual(c1, c2, "Re-encrypting the same items must produce a different ciphertext")
        // …but both decrypt to the same plaintext.
        let d1 = try ShareItemsCrypto.decryptItems(base64: c1, urlPayload: "abc")
        let d2 = try ShareItemsCrypto.decryptItems(base64: c2, urlPayload: "abc")
        XCTAssertEqual(d1.map(\.name), d2.map(\.name))
    }

    func testKeyDerivation_sameInputSameKey() {
        // HKDF derivation must be deterministic — recipient on a
        // different device with the same URL payload must produce the
        // same key. Compare via encryption-then-decryption rather than
        // raw key bytes (CryptoKit hides the bytes by design).
        let items = sampleItems()
        let ciphertext = try! ShareItemsCrypto.encryptItems(items, urlPayload: "shared-url")
        // Round-trip on a DIFFERENT "device" (separate calls, same
        // input string) must still succeed.
        let decrypted = try! ShareItemsCrypto.decryptItems(base64: ciphertext, urlPayload: "shared-url")
        XCTAssertEqual(decrypted.count, items.count)
    }

    // MARK: - Security properties

    func testDecryption_failsUnderWrongURLPayload() {
        // The whole point of the URL-derived key: a ciphertext
        // exfiltrated from D1 must NOT be decryptable without the URL.
        // Swap the URL payload between encrypt and decrypt → AES-GCM's
        // auth tag rejects.
        let items = sampleItems()
        let ciphertext = try! ShareItemsCrypto.encryptItems(items, urlPayload: "original-url-payload")
        XCTAssertThrowsError(
            try ShareItemsCrypto.decryptItems(base64: ciphertext, urlPayload: "wrong-url-payload")
        )
    }

    func testDecryption_failsOnTamperedCiphertext() {
        // GCM auth tag protects integrity. Flipping a byte mid-string
        // (after the nonce, in the ciphertext or tag region) must throw.
        let items = sampleItems()
        let ciphertext = try! ShareItemsCrypto.encryptItems(items, urlPayload: "p")
        // The ciphertext is base64 of (nonce || data || tag). Mutating
        // a byte in the middle reliably hits the data/tag region.
        var bytes = Data(base64Encoded: ciphertext)!
        let midIndex = bytes.count / 2
        bytes[midIndex] = bytes[midIndex] &+ 1
        let tampered = bytes.base64EncodedString()
        XCTAssertThrowsError(
            try ShareItemsCrypto.decryptItems(base64: tampered, urlPayload: "p")
        )
    }

    func testDecryption_failsOnInvalidBase64() {
        XCTAssertThrowsError(
            try ShareItemsCrypto.decryptItems(base64: "not!valid!base64!", urlPayload: "p")
        )
    }

    // MARK: - Wire-format size (compactness sanity)

    func testCiphertextSize_underServerCap_forTypicalReceipt() throws {
        // 30 items is a generous upper bound for a real-world receipt
        // (Wolt order summaries top out around 15–20). Ciphertext +
        // base64 inflation must comfortably fit the server's 10 KB
        // payload cap.
        let items = (0..<30).map { i in
            makeItem(name: "Item \(i) — coffee + pastry", total: 4.50 + Double(i))
        }
        let ciphertext = try ShareItemsCrypto.encryptItems(items, urlPayload: "url")
        XCTAssertLessThan(
            ciphertext.utf8.count, 10_000,
            "Encrypted bundle must fit under the server's 10 KB cap"
        )
    }
}

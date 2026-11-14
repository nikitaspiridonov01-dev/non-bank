import XCTest
import UIKit
@testable import non_bank

/// A receipt that fits one frame whose items don't add up to its printed
/// total is read once more by a different model; the second read is taken
/// only when it adds up to the same total.
final class HybridReceiptParserSecondReadTests: XCTestCase {

    // MARK: - When the second read replaces the first

    private func item(_ name: String, _ total: Double) -> ReceiptItem {
        ReceiptItem(name: name, quantity: 1, price: total, total: total)
    }

    private func result(_ totals: [Double], total: Double?) -> HybridReceiptParser.Result {
        HybridReceiptParser.Result(
            parsedReceipt: ParsedReceipt(
                storeName: nil, date: nil,
                items: totals.enumerated().map { item("Item \($0.offset)", $0.element) },
                totalAmount: total, currency: "RSD"
            ),
            confidence: .medium, totalsMatch: false,
            source: .cloud(provider: "test"), attemptedProvidersCount: 1
        )
    }

    /// The first read missed the 89.99 line; the second has it and adds up.
    func testSecondReadSettles_whenItAddsUpToTheSameTotal() {
        let first = result([149.99, 179.99], total: 419.97)
        let second = result([149.99, 89.99, 179.99], total: 419.97)
        XCTAssertTrue(HybridReceiptParser.secondReadSettles(second, first: first))
    }

    func testSecondReadDoesNotSettle_whenItIsOffToo() {
        let first = result([149.99, 179.99], total: 419.97)
        XCTAssertFalse(HybridReceiptParser.secondReadSettles(result([149.99, 99.99, 179.99], total: 419.97), first: first))
        XCTAssertFalse(HybridReceiptParser.secondReadSettles(result([], total: 419.97), first: first))
    }

    /// Tax added under the subtotal: the first read has the items (42.50)
    /// and the total paid (46.01). A second read that "adds up" by taking
    /// the subtotal for the total would put the wrong amount on the
    /// transaction — it isn't taken.
    func testSecondReadDoesNotSettle_whenItReadsAnotherTotal() {
        let first = result([30, 12.50], total: 46.01)
        XCTAssertFalse(HybridReceiptParser.secondReadSettles(result([30, 12.50], total: 42.50), first: first))
        XCTAssertFalse(HybridReceiptParser.secondReadSettles(result([30, 12.50], total: nil), first: first))
    }

    // MARK: - The whole path, against a stubbed backend

    /// Plain white, not tall, no text: nothing to turn, tile or frame, so
    /// the parse is the whole-image read (and the second read, if any).
    private func photo() -> UIImage {
        let size = CGSize(width: 600, height: 800)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    private func response(provider: String, items: [(String, Double)], total: Double) -> Data {
        let lines: [[String: Any]] = items.map { ["name": $0.0, "quantity": 1, "price": $0.1, "total": $0.1] }
        let receipt: [String: Any] = [
            "storeName": "Maxi",
            "items": lines,
            "totalAmount": total,
            "currency": "RSD",
        ]
        let json: [String: Any] = [
            "receipt": receipt,
            "provider": provider,
            "pool_remaining": 500,
            "pool_low": false,
            "attempted_providers_count": 1,
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func parse(
        _ responses: [Data],
        isWholeReceipt: Bool = true
    ) async throws -> (result: HybridReceiptParser.Result, requests: [String]) {
        StubBackend.reset(responses)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubBackend.self]
        let parser = HybridReceiptParser(
            cloud: CloudReceiptParser(session: URLSession(configuration: configuration), deviceID: "test-device")
        )
        let config = HybridReceiptParser.CloudParseConfig(
            backendURL: URL(string: "https://backend.test")!, categories: [], localeIdentifier: "sr_RS"
        )
        let result = try await parser.parse(image: photo(), cloudConfig: config, isWholeReceipt: isWholeReceipt)
        return (result, StubBackend.requests())
    }

    private let short = [("Mleko 1L", 149.99), ("Jogurt 1kg", 179.99)]
    private let full = [("Mleko 1L", 149.99), ("Hleb beli", 89.99), ("Jogurt 1kg", 179.99)]

    /// The first model misses a line; the second, asked without the first,
    /// reads all three and they add up: its read is the result.
    func testShortReceiptThatDoesNotAddUpIsReadAgainByAnotherModel() async throws {
        let (result, requests) = try await parse([
            response(provider: "gemini", items: short, total: 419.97),
            response(provider: "mistral", items: full, total: 419.97),
        ])
        XCTAssertEqual(result.parsedReceipt.items.map(\.name), ["Mleko 1L", "Hleb beli", "Jogurt 1kg"])
        XCTAssertTrue(result.totalsMatch)
        XCTAssertEqual(result.source, .cloud(provider: "mistral"))
        XCTAssertEqual(result.reconciliationPasses, 2)
        XCTAssertEqual(requests.count, 2)
        XCTAssertFalse(requests[0].contains("name=\"exclude_provider\""))
        XCTAssertTrue(requests[1].contains("name=\"exclude_provider\"\r\n\r\ngemini\r\n"))
    }

    func testReceiptThatAddsUpIsReadOnce() async throws {
        let (result, requests) = try await parse([response(provider: "gemini", items: full, total: 419.97)])
        XCTAssertEqual(result.parsedReceipt.items.count, 3)
        XCTAssertEqual(result.reconciliationPasses, 1)
        XCTAssertEqual(requests.count, 1)
    }

    /// The second read is off as well: the first stands, mismatch and all.
    func testFirstReadStandsWhenTheSecondDoesNotAddUpEither() async throws {
        let (result, requests) = try await parse([
            response(provider: "gemini", items: short, total: 419.97),
            response(provider: "mistral", items: [("Mleko 1L", 149.99), ("Hleb beli", 99.99), ("Jogurt 1kg", 179.99)], total: 419.97),
        ])
        XCTAssertEqual(result.parsedReceipt.items.map(\.name), ["Mleko 1L", "Jogurt 1kg"])
        XCTAssertFalse(result.totalsMatch)
        XCTAssertEqual(result.source, .cloud(provider: "gemini"))
        XCTAssertEqual(result.reconciliationPasses, 2)
        XCTAssertEqual(requests.count, 2)
    }

    /// The second request fails (no model free): the first read is kept.
    func testFirstReadStandsWhenTheSecondRequestFails() async throws {
        let (result, requests) = try await parse([response(provider: "gemini", items: short, total: 419.97)])
        XCTAssertEqual(result.parsedReceipt.items.count, 2)
        XCTAssertEqual(result.source, .cloud(provider: "gemini"))
        XCTAssertEqual(requests.count, 2)
    }

    /// One photo of several: the total isn't this photo's to add up to,
    /// so nothing is read twice.
    func testOnePhotoOfSeveralIsNotReadAgain() async throws {
        let (result, requests) = try await parse(
            [response(provider: "gemini", items: short, total: 419.97)], isWholeReceipt: false)
        XCTAssertEqual(result.parsedReceipt.items.count, 2)
        XCTAssertEqual(requests.count, 1)
    }
}

/// Answers each request with the next queued response (503 once they run
/// out) and keeps the request bodies.
private final class StubBackend: URLProtocol {
    private static let lock = NSLock()
    private static var queued: [Data] = []
    private static var bodies: [String] = []

    static func reset(_ responses: [Data]) {
        lock.lock(); defer { lock.unlock() }
        queued = responses
        bodies = []
    }

    static func requests() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // A URLSession hands the body over as a stream. The JPEG bytes in
        // it aren't text; the form fields around them are.
        let text = String(decoding: Self.bodyData(of: request), as: UTF8.self)
        Self.lock.lock()
        Self.bodies.append(text)
        let data = Self.queued.isEmpty ? nil : Self.queued.removeFirst()
        Self.lock.unlock()

        let response = HTTPURLResponse(
            url: request.url!, statusCode: data == nil ? 503 : 200, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data ?? Data("{\"error\":\"all_providers_unavailable\"}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

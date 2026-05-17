import UIKit

/// Tier-0 receipt parser: uploads the image to the project's Cloudflare
/// Worker which routes across 4 free vision-LLM providers (Gemini, Groq,
/// Cloudflare Workers AI, OpenRouter). Returns the same `ParsedReceipt`
/// shape as the on-device tiers so `HybridReceiptParser` can treat the
/// path uniformly.
///
/// Pre-upload pipeline (matters for cost & privacy):
///   1. Bake CGImage → strips EXIF (location, timestamp, device info)
///   2. Downscale long edge to 2048 px → cuts payload ~10×
///   3. JPEG re-encode at quality 0.85, retry at 0.6 if >3 MB
actor CloudReceiptParser {

    enum Error: LocalizedError {
        case notConfigured
        case imageEncodingFailed
        case network(Swift.Error)
        case badStatus(Int, String)
        case allProvidersUnavailable(attempts: [String])
        case deviceRateLimited(resetAt: Date)
        case decodingFailed(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured:
                return "Cloud parsing is disabled or backend URL is not set."
            case .imageEncodingFailed:
                return "Could not prepare the receipt image for upload."
            case .network(let err):
                return "Network error: \(err.localizedDescription)"
            case .badStatus(let code, let body):
                return "Backend returned \(code): \(body.prefix(200))"
            case .allProvidersUnavailable(let attempts):
                if attempts.isEmpty {
                    return "All cloud providers are temporarily unavailable. Falling back to local OCR."
                }
                return "All providers failed:\n" + attempts.joined(separator: "\n")
            case .deviceRateLimited(let reset):
                let formatter = DateFormatter()
                formatter.timeStyle = .short
                return "Daily cloud limit reached. Resets at \(formatter.string(from: reset))."
            case .decodingFailed(let detail):
                return "Could not decode response: \(detail)"
            }
        }
    }

    struct Result: Sendable {
        let receipt: ParsedReceipt
        let provider: String  // "gemini" | "groq" | "cloudflare" | "openrouter"
        let poolRemaining: Int
        let poolLow: Bool
    }

    private let session: URLSession
    /// Captures iOS-side device id + categories + locale at construction so
    /// the actor doesn't have to hop to the main actor mid-parse.
    private let deviceID: String

    init(session: URLSession = .shared, deviceID: String? = nil) {
        self.session = session
        self.deviceID = deviceID ?? UserIDService.currentID()
    }

    /// Posts the image to the Worker. `categories` is a hint for the LLM —
    /// pass the user's full category list so the model can pick a match for
    /// `suggestedCategory`. `localeIdentifier` (e.g. `Locale.current.identifier`)
    /// disambiguates currency on receipts where the symbol is ambiguous.
    func parse(
        image: UIImage,
        backendURL: URL,
        categories: [(name: String, emoji: String?)],
        localeIdentifier: String?
    ) async throws -> Result {
        let endpoint = backendURL.appendingPathComponent("v1/parse-receipt")
        let imageData = try Self.prepareImage(image)
        let boundary = "----nonbank-\(UUID().uuidString)"

        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 30
        req.httpBody = Self.buildMultipartBody(
            boundary: boundary,
            imageData: imageData,
            deviceID: deviceID,
            categories: categories,
            localeIdentifier: localeIdentifier
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: req)
        } catch {
            throw Error.network(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw Error.badStatus(0, "non-HTTP response")
        }

        // 503 = router exhausted all providers → caller should fall back to
        // local OCR. We don't treat this as an unrecoverable error.
        if http.statusCode == 503 {
            let attempts = (try? JSONDecoder().decode(ServerError.self, from: data))?.attempts ?? []
            throw Error.allProvidersUnavailable(attempts: attempts.map { "\($0.provider): \($0.error.prefix(80))" })
        }
        // 429 = the daily cap was reached. Two flavours from the Worker:
        //   `device_rate_limited` — this device hit its per-device cap
        //   `ip_rate_limited`     — this network (shared NAT/WiFi or an
        //                           attacker rotating device IDs) hit
        //                           the per-IP backstop
        // Same UX either way (fall back to local OCR, surface reset
        // time), so both map to `.deviceRateLimited`.
        if http.statusCode == 429 {
            if let serverErr = try? JSONDecoder().decode(ServerError.self, from: data),
               serverErr.error == "device_rate_limited" || serverErr.error == "ip_rate_limited" {
                let reset = Date(timeIntervalSince1970: TimeInterval(serverErr.reset_at ?? 0))
                throw Error.deviceRateLimited(resetAt: reset)
            }
            throw Error.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.badStatus(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }

        do {
            let decoded = try JSONDecoder().decode(ServerResponse.self, from: data)
            return Result(
                receipt: decoded.receipt,
                provider: decoded.provider,
                poolRemaining: decoded.pool_remaining,
                poolLow: decoded.pool_low
            )
        } catch {
            throw Error.decodingFailed(error.localizedDescription)
        }
    }

    // MARK: - Image preparation

    /// Strip EXIF + downscale + JPEG re-encode. Three-tier quality
    /// curve so OCR almost always sees a sharp first-pass image:
    ///   - 0.9 quality, ≤ 4 MB ceiling — the high-quality default;
    ///     covers nearly every receipt at the 2560 px max long edge.
    ///   - 0.75 quality, ≤ 4.5 MB ceiling — graceful step-down for
    ///     unusually busy long supermarket tapes that bust 4 MB at
    ///     0.9.
    ///   - 0.55 quality — last resort before the Worker's 5 MB cap
    ///     would reject the upload outright.
    ///
    /// The earlier curve (0.85 / 0.6 / 0.5) was tuned for 2048 px
    /// and pushed too many receipts into the 0.6 fallback once the
    /// preprocessing dimension bumped to 2560 — quality 0.6 produces
    /// visibly softer text edges that hurt small-print OCR near the
    /// edges of long receipts, which is exactly the case we want
    /// the high-res path for. The new ceilings preserve the 0.9
    /// first-pass for the same percentage of receipts at 2560 that
    /// the old 0.85 curve served at 2048.
    ///
    /// In the normal flow `HybridReceiptParser.parse` has already
    /// downscaled upstream, so the helper call here is idempotent
    /// (early-returns) — kept for safety in case a future caller
    /// invokes `prepareImage` directly with a raw 12 MP photo.
    static func prepareImage(_ original: UIImage) throws -> Data {
        let downscaled = ImagePreprocessing.downscaled(original)
        // Re-rendering through UIGraphicsImageRenderer drops EXIF metadata —
        // the resulting `UIImage` has no `imageOrientation` baggage and no
        // GPS / device tags from the source.
        let baked = bake(downscaled)

        if let data = baked.jpegData(compressionQuality: 0.9), data.count <= 4_000_000 {
            return data
        }
        if let data = baked.jpegData(compressionQuality: 0.75), data.count <= 4_500_000 {
            return data
        }
        if let data = baked.jpegData(compressionQuality: 0.55) {
            return data
        }
        throw Error.imageEncodingFailed
    }

    private static func bake(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in image.draw(at: .zero) }
    }

    // MARK: - Multipart body

    private static func buildMultipartBody(
        boundary: String,
        imageData: Data,
        deviceID: String,
        categories: [(name: String, emoji: String?)],
        localeIdentifier: String?
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"
        let boundaryStart = "--\(boundary)\(crlf)"
        let boundaryEnd = "--\(boundary)--\(crlf)"

        // image part
        body.append(boundaryStart.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"image\"; filename=\"receipt.jpg\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: image/jpeg\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(imageData)
        body.append(crlf.data(using: .utf8)!)

        // device_id part
        body.append(boundaryStart.data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"device_id\"\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(deviceID.data(using: .utf8)!)
        body.append(crlf.data(using: .utf8)!)

        // categories part — JSON-encoded array
        if !categories.isEmpty {
            let payload: [[String: String]] = categories.map { c in
                var entry = ["name": c.name]
                if let emoji = c.emoji { entry["emoji"] = emoji }
                return entry
            }
            if let json = try? JSONSerialization.data(withJSONObject: payload) {
                body.append(boundaryStart.data(using: .utf8)!)
                body.append("Content-Disposition: form-data; name=\"categories\"\(crlf)".data(using: .utf8)!)
                body.append("Content-Type: application/json\(crlf)\(crlf)".data(using: .utf8)!)
                body.append(json)
                body.append(crlf.data(using: .utf8)!)
            }
        }

        // locale part
        if let locale = localeIdentifier, !locale.isEmpty {
            body.append(boundaryStart.data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"locale\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append(locale.data(using: .utf8)!)
            body.append(crlf.data(using: .utf8)!)
        }

        body.append(boundaryEnd.data(using: .utf8)!)
        return body
    }

    // MARK: - Wire types

    private struct ServerResponse: Decodable {
        let receipt: ParsedReceipt
        let provider: String
        let pool_remaining: Int
        let pool_low: Bool
    }

    private struct ServerError: Decodable {
        let error: String
        let detail: String?
        let reset_at: Int?
        let attempts: [Attempt]?
        struct Attempt: Decodable {
            let provider: String
            let error: String
        }
    }
}

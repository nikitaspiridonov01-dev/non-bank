import Foundation
import Combine

/// Production AI-receipt-scanning configuration. The Settings UI used
/// to expose a toggle + custom backend URL — that was removed for v1
/// because cloud AI is now on by default and the endpoint is fixed.
///
/// HybridReceiptParser still calls `resolvedBackendURL` /
/// `recordPoolStats` / `recordCloudError`; we keep the surface area
/// stable but the URL is hard-coded and the telemetry hooks are
/// no-ops (no UI consumes them any more).
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    /// Cloudflare Worker endpoint that brokers Gemini / Groq / Cloudflare
    /// Workers AI / OpenRouter. Single endpoint so we never have to ship
    /// a build to rotate providers — the broker picks whichever is up.
    /// Sourced from `BackendConfig.baseURL` so a host rebrand is a
    /// single-line edit in one place.
    private static var productionBackendURL: URL { BackendConfig.baseURL }

    private init() {}

    /// Always available. Cloud AI is the default scanning path; if any
    /// of the upstream providers (or the Worker itself) is down, the
    /// caller falls back to local Vision OCR — see
    /// `HybridReceiptParser` Tier 1.
    var resolvedBackendURL: URL? { Self.productionBackendURL }

    /// Kept for source compatibility with HybridReceiptParser — the
    /// Settings screen that consumed these values is gone, so we don't
    /// retain anything any more.
    func recordPoolStats(remaining: Int, low: Bool) {}
    func recordCloudError(_ message: String?) {}
}

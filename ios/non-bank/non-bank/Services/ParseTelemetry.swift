import Foundation
import Combine

/// Lightweight, privacy-safe usage counter so we (or the user via a future
/// debug screen) can answer: "is the cloud parser actually doing useful
/// work, or is OCR fallback enough most of the time?"
///
/// Stores ONLY: tier label, item count, timestamp. No image bytes, no OCR
/// text, no merchant names. Backed by `UserDefaults` to avoid a DB migration
/// for what is essentially debug telemetry. Capped at the last 200 events
/// — older entries roll off, so the dictionary stays under ~20 KB.
@MainActor
final class ParseTelemetry: ObservableObject {
    static let shared = ParseTelemetry()

    enum Tier: String, Codable {
        case cloud
        case ocrFallback
    }

    struct Event: Codable, Identifiable {
        let id: UUID
        let timestamp: Date
        let tier: Tier
        // Provider name for `cloud` tier (gemini/groq/cloudflare/openrouter),
        // nil for `ocrFallback`.
        let provider: String?
        let itemCount: Int
        let hadTotal: Bool
        let latencyMs: Int

        init(
            tier: Tier,
            provider: String? = nil,
            itemCount: Int,
            hadTotal: Bool,
            latencyMs: Int
        ) {
            self.id = UUID()
            self.timestamp = Date()
            self.tier = tier
            self.provider = provider
            self.itemCount = itemCount
            self.hadTotal = hadTotal
            self.latencyMs = latencyMs
        }
    }

    private static let storageKey = "parse.telemetry.events.v1"
    private static let cap = 200

    @Published private(set) var events: [Event] = []

    private init() {
        load()
    }

    func record(_ event: Event) {
        events.append(event)
        if events.count > Self.cap {
            events.removeFirst(events.count - Self.cap)
        }
        save()
    }

    /// `[tier label : count]` over the last `days` (default 30) — convenient
    /// for a one-line "Cloud: 42 / OCR: 8" summary in Settings.
    func usageBreakdown(days: Int = 30) -> [String: Int] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86400)
        var counts: [String: Int] = [:]
        for e in events where e.timestamp >= cutoff {
            let key = e.tier == .cloud ? (e.provider ?? "cloud") : "ocr"
            counts[key, default: 0] += 1
        }
        return counts
    }

    func clear() {
        events = []
        UserDefaults.standard.removeObject(forKey: Self.storageKey)
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey) else { return }
        events = (try? JSONDecoder().decode([Event].self, from: data)) ?? []
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}

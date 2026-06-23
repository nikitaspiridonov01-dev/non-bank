import Foundation

/// What the launch-time version check concluded the app must do.
///
///  - `.none`     — running version is fine; show nothing.
///  - `.optional` — a newer version exists; prompt but allow dismissal.
///  - `.critical` — running version is below the server's minimum; force
///    the update (no dismiss affordance).
///
/// Both prompting cases carry the resolved App Store URL so the gate view
/// can open it without re-deriving it.
enum UpdateRequirement: Equatable {
    case none
    case optional(storeURL: URL)
    case critical(storeURL: URL)
}

/// Launch-time app-update gate. GETs the Worker's static
/// `/v1/app-version` policy (`{ minVersion, latestVersion, storeUrl }`),
/// reads the running bundle version, and compares with a small numeric
/// semver comparator.
///
/// FAIL OPEN, always: any transport error, non-200, decode failure, or a
/// missing / unparseable field returns `.none`. A user is NEVER locked out
/// (or even nagged) because of an uncertain check — the gate only ever
/// acts on a clean, affirmative answer from the server.
///
/// Mirrors `ShareItemsService`'s thin-client shape (own `URLSession`,
/// `JSONDecoder`, `HTTPURLResponse` status check) so the networking idiom
/// matches the rest of the app.
@MainActor
final class AppUpdateService {

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    /// Server policy payload. All fields optional on decode so a partial /
    /// renamed response degrades to `.none` rather than throwing.
    private struct VersionPolicy: Decodable {
        let minVersion: String?
        let latestVersion: String?
        let storeUrl: String?
    }

    /// `<BackendConfig.baseURL>/v1/app-version`.
    private var endpoint: URL {
        BackendConfig.baseURL
            .appendingPathComponent("v1")
            .appendingPathComponent("app-version")
    }

    /// Fetch the policy and decide. Never throws — every failure path
    /// resolves to `.none` (fail open).
    func check() async -> UpdateRequirement {
        guard
            let current = Bundle.main
                .infoDictionary?["CFBundleShortVersionString"] as? String,
            !current.isEmpty
        else {
            return .none
        }

        let policy: VersionPolicy
        do {
            let (data, response) = try await session.data(from: endpoint)
            guard
                let http = response as? HTTPURLResponse,
                (200..<300).contains(http.statusCode)
            else {
                return .none
            }
            policy = try JSONDecoder().decode(VersionPolicy.self, from: data)
        } catch {
            return .none
        }

        // storeURL must parse to an absolute https/http(s) URL or we have
        // nothing to send the user to → fail open.
        guard
            let storeString = policy.storeUrl,
            let storeURL = URL(string: storeString),
            storeURL.scheme != nil
        else {
            return .none
        }

        // A missing / unparseable threshold is treated as "no wall" for
        // that tier rather than failing the whole check, so a server that
        // only sets `minVersion` still enforces the critical floor.
        if let min = policy.minVersion,
           Self.isVersion(current, lessThan: min) {
            return .critical(storeURL: storeURL)
        }
        if let latest = policy.latestVersion,
           Self.isVersion(current, lessThan: latest) {
            return .optional(storeURL: storeURL)
        }
        return .none
    }

    /// Small dotted-numeric semver comparator. Splits on ".", compares
    /// components numerically left-to-right; a missing component on either
    /// side counts as 0 (so "1.2" == "1.2.0", and "1.2" < "1.2.1").
    /// Non-numeric components coerce to 0, which keeps a malformed version
    /// from ever reading as "newer" and forcing an update.
    static func isVersion(_ lhs: String, lessThan rhs: String) -> Bool {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(l.count, r.count)
        for i in 0..<count {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

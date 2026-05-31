import Foundation

/// Single source of truth for the Cloudflare Worker host that backs
/// every server-side feature of the app — receipt parsing
/// (`/v1/parse-receipt`) AND the share-link HTML preview (`/share`).
///
/// ## How to rebrand to a custom domain
///
/// 1. Bind the custom domain to the Worker via Cloudflare's Custom
///    Domains panel (Workers & Pages → non-bank-receipt-proxy →
///    Settings → Triggers → Custom Domains).
/// 2. Change **one line** below — the `host` constant — to the new
///    domain. Rebuild the iOS app. That's it.
///
/// The decoder side (`SharedTransactionLink.isShareURL`) automatically
/// keeps accepting URLs at every host listed in `acceptedHosts`, so
/// share-links already circulating in messengers at the old host
/// keep opening the app. Both the current workers.dev subdomain AND
/// the planned `non-bank.app` are pre-listed there, so the switch
/// itself doesn't even need a test update.
enum BackendConfig {

    /// Hostname of the production Worker. Used by Release/TestFlight/
    /// App Store builds. Now the `non-bank.app` apex custom domain
    /// (bound in `backend/wrangler.toml`'s top-level `routes` with
    /// `custom_domain = true`) — share links read
    /// `https://non-bank.app/share?p=…`. The legacy workers.dev host
    /// stays in `acceptedHosts` below so links already circulating at
    /// the old host keep deep-linking into the app forever.
    private static let productionHost: String = "non-bank.app"

    /// Hostname of the staging Worker. Used by Debug builds (Xcode
    /// `Cmd+R` on a real device or simulator). On the
    /// `staging.non-bank.app` subdomain custom domain (bound in
    /// `wrangler.toml`'s `[env.staging]` block) so Debug builds
    /// exercise the same edge path as prod.
    private static let stagingHost: String = "staging.non-bank.app"

    /// Pre-custom-domain workers.dev hosts. Kept ONLY in
    /// `acceptedHosts` (never used as the active `host`) so any share
    /// link generated before the `non-bank.app` switch still resolves
    /// as a valid share URL and opens the app — links already
    /// circulating in messengers keep deep-linking forever. The
    /// workers.dev subdomains still serve in parallel (custom domains
    /// were additive), so these aren't dead — just no longer the
    /// hosts we *generate* links at. Safe to prune once we're
    /// confident no old-host links remain in the wild.
    private static let legacyProductionHost = "non-bank-receipt-proxy.non-bank-ai.workers.dev"
    private static let legacyStagingHost = "non-bank-receipt-proxy-staging.non-bank-ai.workers.dev"

    /// **The** active host the app talks to right now. Selected at
    /// compile time:
    ///   - Debug build (Xcode run on device) → staging
    ///   - Release / TestFlight / App Store  → production
    /// The split is a single `#if DEBUG` so there's no runtime toggle
    /// the user can accidentally flip — App Store builds are
    /// physically incapable of pointing at staging.
    static let host: String = {
        #if DEBUG
        return stagingHost
        #else
        return productionHost
        #endif
    }()

    /// Hosts the decoder treats as valid share-link backends — the
    /// current `host` plus every legacy / future host that might
    /// appear in URLs the app encounters. Always includes:
    ///   - production hostname (so Release-build users keep opening
    ///     links forever after a backend rename)
    ///   - staging hostname (so a developer running a Debug build can
    ///     receive share-links pasted from a TestFlight tester, and
    ///     vice versa)
    ///   - `non-bank.app` (pre-listed so the eventual custom-domain
    ///     switch is a one-line edit on the producer side)
    ///
    /// `Set` so duplicates between `host` and the static list collapse
    /// automatically.
    static var acceptedHosts: Set<String> {
        Set([
            host,
            productionHost,
            stagingHost,
            legacyProductionHost,
            legacyStagingHost,
        ])
    }

    /// Full `https://<host>` URL — used by `CloudReceiptParser`
    /// (which appends `/v1/parse-receipt`) and any other code path
    /// that needs the active backend's root URL.
    static var baseURL: URL {
        // Force-unwrap is fine: `host` is a controlled compile-time
        // string. If a future change makes it user-configurable,
        // route this through a throwing initialiser instead.
        URL(string: "https://\(host)")!
    }
}

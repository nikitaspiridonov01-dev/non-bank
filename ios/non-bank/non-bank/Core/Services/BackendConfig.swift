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

    /// **The** active host. Where new share-links point and where
    /// `CloudReceiptParser` POSTs receipt images. Currently the
    /// default workers.dev subdomain because the planned
    /// `non-bank.app` custom domain is still under the 10-day
    /// post-registration transfer lock as of 2026-05-16; switching
    /// is a single-line edit here once the zone has been moved to
    /// the Worker's account and bound as a Custom Domain.
    static let host: String = "non-bank-receipt-proxy.non-bank-ai.workers.dev"

    /// Hosts the decoder treats as valid share-link backends —
    /// the current `host` plus every legacy / future host that
    /// might appear in URLs the app encounters. We pre-list
    /// `non-bank.app` here so the switch-over is a one-line edit
    /// (`host` only); we keep the workers.dev subdomain here
    /// forever so old share-links in messenger history never
    /// stop opening the app.
    ///
    /// `Set` so duplicates between `host` and the static list
    /// (current state has both equal to workers.dev) collapse
    /// automatically.
    static var acceptedHosts: Set<String> {
        Set([
            host,
            "non-bank-receipt-proxy.non-bank-ai.workers.dev",
            "non-bank.app",
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

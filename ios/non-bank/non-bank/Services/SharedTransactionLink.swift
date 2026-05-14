import Foundation

// MARK: - Shared Transaction Link

/// Encoder + decoder for share-link URLs. The format is intentionally
/// boring: `https://<host>/s/?p=<base64url(JSON)>` where `<host>` is a
/// statically hosted page that ALSO carries the `apple-app-site-association`
/// file (Universal Link routes the URL into the app when installed) and a
/// rendered HTML fallback (read-only preview when not).
///
/// Both halves of this enum are pure functions — no I/O, no network, no
/// dependencies on any app singletons. That's what makes them trivially
/// unit-testable and lets Phase 4 (the receiver-side flow) plug them in
/// without bringing in extra collaborators.
enum SharedTransactionLink {

    // MARK: - Configuration

    /// Custom URL scheme for the **interim** mechanism — works without
    /// any hosting and lets us test the encoder/decoder/receiver pipeline
    /// end-to-end during development. When a real Universal Link domain
    /// goes live, the encoder will switch to `https://...` URLs but the
    /// app keeps registering this scheme so old `nonbank://` links keep
    /// opening the app.
    static let customScheme = "nonbank"

    /// Custom-scheme host segment. Pseudo-path component since custom
    /// schemes have no real hostname; we treat it as the "share" route.
    static let customSchemeHost = "share"

    /// Universal Link host (the GitHub Pages site that hosts the
    /// `apple-app-site-association` file). Tied to the entitlements:
    /// `applinks:nikitaspiridonov01-dev.github.io`. Pointing at a real
    /// host means iOS Safari resolves the link by:
    ///   1. Loading `https://<host>/.well-known/apple-app-site-association`
    ///   2. Confirming our `appIDs` whitelist contains
    ///      `28PGV25T47.nikitaspiridonov.non-bank`
    ///   3. Routing `https://<host>/transaction/...` URLs straight into
    ///      the app via `onContinueUserActivity` / `onOpenURL`.
    /// When the app isn't installed Safari just loads the page at the URL
    /// — that page is a tiny App Store redirect (see Phase 5 plan).
    static let universalLinkHost = "nikitaspiridonov01-dev.github.io"

    /// Path component for universal-link share URLs. Matched in the AASA
    /// file as `/transaction/*` so iOS only intercepts share routes —
    /// any other future page on the same domain stays in Safari.
    static let universalLinkPath = "/transaction/"

    /// Cloudflare Worker host that serves the `/share` HTML preview for
    /// recipients without the iOS app installed. Same Worker that hosts
    /// `/v1/parse-receipt` etc. — see `backend/src/share.ts`. Update
    /// this if you ever migrate to a custom domain; for now it points
    /// at the deployed `*.workers.dev` subdomain.
    static let webBackendHost = "non-bank-receipt-proxy.non-bank-ai.workers.dev"

    /// Path on the Worker. Lives at the root (not under `/v1/`) because
    /// it's the user-facing share URL — short and brand-clean reads
    /// better in iMessage previews than `…/v1/share?p=…`.
    static let webBackendPath = "/share"

    /// Query parameter name carrying the base64url payload.
    static let payloadKey = "p"

    /// Schema version emitted by the encoder.
    static let currentSchemaVersion: Int = 1

    /// Current default URL scheme used by `encode(...)`. Switched between
    /// `.customScheme` (works with a free Apple ID — the `nonbank://`
    /// scheme is registered in Info.plist and routes through SwiftUI's
    /// `onOpenURL`) and `.universalLink` (production — opens the app
    /// from anywhere via AASA, but requires the paid Apple Developer
    /// Program for the Associated Domains entitlement).
    ///
    /// Currently `.webBackend` — the Worker renders an HTML preview for
    /// recipients without the iOS app, AND the page deep-links to
    /// `nonbank://share?p=…` for those who have the app. Best of both:
    /// shareable in any messenger, opens in-app for installed users.
    ///
    /// Other styles still work via the decoder (any old `nonbank://`
    /// link keeps opening the app on `onOpenURL`):
    ///   • `.customScheme` — only useful if the receiver definitely
    ///     has the app and you want to skip the web hop.
    ///   • `.universalLink` — Phase-2 path once Associated Domains
    ///     entitlement is wired up (paid dev account required).
    static var defaultURLStyle: URLStyle = .webBackend

    enum URLStyle {
        /// `nonbank://share?p=…` — works as soon as the app is installed.
        /// Doesn't gracefully fall back to App Store on iOS Safari, but
        /// it doesn't depend on any external hosting either.
        case customScheme
        /// `https://share.nonbank.app/s/?p=…` — requires the
        /// `apple-app-site-association` file on the host. Falls back to
        /// the host's web page when the app isn't installed (which we'll
        /// configure to redirect to App Store).
        case universalLink
        /// `https://<worker-host>/share?p=…` — the Cloudflare Worker
        /// renders a server-side HTML preview, and the page tries to
        /// hand off to `nonbank://share?p=…` on tap. Works in every
        /// browser, on any platform, even when the app isn't installed.
        /// No Associated Domains entitlement needed (the receiver
        /// browser opens the URL directly; the app is invoked
        /// secondarily via the in-page deep-link button).
        case webBackend
    }

    // MARK: - Encode

    /// Build a share-link URL from a split transaction.
    ///
    /// - Parameter friends: lookup table for FriendShare → display name
    ///   resolution. Pass the union of FriendStore (current friends) and
    ///   any historical friends still referenced by this transaction.
    /// - Parameter category: the `Category` record matching
    ///   `transaction.category` — resolved by the caller because the
    ///   encoder is intentionally store-agnostic.
    static func encode(
        transaction: Transaction,
        sharerID: String,
        sharerName: String?,
        friends: [Friend],
        category: Category,
        repeatInterval: RepeatInterval? = nil,
        style: URLStyle = defaultURLStyle
    ) throws -> URL {
        guard let split = transaction.splitInfo else {
            throw SharedTransactionError.notASplitTransaction
        }

        let friendsByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })

        let participants: [SharedTransactionPayload.Participant] = split.friends.map { share in
            // Fall back to the raw ID when we don't have a friend record.
            // Better than throwing — receivers can rename later, and
            // throwing on legacy data would block the share entirely.
            let displayName = friendsByID[share.friendID]?.name ?? share.friendID
            return SharedTransactionPayload.Participant(
                id: share.friendID,
                n: displayName,
                sh: share.share,
                pa: share.paidAmount
            )
        }

        // Resolve the recurring rule. Prefer the explicit param (caller
        // walked the parent reminder for child-occurrence transactions),
        // fall back to whatever's on the transaction itself for the
        // standalone case (parent reminder shared directly, or non-
        // recurring transaction). `nil` overall → the receiver gets a
        // non-recurring import, which is the safe degradation.
        let resolvedInterval = repeatInterval ?? transaction.repeatInterval
        let recurring = resolvedInterval.flatMap(SharedRecurring.init(from:))

        let payload = SharedTransactionPayload(
            v: currentSchemaVersion,
            id: transaction.syncID,
            s: sharerID,
            ta: split.totalAmount,
            pa: split.paidByMe,
            ms: split.myShare,
            c: transaction.currency,
            d: transaction.date.timeIntervalSince1970,
            k: transaction.type == .income ? "inc" : "exp",
            t: transaction.title,
            cn: category.title,
            ce: category.emoji,
            sm: split.splitMode?.rawValue,
            sn: sharerName,
            f: participants,
            r: recurring
        )

        return try buildURL(payload: payload, style: style)
    }

    /// Lower-level helper: encode a payload object directly into a URL.
    /// Useful for tests and for re-encoding a previously-decoded payload
    /// (e.g. when re-sharing).
    static func buildURL(payload: SharedTransactionPayload, style: URLStyle = defaultURLStyle) throws -> URL {
        let encoder = JSONEncoder()
        // `.sortedKeys` keeps the link byte-stable for the same input —
        // important for the checksum semantics: re-encoding never
        // accidentally produces a different link for the same data.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        let base64url = base64URLEncode(data)

        var components = URLComponents()
        switch style {
        case .customScheme:
            components.scheme = customScheme
            components.host = customSchemeHost
        case .universalLink:
            components.scheme = "https"
            components.host = universalLinkHost
            components.path = universalLinkPath
        case .webBackend:
            components.scheme = "https"
            components.host = webBackendHost
            components.path = webBackendPath
        }
        components.queryItems = [URLQueryItem(name: payloadKey, value: base64url)]
        guard let url = components.url else {
            // URLComponents only fails URL construction on malformed
            // host/path inputs, which our static config can't produce —
            // but throwing is safer than force-unwrapping in case the
            // host string is ever made user-configurable.
            throw SharedTransactionError.invalidEncoding
        }
        return url
    }

    // MARK: - Decode

    /// Parse a share-link URL into a payload. Throws on malformed input
    /// (corrupted base64, broken JSON, unknown schema version).
    ///
    /// Whitelists the schema version so a v2 link to a v1 app doesn't
    /// silently drop fields — callers see `unsupportedVersion(2)` and can
    /// prompt the user to update.
    ///
    /// Accepts both `nonbank://share?p=…` (interim custom scheme) and
    /// `https://share.nonbank.app/s/?p=…` (Universal Link, once hosting
    /// is set up). Decoder is scheme-agnostic — it only looks for `?p=…`.
    static func decode(url: URL) throws -> SharedTransactionPayload {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let queryItems = components.queryItems,
            let payloadValue = queryItems.first(where: { $0.name == payloadKey })?.value,
            !payloadValue.isEmpty
        else {
            throw SharedTransactionError.missingPayload
        }

        guard let data = base64URLDecode(payloadValue) else {
            throw SharedTransactionError.invalidEncoding
        }

        let payload: SharedTransactionPayload
        do {
            payload = try JSONDecoder().decode(SharedTransactionPayload.self, from: data)
        } catch {
            throw SharedTransactionError.malformedPayload(underlying: error)
        }

        guard payload.v == currentSchemaVersion else {
            throw SharedTransactionError.unsupportedVersion(payload.v)
        }
        return payload
    }

    /// Quick "is this a share link we should attempt to decode?" check —
    /// used by the SwiftUI `onOpenURL` handler to filter out other deep
    /// links the app might receive in future. Pure URL inspection, no
    /// payload parsing.
    static func isShareURL(_ url: URL) -> Bool {
        // Custom scheme: `nonbank://share?p=…`
        if url.scheme == customScheme && url.host == customSchemeHost {
            return true
        }
        // Universal Link: `https://<universalLinkHost>/transaction/…`
        if url.scheme == "https" && url.host == universalLinkHost {
            return true
        }
        // Web backend: `https://<workerHost>/share?p=…`. Path-scoped so
        // a future `/v1/health` (or any other Worker route) doesn't get
        // misclassified as a share link if it ever lands in onOpenURL.
        if url.scheme == "https" && url.host == webBackendHost && url.path == webBackendPath {
            return true
        }
        return false
    }

    // MARK: - Base64URL helpers

    /// Standard base64 uses `+`, `/`, and `=` — all of which need URL
    /// encoding when stuffed into a query string. Base64url replaces
    /// `+` → `-`, `/` → `_` and drops the trailing `=` padding entirely.
    /// Result: a string that survives copy/paste into iMessage and never
    /// gets URL-encoded into something a human can't recognise as a link.
    static func base64URLEncode(_ data: Data) -> String {
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// Reverse of `base64URLEncode`. Re-pads with `=` so Apple's standard
    /// base64 decoder accepts the input — the spec lets us drop padding
    /// on the wire but the decoder doesn't infer it.
    static func base64URLDecode(_ string: String) -> Data? {
        var s = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad up to a multiple of 4 chars — base64 alignment requirement.
        let remainder = s.count % 4
        if remainder > 0 {
            s.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: s)
    }
}

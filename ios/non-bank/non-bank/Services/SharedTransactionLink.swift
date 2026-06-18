import Foundation

// MARK: - Shared Transaction Link

/// Encoder + decoder for share-link URLs.
///
/// ## What's actually live (active production path)
///
/// `.webBackend` style → `https://<cloudflare-worker-host>/share?p=<base64url(JSON)>`.
/// The Worker (`backend/src/share.ts`) renders an HTML preview for
/// recipients without the app; its inline JS auto-redirects to
/// `nonbank://share?p=…` (custom URL scheme, registered in `Info.plist`)
/// so installed apps open directly via `onOpenURL`.
///
/// ## What's NOT live (dormant configuration)
///
/// `.universalLink` style is wired through the encoder/decoder so the
/// machinery is unit-tested, BUT it has never been the default and
/// is currently unreachable in practice for two compounding reasons:
///   1. `non-bank.entitlements` does NOT include
///      `com.apple.developer.associated-domains` — Apple's free
///      Personal Team provisioning rejects that entitlement (see the
///      commented block in the entitlements file). Without it, iOS
///      doesn't even attempt Universal-Link resolution.
///   2. `defaultURLStyle` is `.webBackend`, so every URL the app
///      emits points at the Cloudflare Worker host, not at the
///      Universal-Link host below.
///
/// The legacy AASA file at `https://nikitaspiridonov01-dev.github.io/
/// .well-known/apple-app-site-association` is real and serves the
/// right JSON — it's just inert until both conditions above flip.
/// Activation steps when ready:
///   • Pay the Apple Developer Program (~$99/yr)
///   • Uncomment the `associated-domains` block in
///     `non-bank.entitlements` and replace the host with the live one
///   • Host an AASA file at `https://<host>/.well-known/apple-app-site-association`
///     (the Cloudflare Worker can serve this directly — preferred
///     over GitHub Pages for parity with a custom domain)
///   • Flip `defaultURLStyle = .universalLink`
///
/// ## Why keep the dormant code at all
///
/// Both halves of the enum are pure functions — no I/O, no network,
/// no app singletons — so the encode/decode mechanism for
/// `.universalLink` costs nothing to keep tested. When we eventually
/// activate it the only changes are the entitlement, the host string,
/// and the `defaultURLStyle` flip.
enum SharedTransactionLink {

    // MARK: - Configuration

    /// Custom URL scheme registered in `Info.plist`. This is what the
    /// in-page JS on the Cloudflare share preview ultimately invokes
    /// (`window.location.href = "nonbank://share?p=…"`) to hand off
    /// from Safari into the installed app. Also a valid value for
    /// `URLStyle.customScheme` when you want to generate a deep-link
    /// directly (e.g. from an in-app share sheet target that knows
    /// the recipient has the app).
    static let customScheme = "nonbank"

    /// Custom-scheme host segment. Pseudo-path component since custom
    /// schemes have no real hostname; we treat it as the "share" route.
    static let customSchemeHost = "share"

    /// **DORMANT** — Host the encoder would target if `URLStyle`
    /// were `.universalLink`. Currently a legacy GitHub Pages site
    /// hosting the AASA file from an earlier setup; iOS never queries
    /// it because the active path is `.webBackend` AND the
    /// Associated-Domains entitlement is disabled. Kept as the
    /// placeholder value so the existing unit tests for the
    /// `.universalLink` encode path stay green; replace with the
    /// live domain when Universal Links are activated (see the
    /// top-of-file activation checklist).
    static let universalLinkHost = "nikitaspiridonov01-dev.github.io"

    /// Path component for Universal-Link share URLs. The AASA file
    /// at `universalLinkHost` matches `/transaction/*` so iOS only
    /// intercepts share routes — any other page on the same host
    /// stays in Safari. Unused until `.universalLink` becomes the
    /// active style.
    static let universalLinkPath = "/transaction/"

    /// **ACTIVE** — Cloudflare Worker host serving the `/share` HTML
    /// preview and (separately) the `/v1/parse-receipt` LLM proxy.
    /// See `backend/src/share.ts`. Sourced from `BackendConfig.host`
    /// — change there to rebrand to a custom domain, not here.
    static var webBackendHost: String { BackendConfig.host }

    /// Path on the Worker. Lives at the root (not under `/v1/`) because
    /// it's the user-facing share URL — short and brand-clean reads
    /// better in iMessage previews than `…/v1/share?p=…`.
    static let webBackendPath = "/share"

    /// Query parameter name carrying the base64url payload.
    static let payloadKey = "p"

    /// Schema version emitted by the encoder.
    static let currentSchemaVersion: Int = 1

    /// Active URL scheme used by `encode(...)`. Set to `.webBackend`
    /// in production — every generated share URL points at the
    /// Cloudflare Worker, which then either renders the HTML preview
    /// or hands off to `nonbank://` for installed apps. See the
    /// top-of-file doc for what each alternative actually requires
    /// in order to be activated.
    static var defaultURLStyle: URLStyle = .webBackend

    enum URLStyle {
        /// `nonbank://share?p=…` — only useful when the receiver
        /// definitely has the app (skips the web hop). Generated
        /// directly from in-app share targets that know the recipient
        /// is an existing user; not used for outbound shares because
        /// Safari can't open the custom scheme from a link tap.
        case customScheme

        /// `https://<universalLinkHost>/transaction/?p=…` —
        /// **DORMANT** Universal-Link path. See the top-of-file
        /// activation checklist; production-blocked on the paid
        /// Apple Developer Program + `associated-domains`
        /// entitlement, which Personal Team provisioning rejects.
        case universalLink

        /// `https://<worker-host>/share?p=…` — **active** production
        /// style. Worker renders the HTML preview for recipients
        /// without the app and the in-page JS deep-links to
        /// `nonbank://share?p=…` for those who have it. Works in
        /// every browser on every platform; no Apple entitlement
        /// needed.
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
    /// Build the wire payload for a split transaction WITHOUT encoding it
    /// into a URL. Extracted from `encode` so the server-sync engine
    /// (`SyncEngine`), which needs the payload object to encrypt and
    /// deliver, reuses the exact same construction (including `ev`).
    static func buildPayload(
        transaction: Transaction,
        sharerID: String,
        sharerName: String?,
        friends: [Friend],
        category: Category,
        repeatInterval: RepeatInterval? = nil
    ) throws -> SharedTransactionPayload {
        guard let split = transaction.splitInfo else {
            throw SharedTransactionError.notASplitTransaction
        }

        let friendsByID = Dictionary(uniqueKeysWithValues: friends.map { ($0.id, $0) })

        let participants: [SharedTransactionPayload.Participant] = split.friends.map { share in
            // Fall back to the raw ID when we don't have a friend record.
            // Better than throwing — receivers can rename later, and
            // throwing on legacy data would block the share entirely.
            let displayName = friendsByID[share.friendID]?.name ?? share.friendID
            // `cn` ("connected"): is this participant a connected/real-user
            // friend on the sharer's side? Drives the recipient-identity
            // invariant in `ShareIntentClassifier` — connected participants
            // were addressed by their real userID and can never legitimately
            // be the receiver once an id-match fails, so they're excluded
            // from the picker's candidate set. A friend with no record (ad-hoc
            // participant) or an unconnected friend is a phantom → `false`.
            let isConnected = friendsByID[share.friendID]?.isConnected ?? false
            return SharedTransactionPayload.Participant(
                id: share.friendID,
                n: displayName,
                sh: share.share,
                pa: share.paidAmount,
                cn: isConnected
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

        // Pass `splitMode` through verbatim — including `.byItems`. The
        // receipt items now ride along via the encrypted share-items
        // channel (Phase 10), and the receiver mapper reconstructs the
        // full byItems display from those items (Phase 10.1). The web
        // preview also keys its split-mode label off this field, so
        // sending `"byItems"` is what makes "By items in receipt" show
        // in the preview chip. If items happen to be missing on the
        // receiver side (channel expired, sender on a pre-Phase-10
        // build, decrypt failure), `ReceivedTransactionMapper` degrades
        // `.byItems` back to `.byAmount` on its side — see the no-items
        // branch in that file.

        return SharedTransactionPayload(
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
            r: recurring,
            ev: transaction.editVersion
        )
    }

    /// Build a share-link URL from a split transaction. Thin wrapper over
    /// `buildPayload` + `buildURL`.
    static func encode(
        transaction: Transaction,
        sharerID: String,
        sharerName: String?,
        friends: [Friend],
        category: Category,
        repeatInterval: RepeatInterval? = nil,
        style: URLStyle = defaultURLStyle
    ) throws -> URL {
        let payload = try buildPayload(
            transaction: transaction,
            sharerID: sharerID,
            sharerName: sharerName,
            friends: friends,
            category: category,
            repeatInterval: repeatInterval
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
    /// Accepts every URL style the encoder can emit: `nonbank://share?p=…`
    /// (custom scheme), `https://<webBackendHost>/share?p=…` (active
    /// production path), and `https://<universalLinkHost>/transaction/?p=…`
    /// (dormant Universal-Link path — see top-of-file). Decoder is
    /// scheme-agnostic — it only looks for `?p=…`.
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
        // We accept every host in `BackendConfig.acceptedHosts` (current
        // backend + legacy hosts) so share-links already circulating
        // under an older host keep opening the app after a rebrand.
        if url.scheme == "https",
           let host = url.host,
           BackendConfig.acceptedHosts.contains(host),
           url.path == webBackendPath {
            return true
        }
        return false
    }

    // MARK: - URL inspection helpers (for the server-side items channel)

    /// Pull the raw `?p=...` query-parameter value out of a share URL,
    /// or `nil` when the URL isn't a share URL or doesn't carry one.
    /// Used by the share-items channel: this string is BOTH the key
    /// the Worker stores items under (after deriving the checksum)
    /// AND the seed for the recipient's decryption key, so we surface
    /// it as a small helper rather than duplicating the URL parsing
    /// at every callsite.
    static func urlPayloadString(of url: URL) -> String? {
        guard
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let value = components.queryItems?
                .first(where: { $0.name == payloadKey })?
                .value,
            !value.isEmpty
        else {
            return nil
        }
        return value
    }

    /// Compute the canonical payload checksum for a share URL — i.e.
    /// the same hex string `SharedTransactionPayload.checksum` would
    /// return on the original payload. Used as the `{share_id}` URL
    /// component for the server-side items store so sender + recipient
    /// agree on the storage key from the URL alone.
    static func payloadChecksum(of url: URL) throws -> String {
        try decode(url: url).checksum
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

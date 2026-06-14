import Foundation
import StoreKit
import Combine

/// StoreKit2 wrapper for the "tip the developer" consumable IAPs.
///
/// Five tip tiers with a culinary theme — each tier upgrades the meal
/// being "bought" for the dev so the upsell reads emotionally instead
/// of as a dry "$0.99 / $1.99 / $2.99 / $4.99 / $9.99" list:
///   - ☕ Coffee — $0.99
///   - 🐱 Kitten food — $1.99
///   - 🥐 Croissant — $2.99
///   - 🍕 Pizza — $4.99   ← visually highlighted as "Recommended"
///   - 🧑‍🍳 Chef's table — $9.99  ← labelled "Most generous"
///
/// All five products are `Consumable` so the user can buy any tier
/// multiple times. Receipt items don't need to be re-validated on
/// launch (we don't unlock anything in return); the only purchase
/// state we keep around is the in-memory `lastPurchasedProductID`
/// used by the UI for the "Thanks!" confirmation overlay.
@MainActor
final class TipJarService: ObservableObject {
    static let shared = TipJarService()

    /// Stable tier metadata. The `productID` strings have to match the
    /// `.storekit` configuration file (and, in production, the App
    /// Store Connect entries created with the same IDs).
    enum Tier: String, CaseIterable, Identifiable {
        case coffee     = "com.nonbank.tip.coffee"
        case kitten     = "com.nonbank.tip.kitten"
        case croissant  = "com.nonbank.tip.croissant"
        case pizza      = "com.nonbank.tip.pizza"
        case chefsTable = "com.nonbank.tip.chefstable"

        var id: String { rawValue }

        var emoji: String {
            switch self {
            case .coffee:     return "☕"
            case .kitten:     return "🐱"
            case .croissant:  return "🥐"
            case .pizza:      return "🍕"
            case .chefsTable: return "🧑‍🍳"
            }
        }

        var title: String {
            switch self {
            case .coffee:     return "Coffee"
            case .kitten:     return "Kitten food"
            case .croissant:  return "Croissant"
            case .pizza:      return "Pizza night"
            case .chefsTable: return "Chef's table"
            }
        }

        var blurb: String {
            switch self {
            case .coffee:     return "A small thanks for shipping non-bank."
            case .kitten:     return "Keep the office cat fed while features ship."
            case .croissant:  return "Fuel for a Saturday-morning fix-up session."
            case .pizza:      return "A round for the team after a long sprint."
            case .chefsTable: return "Sponsor a whole feature. Seriously, thank you."
            }
        }

        /// Visual badge displayed on the card. We tilt the user toward
        /// pizza (the "Recommended" label) by giving it the accent
        /// fill — the chef's table tier gets a quieter "Most generous"
        /// chip so the very high price doesn't feel like the default.
        var badge: Badge? {
            switch self {
            case .pizza:      return .recommended
            case .chefsTable: return .mostGenerous
            default:          return nil
            }
        }

        enum Badge {
            case recommended
            case mostGenerous
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var isLoadingProducts: Bool = false
    @Published private(set) var purchaseState: PurchaseState = .idle
    @Published private(set) var lastPurchasedTier: Tier?

    /// Stable, locale-independent code for the most recent failed
    /// purchase — derived from the underlying error's `NSError`
    /// domain + code, never the localized message (which varies per
    /// language) or `String.hashValue` (which is randomized per process
    /// launch). Consumed by the analytics layer for
    /// `tip_purchase_failed.error_code` so the same failure groups
    /// across launches, devices, and locales. `nil` until a failure.
    @Published private(set) var lastFailureCode: String?

    enum PurchaseState: Equatable {
        case idle
        case purchasing(Tier)
        case succeeded(Tier)
        /// `.pending` from StoreKit — Ask-to-Buy approval required.
        case deferred(Tier)
        case failed(String)
        case cancelled

        /// Convenience for the binding-getter pattern that surfaces
        /// the error alert — keeps the alert's `isPresented:` from
        /// having to inline an `if case .failed = …` ternary.
        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    /// Background listener for `Transaction.updates`. Delivers
    /// transactions that complete OUTSIDE the `product.purchase()` call —
    /// the canonical case being a Family Sharing "Ask to Buy" tip the
    /// organizer approves minutes or hours after the buyer tapped (the
    /// buyer's `purchase()` already returned `.pending`). Without this,
    /// an approved tip is never finished, never sets `lastPurchasedTier`,
    /// and never fires success — the conversion is silently lost and the
    /// consumable transaction sits unfinished. Gap "FS-3" from the audit.
    private var updatesListener: Task<Void, Never>?

    /// Transaction ids already finished this process. A normal (non-
    /// deferred) purchase is delivered BOTH by `product.purchase()` and
    /// by `Transaction.updates`; we process whichever arrives first and
    /// treat the duplicate as a no-op so we never finish twice or (via the
    /// view's `.succeeded` observer) double-fire success + fireworks.
    /// In-memory only — consumables need no persistence, so this resets on
    /// relaunch, which is fine: StoreKit only re-delivers unfinished
    /// transactions, and we finish each one the first time we see it.
    private var finishedTransactionIDs: Set<UInt64> = []

    private init() {
        // Start the out-of-band transaction listener as early as possible
        // so an Ask-to-Buy approval that lands before any view observes is
        // still finished and recorded.
        updatesListener = Task { [weak self] in
            // `StoreKit.Transaction` is fully qualified throughout: the app
            // has its own `Transaction` model (a bank-style ledger entry),
            // so a bare `Transaction` would resolve to that, not StoreKit's.
            for await update in StoreKit.Transaction.updates {
                // Trust only cryptographically verified transactions —
                // leave anything unverified unfinished so StoreKit can
                // re-deliver it, and never grant on it.
                guard case .verified(let transaction) = update else { continue }
                // Skip products that aren't one of our five tip
                // consumables: they belong to some other flow and aren't
                // ours to finish.
                guard let tier = Tier(rawValue: transaction.productID) else { continue }
                await self?.complete(transaction, tier: tier)
            }
        }
    }

    deinit {
        updatesListener?.cancel()
    }

    // MARK: - Loading

    /// Fetches Product metadata (localized price + display name) from
    /// StoreKit. Called once on view appearance; subsequent calls are
    /// no-ops while a previous fetch is in flight.
    func loadProducts() async {
        guard !isLoadingProducts, products.isEmpty else { return }
        isLoadingProducts = true
        defer { isLoadingProducts = false }
        do {
            let fetched = try await Product.products(for: Tier.allCases.map { $0.rawValue })
            // Sort by our tier order, not whatever the store returned —
            // the UI relies on Coffee → Croissant → Pizza → Chef's table.
            let order = Dictionary(uniqueKeysWithValues: Tier.allCases.enumerated().map { ($1.rawValue, $0) })
            products = fetched.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
        } catch {
            // Leave `products` empty — the UI falls back to a generic
            // "Tips are unavailable right now" message in that case.
            products = []
        }
    }

    func product(for tier: Tier) -> Product? {
        products.first(where: { $0.id == tier.rawValue })
    }

    // MARK: - Purchasing

    /// Kicks off the purchase flow for the given tier. The result is
    /// surfaced through `purchaseState` so any view observing the
    /// service can react (confetti, success overlay, error toast).
    func purchase(_ tier: Tier) async {
        guard let product = product(for: tier) else {
            lastFailureCode = "no_product"
            purchaseState = .failed("This tip isn't available right now. Please try again later.")
            return
        }
        lastFailureCode = nil
        purchaseState = .purchasing(tier)
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    // Same finish/record path the `Transaction.updates`
                    // listener uses — `complete` dedups by transaction id,
                    // so the duplicate delivery of THIS very transaction
                    // via the listener is a harmless no-op.
                    await complete(transaction, tier: tier)
                case .unverified(_, let error):
                    lastFailureCode = Self.stableErrorCode(from: error)
                    purchaseState = .failed(error.localizedDescription)
                }
            case .userCancelled:
                purchaseState = .cancelled
            case .pending:
                // Family-share / Ask-to-Buy flow. Surface a distinct
                // `.deferred` state (rather than collapsing to `.idle`)
                // so the funnel can tell "awaiting approval" apart from
                // "looked and left." Once the organizer approves, the
                // transaction arrives out-of-band via the
                // `Transaction.updates` listener (started in `init`), which
                // finishes it and drives `.succeeded` — completing the
                // conversion the buyer started here.
                purchaseState = .deferred(tier)
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            lastFailureCode = Self.stableErrorCode(from: error)
            purchaseState = .failed(error.localizedDescription)
        }
    }

    /// Finalizes a verified tip transaction arriving from EITHER path —
    /// the direct `product.purchase()` result or the `Transaction.updates`
    /// listener (Ask-to-Buy approvals that land out-of-band). Idempotent
    /// per transaction id: a normal purchase is delivered by both paths,
    /// so the first call finishes + records success and the duplicate
    /// returns early. That single `.succeeded` transition is what the
    /// view's `purchaseState` observer turns into exactly one
    /// `tip_purchase_succeeded` event and one fireworks burst.
    private func complete(_ transaction: StoreKit.Transaction, tier: Tier) async {
        guard !finishedTransactionIDs.contains(transaction.id) else { return }
        finishedTransactionIDs.insert(transaction.id)
        await transaction.finish()
        lastPurchasedTier = tier
        purchaseState = .succeeded(tier)
    }

    /// Maps an arbitrary purchase error to a short, stable,
    /// locale-independent code for low-cardinality analytics grouping.
    /// `NSError` domain + numeric code (e.g. "SKErrorDomain.2") is
    /// identical across launches, devices, and languages — unlike
    /// `String.hashValue` (per-process randomized) or the localized
    /// message (per-language).
    static func stableErrorCode(from error: Error) -> String {
        let ns = error as NSError
        return "\(ns.domain).\(ns.code)"
    }

    /// Resets the success / failure state so the UI overlay can be
    /// dismissed cleanly without leaving the service in a stuck state.
    func dismissPurchaseConfirmation() {
        purchaseState = .idle
    }
}

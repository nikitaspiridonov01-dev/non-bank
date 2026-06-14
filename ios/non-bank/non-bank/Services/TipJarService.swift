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

    enum PurchaseState: Equatable {
        case idle
        case purchasing(Tier)
        case succeeded(Tier)
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

    private init() {}

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
            purchaseState = .failed("This tip isn't available right now. Please try again later.")
            return
        }
        purchaseState = .purchasing(tier)
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                switch verification {
                case .verified(let transaction):
                    await transaction.finish()
                    lastPurchasedTier = tier
                    purchaseState = .succeeded(tier)
                case .unverified(_, let error):
                    purchaseState = .failed(error.localizedDescription)
                }
            case .userCancelled:
                purchaseState = .cancelled
            case .pending:
                // Family-share / Ask-to-Buy flow. We treat it as a
                // graceful exit — the user will get the confirmation
                // via the system once the request is approved.
                purchaseState = .idle
            @unknown default:
                purchaseState = .idle
            }
        } catch {
            purchaseState = .failed(error.localizedDescription)
        }
    }

    /// Resets the success / failure state so the UI overlay can be
    /// dismissed cleanly without leaving the service in a stuck state.
    func dismissPurchaseConfirmation() {
        purchaseState = .idle
    }
}

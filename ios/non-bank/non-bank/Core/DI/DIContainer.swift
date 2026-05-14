import Foundation

/// Lightweight dependency injection container.
/// Registers and resolves services by protocol type.
/// On app start, call `DIContainer.shared.registerDefaults()` to wire up production implementations.
final class DIContainer {
    static let shared = DIContainer()

    private var services: [String: Any] = [:]
    /// Guards `registerDefaults()` against double-registration and lets
    /// `resolve(_:)` self-heal in RELEASE if a caller resolves before
    /// the app root invoked `registerDefaults()`.
    private var didRegisterDefaults = false

    private init() {}

    /// Register a service instance for a given protocol type.
    func register<T>(_ type: T.Type, instance: T) {
        let key = String(describing: type)
        services[key] = instance
    }

    /// Resolve a service by protocol type.
    ///
    /// In DEBUG, an unregistered protocol is a programming error and
    /// crashes immediately (`fatalError`) so the issue is caught
    /// before shipping. In RELEASE we try to recover once by invoking
    /// `registerDefaults()` (covers the "resolve hit before app-root
    /// init" misordering) and crash only if recovery fails — at that
    /// point the app genuinely can't function without the service.
    /// The crash is preceded by an `NSLog` so the cause shows up in
    /// Console.app and crash reports.
    func resolve<T>(_ type: T.Type) -> T {
        let key = String(describing: type)
        if let service = services[key] as? T {
            return service
        }
        #if DEBUG
        fatalError("DIContainer: No registration for \(key). Call DIContainer.shared.registerDefaults() at app launch and ensure \(key) is registered.")
        #else
        NSLog("DIContainer.resolve: missing \(key); attempting self-heal via registerDefaults()")
        if !didRegisterDefaults {
            registerDefaults()
            if let recovered = services[key] as? T {
                return recovered
            }
        }
        NSLog("DIContainer.resolve: unrecoverable miss for \(key); registration list does not include this protocol")
        fatalError("DIContainer: \(key) is not registered. Add it to DIContainer.registerDefaults().")
        #endif
    }

    /// Resolve a service or return `nil` instead of crashing. Use for
    /// optional dependencies — the analytics + share-extension paths
    /// already tolerate a missing implementation, and this gives the
    /// caller a way to express that explicitly instead of relying on
    /// `resolve`'s fatal-on-miss behavior.
    func resolveOptional<T>(_ type: T.Type) -> T? {
        let key = String(describing: type)
        return services[key] as? T
    }

    /// Register all production dependencies. Idempotent — repeated
    /// calls are no-ops, which means `resolve` can safely use this as
    /// a recovery hook in RELEASE without re-instantiating shared
    /// services (some of which open file handles or sockets on init).
    func registerDefaults() {
        guard !didRegisterDefaults else { return }
        didRegisterDefaults = true
        // Persistence
        let db = SQLiteService.shared
        register(DatabaseProtocol.self, instance: db)
        register(KeyValueStoreProtocol.self, instance: UserDefaultsService())

        // Repositories
        register(TransactionRepositoryProtocol.self, instance: TransactionRepository(db: db))
        register(CategoryRepositoryProtocol.self, instance: CategoryRepository(db: db))
        register(FriendRepositoryProtocol.self, instance: FriendRepository(db: db))
        register(ReceiptItemRepositoryProtocol.self, instance: ReceiptItemRepository(db: db))

        // Network
        let networkClient = NetworkClient()
        register(NetworkClientProtocol.self, instance: networkClient)
        register(CurrencyAPIProtocol.self, instance: CurrencyAPI(client: networkClient))

        // Services
        register(CurrencyServiceProtocol.self, instance: CurrencyService())

        // Analytics — Firebase if the SDK is linked, NoOp otherwise.
        // The `FirebaseAnalyticsService` initialiser already gates on
        // `canImport(FirebaseAnalytics)` and falls back to a NoOp
        // internally, so a single registration line works whether the
        // SDK is present or not.
        let analytics: AnalyticsServiceProtocol
        if AnalyticsAvailability.isFirebaseLinked {
            analytics = FirebaseAnalyticsService(enabled: true)
        } else {
            // DEBUG-only console logging while the SDK isn't linked
            // yet so we can verify event taxonomy before paying for
            // the Firebase wiring.
            #if DEBUG
            analytics = NoOpAnalyticsService(logToConsole: true)
            #else
            analytics = NoOpAnalyticsService(logToConsole: false)
            #endif
        }
        register(AnalyticsServiceProtocol.self, instance: analytics)
    }
}

/// Compile-time check for whether the Firebase Analytics SDK is part
/// of this build. Kept separate from `FirebaseAnalyticsService` so
/// `DIContainer.registerDefaults` doesn't have to duplicate the
/// `#if canImport(...)` block.
enum AnalyticsAvailability {
    static var isFirebaseLinked: Bool {
        #if canImport(FirebaseAnalytics)
        return true
        #else
        return false
        #endif
    }
}

import Foundation

/// Lightweight dependency injection container.
/// Registers and resolves services by protocol type.
/// On app start, call `DIContainer.shared.registerDefaults()` to wire up production implementations.
final class DIContainer {
    static let shared = DIContainer()

    private var services: [String: Any] = [:]

    private init() {}

    /// Register a service instance for a given protocol type.
    func register<T>(_ type: T.Type, instance: T) {
        let key = String(describing: type)
        services[key] = instance
    }

    /// Resolve a service by protocol type. Fatal error if not registered.
    func resolve<T>(_ type: T.Type) -> T {
        let key = String(describing: type)
        guard let service = services[key] as? T else {
            fatalError("DIContainer: No registration for \(key). Call registerDefaults() first.")
        }
        return service
    }

    /// Register all production dependencies.
    func registerDefaults() {
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
    }
}

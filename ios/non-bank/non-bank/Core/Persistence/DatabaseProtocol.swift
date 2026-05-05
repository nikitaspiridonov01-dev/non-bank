import Foundation

/// Abstract interface for database operations.
/// SQLiteService conforms to this protocol, allowing mock implementations for testing.
protocol DatabaseProtocol {

    // MARK: - Transactions
    func insertTransaction(_ transaction: Transaction) async
    func insertTransactions(_ transactions: [Transaction]) async
    func fetchAllTransactions() async -> [Transaction]
    func updateTransaction(_ transaction: Transaction) async
    func deleteTransaction(id: Int) async
    func deleteAllTransactions() async

    // MARK: - Categories
    func insertCategory(_ category: Category) async
    func fetchAllCategories() async -> [Category]
    func updateCategory(_ category: Category) async
    func deleteCategory(id: UUID) async

    // MARK: - Friends
    func insertFriend(_ friend: Friend) async
    func fetchAllFriends() async -> [Friend]
    func updateFriend(_ friend: Friend) async
    func deleteFriend(id: String) async

    // MARK: - Receipt Items
    /// Inserts a single item, returning the assigned autoincrement id.
    func insertReceiptItem(_ item: ReceiptItem) async -> Int?
    /// Inserts a batch in a single SQL transaction. Returns the same items
    /// with `persistedID` populated, in input order.
    func insertReceiptItems(_ items: [ReceiptItem]) async -> [ReceiptItem]
    /// All items belonging to a transaction, ordered by `position` ascending.
    func fetchReceiptItems(transactionID: Int) async -> [ReceiptItem]
    /// All items across all transactions — used by the in-memory store on
    /// initial load.
    func fetchAllReceiptItems() async -> [ReceiptItem]
    func updateReceiptItem(_ item: ReceiptItem) async
    func deleteReceiptItem(id: Int) async
    /// Cascade-style delete used when the parent transaction is removed.
    func deleteReceiptItems(transactionID: Int) async
}

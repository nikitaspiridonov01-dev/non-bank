import Foundation
@testable import non_bank

typealias Category = non_bank.Category

enum TestFixtures {

    static let fixedDate = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14

    static func makeTransaction(
        id: Int = 1,
        emoji: String = "🍽️",
        category: String = "Food",
        title: String = "Lunch",
        description: String? = nil,
        amount: Double = 15.0,
        currency: String = "USD",
        date: Date = fixedDate,
        type: TransactionType = .expenses,
        tags: [String]? = nil,
        repeatInterval: RepeatInterval? = nil,
        parentReminderID: Int? = nil,
        splitInfo: SplitInfo? = nil
    ) -> Transaction {
        Transaction(
            id: id,
            emoji: emoji,
            category: category,
            title: title,
            description: description,
            amount: amount,
            currency: currency,
            date: date,
            type: type,
            tags: tags,
            repeatInterval: repeatInterval,
            parentReminderID: parentReminderID,
            splitInfo: splitInfo
        )
    }

    static func makeCategory(
        emoji: String = "🍽️",
        title: String = "Food"
    ) -> Category {
        Category(emoji: emoji, title: title)
    }

    static let sampleCategories: [Category] = [
        Category(emoji: "🙂", title: "General"),
        Category(emoji: "🍽️", title: "Food"),
        Category(emoji: "🚗", title: "Transport"),
        Category(emoji: "💰", title: "Salary"),
    ]
}

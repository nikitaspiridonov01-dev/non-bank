import XCTest
@testable import non_bank

final class TransactionFilterServiceTests: XCTestCase {

    // MARK: - Date Filtering

    func testFilterByDate_all_returnsEverything() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: Date.distantPast),
            TestFixtures.makeTransaction(id: 2, date: Date()),
        ]
        let result = TransactionFilterService.filterByDate(transactions: txs, filter: .all)
        XCTAssertEqual(result.count, 2)
    }

    func testFilterByDate_today_returnsOnlyToday() {
        let now = Date()
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: now),
            TestFixtures.makeTransaction(id: 2, date: yesterday),
        ]
        let result = TransactionFilterService.filterByDate(transactions: txs, filter: .today, now: now)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testFilterByDate_week_returnsLast7Days() {
        let now = Date()
        let fiveDaysAgo = Calendar.current.date(byAdding: .day, value: -5, to: now)!
        let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: now)!
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: now),
            TestFixtures.makeTransaction(id: 2, date: fiveDaysAgo),
            TestFixtures.makeTransaction(id: 3, date: tenDaysAgo),
        ]
        let result = TransactionFilterService.filterByDate(transactions: txs, filter: .week, now: now)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Multi-criteria Filtering

    func testApply_searchText_matchesTitleAndDescription() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, title: "Uber ride"),
            TestFixtures.makeTransaction(id: 2, title: "Lunch", description: "uber eats"),
            TestFixtures.makeTransaction(id: 3, title: "Coffee"),
        ]
        let criteria = TransactionFilterService.FilterCriteria(searchText: "uber")
        let result = TransactionFilterService.apply(criteria: criteria, to: txs)
        XCTAssertEqual(result.count, 2)
    }

    func testApply_categoryFilter() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, category: "Food"),
            TestFixtures.makeTransaction(id: 2, category: "Transport"),
        ]
        let criteria = TransactionFilterService.FilterCriteria(categories: ["Food"])
        let result = TransactionFilterService.apply(criteria: criteria, to: txs)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.category, "Food")
    }

    func testApply_typeFilter() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, type: .expenses),
            TestFixtures.makeTransaction(id: 2, type: .income),
        ]
        let criteria = TransactionFilterService.FilterCriteria(types: [.income])
        let result = TransactionFilterService.apply(criteria: criteria, to: txs)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.type, .income)
    }

    func testApply_combinedFilters() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, category: "Food", title: "Lunch", type: .expenses),
            TestFixtures.makeTransaction(id: 2, category: "Food", title: "Dinner", type: .income),
            TestFixtures.makeTransaction(id: 3, category: "Transport", title: "Uber", type: .expenses),
        ]
        let criteria = TransactionFilterService.FilterCriteria(
            categories: ["Food"],
            types: [.expenses]
        )
        let result = TransactionFilterService.apply(criteria: criteria, to: txs)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, 1)
    }

    func testApply_emptyFilters_returnsAll() {
        let txs = [
            TestFixtures.makeTransaction(id: 1),
            TestFixtures.makeTransaction(id: 2),
        ]
        let criteria = TransactionFilterService.FilterCriteria()
        let result = TransactionFilterService.apply(criteria: criteria, to: txs)
        XCTAssertEqual(result.count, 2)
    }

    // MARK: - Group by Day

    func testGroupByDay_groupsCorrectly() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
        let txs = [
            TestFixtures.makeTransaction(id: 1, date: today),
            TestFixtures.makeTransaction(id: 2, date: today.addingTimeInterval(3600)),
            TestFixtures.makeTransaction(id: 3, date: yesterday),
        ]
        let groups = TransactionFilterService.groupByDay(txs)
        XCTAssertEqual(groups.count, 2)
        // First group should be the most recent (today)
        XCTAssertEqual(groups[0].transactions.count, 2)
        XCTAssertEqual(groups[1].transactions.count, 1)
    }

    // MARK: - Balance

    func testBalance_netCalculation() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, amount: 100, type: .income),
            TestFixtures.makeTransaction(id: 2, amount: 30, type: .expenses),
            TestFixtures.makeTransaction(id: 3, amount: 20, type: .expenses),
        ]
        let balance = TransactionFilterService.balance(
            transactions: txs,
            targetCurrency: "USD",
            convert: { amount, _, _ in amount }
        )
        XCTAssertEqual(balance, 50.0, accuracy: 0.01) // 100 - 30 - 20
    }

    func testBalance_withConversion() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, amount: 100, currency: "EUR", type: .income),
        ]
        let balance = TransactionFilterService.balance(
            transactions: txs,
            targetCurrency: "USD",
            convert: { amount, from, to in
                if from == "EUR" && to == "USD" { return amount * 1.09 }
                return amount
            }
        )
        XCTAssertEqual(balance, 109.0, accuracy: 0.01)
    }

    // MARK: - Top Categories

    func testTopCategories_sortedByFrequency() {
        let txs = [
            TestFixtures.makeTransaction(id: 1, category: "Food"),
            TestFixtures.makeTransaction(id: 2, category: "Food"),
            TestFixtures.makeTransaction(id: 3, category: "Transport"),
            TestFixtures.makeTransaction(id: 4, category: "Transport"),
            TestFixtures.makeTransaction(id: 5, category: "Transport"),
            TestFixtures.makeTransaction(id: 6, category: "Rent"),
        ]
        let top = TransactionFilterService.topCategories(
            from: txs,
            resolveCategory: { $0.category },
            limit: 2
        )
        XCTAssertEqual(top, ["Transport", "Food"])
    }

}

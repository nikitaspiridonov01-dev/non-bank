import XCTest
@testable import non_bank

final class MoneyMathTests: XCTestCase {

    private func sum(_ xs: [Double]) -> Double { xs.reduce(0, +) }

    // MARK: - cents / roundedToCents

    func testCents_roundsHalfAwayFromZero() {
        XCTAssertEqual(MoneyMath.cents(12.996666), 1300)
        XCTAssertEqual(MoneyMath.cents(12.344999), 1234)
        XCTAssertEqual(MoneyMath.cents(-12.996666), -1300)
        XCTAssertEqual(MoneyMath.cents(0.005), 1)
        XCTAssertEqual(MoneyMath.cents(0), 0)
    }

    func testRoundedToCents() {
        XCTAssertEqual(MoneyMath.roundedToCents(12.996666), 13.0, accuracy: 1e-9)
        XCTAssertEqual(MoneyMath.roundedToCents(2.675), 2.68, accuracy: 1e-9)
    }

    // MARK: - splitEvenly

    func testSplitEvenly_38_99_byThree_isCentExact() {
        // The reported bug: 38.99 / 3 = 12.9966… was stored and then shown
        // as "12" / "12.100". Cent-exact shares: 13.00 + 13.00 + 12.99.
        let shares = MoneyMath.splitEvenly(38.99, count: 3)
        XCTAssertEqual(shares, [13.00, 13.00, 12.99])
        XCTAssertEqual(sum(shares), 38.99, accuracy: 1e-9)
    }

    func testSplitEvenly_100_byThree_sumsToTotal() {
        let shares = MoneyMath.splitEvenly(100, count: 3)
        XCTAssertEqual(shares, [33.34, 33.33, 33.33])
        XCTAssertEqual(sum(shares), 100, accuracy: 1e-9)
    }

    func testSplitEvenly_exactDivision_hasNoLeftover() {
        XCTAssertEqual(MoneyMath.splitEvenly(30, count: 2), [15, 15])
        XCTAssertEqual(MoneyMath.splitEvenly(0.03, count: 3), [0.01, 0.01, 0.01])
    }

    func testSplitEvenly_fewerCentsThanPeople() {
        // Two cents, three people: the first two get one cent each.
        XCTAssertEqual(MoneyMath.splitEvenly(0.02, count: 3), [0.01, 0.01, 0])
    }

    func testSplitEvenly_oneParticipant_getsRoundedTotal() {
        XCTAssertEqual(MoneyMath.splitEvenly(12.996666, count: 1), [13.00])
    }

    func testSplitEvenly_zeroOrNegativeCount_isEmpty() {
        XCTAssertEqual(MoneyMath.splitEvenly(10, count: 0), [])
        XCTAssertEqual(MoneyMath.splitEvenly(10, count: -1), [])
    }

    func testSplitEvenly_negativeTotal_keepsSignAndMagnitudes() {
        let shares = MoneyMath.splitEvenly(-3.00, count: 2)
        XCTAssertEqual(shares, [-1.50, -1.50])
        XCTAssertEqual(MoneyMath.splitEvenly(-0.03, count: 2), [-0.02, -0.01])
    }

    func testSplitEvenly_sumIsExactAcrossManyInputs() {
        // Property check over a grid of totals and head counts: the shares
        // always add up to the total rounded to cents, and differ by at
        // most one cent from each other.
        for cents in stride(from: 1, through: 5000, by: 7) {
            for n in 1...9 {
                let total = Double(cents) / 100
                let shares = MoneyMath.splitEvenly(total, count: n)
                XCTAssertEqual(shares.count, n)
                XCTAssertEqual(MoneyMath.cents(sum(shares)), cents, "total \(total) / \(n)")
                let minShare = shares.min()!, maxShare = shares.max()!
                XCTAssertLessThanOrEqual(MoneyMath.cents(maxShare) - MoneyMath.cents(minShare), 1)
            }
        }
    }

    // MARK: - allocate

    func testAllocate_proportional_exactWhenDivisible() {
        // 3.00 across weights 20:10 → 2.00 / 1.00
        XCTAssertEqual(MoneyMath.allocate(3.00, weights: [20, 10]), [2.00, 1.00])
    }

    func testAllocate_largestRemainder_getsTheExtraCent() {
        // 1.00 across 1:1:1 → 0.34 / 0.33 / 0.33 (ties go in input order).
        XCTAssertEqual(MoneyMath.allocate(1.00, weights: [1, 1, 1]), [0.34, 0.33, 0.33])
        // 1.00 across 1:2 → ideal 33.33 / 66.67 → the bigger remainder wins.
        XCTAssertEqual(MoneyMath.allocate(1.00, weights: [1, 2]), [0.33, 0.67])
    }

    func testAllocate_zeroWeight_getsNothing() {
        XCTAssertEqual(MoneyMath.allocate(5.00, weights: [0, 1]), [0, 5.00])
        XCTAssertEqual(MoneyMath.allocate(5.00, weights: [-1, 1]), [0, 5.00])
    }

    func testAllocate_allZeroWeights_distributesNothing() {
        XCTAssertEqual(MoneyMath.allocate(5.00, weights: [0, 0]), [0, 0])
        XCTAssertEqual(MoneyMath.allocate(5.00, weights: []), [])
    }

    func testAllocate_negativeTotal_discount() {
        let cuts = MoneyMath.allocate(-3.00, weights: [20, 10])
        XCTAssertEqual(cuts, [-2.00, -1.00])
        XCTAssertEqual(sum(cuts), -3.00, accuracy: 1e-9)
    }

    func testAllocate_sumIsExactAcrossManyInputs() {
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 11) / Double(1 << 53)
        }
        for _ in 0..<300 {
            let n = 1 + Int(next() * 6)
            let weights = (0..<n).map { _ in (next() * 50).rounded() / 2 }
            let total = (next() * 20000).rounded() / 100 - 50
            let cuts = MoneyMath.allocate(total, weights: weights)
            XCTAssertEqual(cuts.count, n)
            if weights.reduce(0, +) > 0 {
                XCTAssertEqual(MoneyMath.cents(sum(cuts)), MoneyMath.cents(total), "total \(total) weights \(weights)")
            } else {
                XCTAssertEqual(cuts, Array(repeating: 0, count: n))
            }
        }
    }
}

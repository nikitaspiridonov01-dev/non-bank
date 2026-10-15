import Foundation

/// Cent-exact money arithmetic.
///
/// Amounts are `Double`s throughout the app, which is fine for storing what
/// the user typed (two decimals survive the round trip), but dividing them
/// produces values like `12.996666…` that no formatter can show honestly:
/// the integer part says 12 while the cents round up to a full unit. Every
/// place that splits one amount between several people goes through this
/// enum so that each share is a whole number of cents and the shares sum to
/// the original amount exactly.
///
/// The distribution is the "largest remainder" method: each participant
/// gets the floor of their ideal share in cents, and the leftover cents go
/// one each to the participants with the largest fractional remainders, in
/// input order on ties. The result is deterministic for the same inputs.
enum MoneyMath {

    /// `value` rounded to the nearest cent, as a `Double` (`12.996…` → `13.0`).
    static func roundedToCents(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    /// `value` rounded to the nearest cent, as a signed integer number of
    /// cents (`-12.996…` → `-1300`).
    static func cents(_ value: Double) -> Int {
        Int((value * 100).rounded())
    }

    /// Splits `total` between `count` equal participants. The first
    /// `remainder` participants carry one extra cent, so the shares sum to
    /// `total` (rounded to cents) exactly. Returns `[]` for `count <= 0`.
    static func splitEvenly(_ total: Double, count: Int) -> [Double] {
        guard count > 0 else { return [] }
        return allocate(total, weights: Array(repeating: 1, count: count))
    }

    /// Splits `total` between participants in proportion to `weights`.
    /// The returned array is aligned with `weights` and sums to `total`
    /// (rounded to cents) exactly. Negative totals (discounts) are split
    /// with the same magnitudes and the sign restored. A zero or negative
    /// weight yields a zero share; if every weight is zero, everyone gets
    /// zero and the total is not distributed (callers gate on this case).
    static func allocate(_ total: Double, weights: [Double]) -> [Double] {
        guard !weights.isEmpty else { return [] }
        let weightSum = weights.reduce(0) { $0 + max($1, 0) }
        guard weightSum > 0 else { return Array(repeating: 0, count: weights.count) }

        let sign: Double = total < 0 ? -1 : 1
        let totalCents = abs(cents(total))

        var floors = [Int](repeating: 0, count: weights.count)
        var remainders = [(index: Int, fraction: Double)]()
        var assigned = 0
        for (i, w) in weights.enumerated() where w > 0 {
            let ideal = Double(totalCents) * w / weightSum
            let whole = Int(ideal.rounded(.down))
            floors[i] = whole
            assigned += whole
            remainders.append((i, ideal - Double(whole)))
        }

        // Hand the leftover cents to the largest remainders; stable on ties
        // so equal participants are served in input order.
        var leftover = totalCents - assigned
        if leftover > 0 {
            let order = remainders.enumerated().sorted {
                if $0.element.fraction != $1.element.fraction {
                    return $0.element.fraction > $1.element.fraction
                }
                return $0.offset < $1.offset
            }
            for entry in order where leftover > 0 {
                floors[entry.element.index] += 1
                leftover -= 1
            }
        }

        return floors.map { sign * Double($0) / 100 }
    }
}

import Foundation

/// Pure business logic for currency conversion.
/// No UI, no persistence — just math.
protocol CurrencyServiceProtocol {
    func convert(amount: Double, from: String, to: String, rates: [String: Double]) -> Double
    func convertToUsd(amount: Double, from: String, rates: [String: Double]) -> Double
    func convertFromUsd(amount: Double, to: String, rates: [String: Double]) -> Double
}

final class CurrencyService: CurrencyServiceProtocol {

    func convertFromUsd(amount: Double, to: String, rates: [String: Double]) -> Double {
        guard let rate = rates[to] else { return amount }
        return amount * rate
    }

    func convertToUsd(amount: Double, from: String, rates: [String: Double]) -> Double {
        guard let rate = rates[from], rate != 0 else { return amount }
        return amount / rate
    }

    func convert(amount: Double, from: String, to: String, rates: [String: Double]) -> Double {
        if from == to { return amount }
        let usd = convertToUsd(amount: amount, from: from, rates: rates)
        return convertFromUsd(amount: usd, to: to, rates: rates)
    }
}

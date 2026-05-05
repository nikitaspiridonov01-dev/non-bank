import Foundation

enum TransactionType: String, CaseIterable, Identifiable, Codable, Equatable {
    case expenses = "Expenses"
    case income = "Income"
    
    var id: String { rawValue }
    var label: String {
        switch self {
        case .expenses: return "Expenses"
        case .income: return "Income"
        }
    }
}

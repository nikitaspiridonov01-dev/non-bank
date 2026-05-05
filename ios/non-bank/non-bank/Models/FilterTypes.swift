import Foundation
import SwiftUI

enum DateFilterType: String, CaseIterable, Identifiable {
    case all, today, week, month, year
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "All time"
        case .today: return "Today"
        case .week: return "Week"
        case .month: return "Month"
        case .year: return "Year"
        }
    }
    /// Short labels for the horizontal period picker below the chart.
    var shortLabel: String {
        switch self {
        case .all: return "All time"
        case .today: return "1D"
        case .week: return "1W"
        case .month: return "1M"
        case .year: return "1Y"
        }
    }
}

struct TrendBarPoint: Identifiable {
    let id = UUID()
    let height: CGFloat
    let balance: Double
    let label: String
}

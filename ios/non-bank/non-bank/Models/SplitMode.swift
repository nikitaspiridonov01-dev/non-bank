import SwiftUI

/// How a user and their friend commonly split expenses.
enum SplitMode: String, Codable, CaseIterable, Identifiable {
    case fiftyFifty = "50/50"
    case unequalPercent = "Unequally, %"
    case unequalExact = "Unequally, exact amounts"
    case timeBased = "Time based"

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .fiftyFifty:      return "50/50"
        case .unequalPercent:  return "By percentage"
        case .unequalExact:    return "By amount"
        case .timeBased:       return "Time based"
        }
    }

    var iconName: String {
        switch self {
        case .fiftyFifty:      return "equal.circle.fill"
        case .unequalPercent:  return "percent"
        case .unequalExact:    return "number.circle.fill"
        case .timeBased:       return "clock.fill"
        }
    }

    var iconColor: Color {
        switch self {
        case .fiftyFifty:      return .blue
        case .unequalPercent:  return .orange
        case .unequalExact:    return .purple
        case .timeBased:       return .green
        }
    }

    var helpText: String {
        switch self {
        case .fiftyFifty:      return "Split equally between both"
        case .unequalPercent:  return "Split by percentage share"
        case .unequalExact:    return "Each person pays a set amount"
        case .timeBased:       return "Split based on time spent"
        }
    }
}

/// A small circular icon badge for a split mode.
struct SplitModeIcon: View {
    let mode: SplitMode
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: mode.iconName)
            .font(.system(size: size * 0.5, weight: .bold))
            .foregroundColor(.white)
            .frame(width: size, height: size, alignment: .center)
            .background(mode.iconColor)
            .clipShape(Circle())
    }
}


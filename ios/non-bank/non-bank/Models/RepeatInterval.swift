import Foundation

enum DayOfWeek: Int, Codable, CaseIterable, Identifiable {
    case sunday = 1, monday, tuesday, wednesday, thursday, friday, saturday
    var id: Int { rawValue }
    var label: String {
        Calendar.current.weekdaySymbols[rawValue - 1]
    }
    var shortLabel: String {
        Calendar.current.shortWeekdaySymbols[rawValue - 1]
    }
}

enum MonthOfYear: Int, Codable, CaseIterable, Identifiable {
    case january = 1, february, march, april, may, june
    case july, august, september, october, november, december
    var id: Int { rawValue }
    var label: String {
        Calendar.current.monthSymbols[rawValue - 1]
    }
    var shortLabel: String {
        Calendar.current.shortMonthSymbols[rawValue - 1]
    }
}

/// Defines how often a recurring transaction repeats.
enum RepeatInterval: Codable, Equatable {
    case daily(hour: Int, minute: Int)
    case weekly(hour: Int, minute: Int, daysOfWeek: [DayOfWeek])
    case monthly(hour: Int, minute: Int, daysOfMonth: [Int])
    case yearly(hour: Int, minute: Int, month: MonthOfYear, dayOfMonth: Int)

    /// Full label for detail card, e.g. "Every day at 09:00", "Weekly on Mon, Fri at 09:00"
    var displayLabel: String {
        switch self {
        case .daily(let hour, let minute):
            return "Every day at \(Self.timeString(hour, minute))"
        case .weekly(let hour, let minute, let days):
            let names = days.map { $0.shortLabel }
            return "Weekly on \(names.joined(separator: ", ")) at \(Self.timeString(hour, minute))"
        case .monthly(let hour, let minute, let days):
            let dayStrings = days.map { Self.ordinal($0) }
            return "Monthly on the \(dayStrings.joined(separator: ", ")) at \(Self.timeString(hour, minute))"
        case .yearly(let hour, let minute, let month, let day):
            return "Yearly on \(month.shortLabel) \(day) at \(Self.timeString(hour, minute))"
        }
    }

    /// Short label for row badges (no details)
    var badgeLabel: String {
        switch self {
        case .daily:   return "Every day"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    private static func timeString(_ hour: Int, _ minute: Int) -> String {
        String(format: "%02d:%02d", hour, minute)
    }

    private static func ordinal(_ day: Int) -> String {
        let suffix: String
        let ones = day % 10
        let tens = day % 100
        if tens >= 11 && tens <= 13 {
            suffix = "th"
        } else if ones == 1 {
            suffix = "st"
        } else if ones == 2 {
            suffix = "nd"
        } else if ones == 3 {
            suffix = "rd"
        } else {
            suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    /// Computes the next N occurrence dates after the given reference date.
    func nextOccurrences(_ count: Int, after referenceDate: Date, calendar: Calendar = .current) -> [Date] {
        var results: [Date] = []
        var cursor = referenceDate
        for _ in 0..<count {
            guard let next = nextOccurrence(after: cursor, calendar: calendar) else { break }
            results.append(next)
            cursor = next
        }
        return results
    }

    /// Computes the next occurrence date after the given reference date.
    func nextOccurrence(after referenceDate: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .daily(let hour, let minute):
            var comps = calendar.dateComponents([.year, .month, .day], from: referenceDate)
            comps.hour = hour
            comps.minute = minute
            comps.second = 0
            guard let candidate = calendar.date(from: comps) else { return nil }
            return candidate > referenceDate
                ? candidate
                : calendar.date(byAdding: .day, value: 1, to: candidate)

        case .weekly(let hour, let minute, let daysOfWeek):
            let targetWeekdays = daysOfWeek.map { $0.rawValue }.sorted()
            guard !targetWeekdays.isEmpty else { return nil }
            for offset in 0..<8 {
                guard let candidate = calendar.date(byAdding: .day, value: offset, to: referenceDate) else { continue }
                let weekday = calendar.component(.weekday, from: candidate)
                if targetWeekdays.contains(weekday) {
                    var comps = calendar.dateComponents([.year, .month, .day], from: candidate)
                    comps.hour = hour
                    comps.minute = minute
                    comps.second = 0
                    guard let result = calendar.date(from: comps) else { continue }
                    if result > referenceDate { return result }
                }
            }
            return nil

        case .monthly(let hour, let minute, let daysOfMonth):
            let sortedDays = daysOfMonth.sorted()
            guard !sortedDays.isEmpty else { return nil }
            for monthOffset in 0..<3 {
                guard let monthDate = calendar.date(byAdding: .month, value: monthOffset, to: referenceDate) else { continue }
                for day in sortedDays {
                    var comps = calendar.dateComponents([.year, .month], from: monthDate)
                    comps.day = day
                    comps.hour = hour
                    comps.minute = minute
                    comps.second = 0
                    guard let candidate = calendar.date(from: comps) else { continue }
                    if candidate > referenceDate { return candidate }
                }
            }
            return nil

        case .yearly(let hour, let minute, let month, let dayOfMonth):
            let currentYear = calendar.component(.year, from: referenceDate)
            for yearOffset in 0..<2 {
                var comps = DateComponents()
                comps.year = currentYear + yearOffset
                comps.month = month.rawValue
                comps.day = dayOfMonth
                comps.hour = hour
                comps.minute = minute
                comps.second = 0
                guard let candidate = calendar.date(from: comps) else { continue }
                if candidate > referenceDate { return candidate }
            }
            return nil
        }
    }
}

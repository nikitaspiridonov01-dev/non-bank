import Foundation
import Combine

@MainActor
class ReminderViewModel: ObservableObject {

    @Published var reminders: [Transaction] = []

    func refresh(from allTransactions: [Transaction]) {
        let raw = ReminderService.reminders(from: allTransactions)
        reminders = ReminderService.sortedByNextOccurrence(raw)
    }

    func nextDate(for transaction: Transaction) -> Date? {
        ReminderService.nextOccurrenceDate(for: transaction)
    }

    func formattedNextDate(for transaction: Transaction) -> String {
        guard let date = nextDate(for: transaction) else { return "No upcoming" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today at' HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "'Tomorrow at' HH:mm"
        } else {
            let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
            formatter.dateFormat = isCurrentYear ? "MMM d 'at' HH:mm" : "MMM d, yyyy 'at' HH:mm"
        }
        return formatter.string(from: date)
    }

    /// Reminders grouped by the day of their next occurrence, oldest first so
    /// the soonest reminders surface at the top (already sorted by `refresh`).
    func groupedByNextDay() -> [(date: Date, reminders: [Transaction])] {
        let calendar = Calendar.current
        let buckets = Dictionary(grouping: reminders) { tx -> Date in
            let ref = ReminderService.nextOccurrenceDate(for: tx) ?? tx.date
            let comps = calendar.dateComponents([.year, .month, .day], from: ref)
            return calendar.date(from: comps) ?? ref
        }
        return buckets.keys.sorted().map { key in
            (date: key, reminders: buckets[key] ?? [])
        }
    }

    /// Section header label for a grouped day (matches the Home-screen style).
    func sectionLabel(for date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "TODAY" }
        if calendar.isDateInTomorrow(date) { return "TOMORROW" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        formatter.dateFormat = isCurrentYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return formatter.string(from: date).uppercased()
    }
}

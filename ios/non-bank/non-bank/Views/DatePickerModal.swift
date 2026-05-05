import SwiftUI

// MARK: - Модалка выбора даты

/// Date picker + optional time + recurrence selector.
///
/// - Future dates are allowed: picking a date after now saves the transaction
///   as a reminder that fires at the chosen time.
/// - The repeat picker turns the transaction into a recurring parent — child
///   transactions spawn automatically on each occurrence.
struct DatePickerModal: View {
    @Binding var isPresented: Bool
    @Binding var date: Date
    @Binding var repeatInterval: RepeatInterval?

    @State private var repeatChoice: RepeatChoice = .none

    // MARK: - Derived

    private var dateLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMM d, yyyy"
        return fmt.string(from: date)
    }

    /// "Now" is visible while the selected time differs from the current time
    /// by more than 60s — including any time in the future.
    private var isTimeChanged: Bool {
        abs(date.timeIntervalSinceNow) > 60
    }

    private var isFuture: Bool {
        date > Date()
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: AppSpacing.lg) {
                        DatePicker("", selection: $date, displayedComponents: [.date])
                            .datePickerStyle(.graphical)
                            .labelsHidden()
                            .padding(.horizontal, AppSpacing.sm)

                        // Time picker row
                        HStack {
                            Text(dateLabel)
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            Spacer()
                            DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                                .labelsHidden()
                        }
                        .padding(.horizontal, AppSpacing.xl)

                        repeatPickerRow
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.top, AppSpacing.xs)

                        if shouldShowReminderHint {
                            reminderHint
                                .padding(.horizontal, AppSpacing.pageHorizontal)
                        }

                        Spacer().frame(height: 24)
                    }
                    .padding(.top, AppSpacing.md)
                }
            }
            .navigationTitle("Select Date")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isTimeChanged {
                        Button(action: { date = Date() }) {
                            Label("Now", systemImage: "clock.arrow.circlepath")
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
            .onAppear {
                repeatChoice = RepeatChoice(interval: repeatInterval)
            }
            .onChange(of: repeatChoice) { _ in
                syncRepeatBinding()
            }
            .onChange(of: date) { _ in
                // Keep the recurring pattern aligned with the picked
                // hour/minute/weekday/day-of-month whenever the date changes.
                if repeatChoice != .none {
                    syncRepeatBinding()
                }
            }
        }
        .presentationDragIndicator(.visible)
    }

    // MARK: - Repeat Picker

    private var repeatPickerRow: some View {
        // Keep the Menu label static and short ("Daily", "Weekly", ...) so
        // that switching choices never reflows the row. Date-dependent detail
        // (weekday, day-of-month, etc.) lives in a separate caption below.
        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
            HStack(alignment: .firstTextBaseline) {
                Label("Repeat", systemImage: "repeat")
                    .font(.subheadline)
                    .foregroundColor(.primary)
                Spacer(minLength: 8)
                // Native .menu picker: iOS renders the selected option + a
                // chevron in its own button, so the label's intrinsic width
                // never collides with surrounding layout during selection
                // changes. This avoids the truncation flash the custom
                // `Menu { } label:` approach exhibits.
                Picker("Repeat", selection: $repeatChoice) {
                    ForEach(RepeatChoice.allCases) { choice in
                        Text(choice.label).tag(choice)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .tint(.accentColor)
            }
            if let detail = repeatDetailDescription {
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.backgroundElevated)
        )
    }

    /// Date-dependent caption shown under the repeat row — hidden when no
    /// repeat is selected or the choice doesn't carry extra information.
    private var repeatDetailDescription: String? {
        let cal = Calendar.current
        switch repeatChoice {
        case .none, .daily:
            return nil
        case .weekly:
            let weekday = cal.component(.weekday, from: date)
            let name = cal.weekdaySymbols[max(weekday - 1, 0)]
            return "Every \(name)"
        case .monthly:
            let day = cal.component(.day, from: date)
            return "Every \(ordinalSuffix(day)) of the month"
        case .yearly:
            let fmt = DateFormatter()
            fmt.dateFormat = "MMMM d"
            return "Every \(fmt.string(from: date))"
        }
    }

    private func ordinalSuffix(_ n: Int) -> String {
        let ones = n % 10
        let tens = n % 100
        if tens >= 11 && tens <= 13 { return "\(n)th" }
        switch ones {
        case 1: return "\(n)st"
        case 2: return "\(n)nd"
        case 3: return "\(n)rd"
        default: return "\(n)th"
        }
    }

    // MARK: - Reminder Hint

    private var shouldShowReminderHint: Bool {
        isFuture || repeatInterval != nil
    }

    private var reminderHint: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge")
                .font(AppFonts.subhead)
                .foregroundColor(AppColors.reminderAccent)

            VStack(alignment: .leading, spacing: 3) {
                Text("Saved as a reminder")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(AppColors.textPrimary)
                Text(reminderHintBody)
                    .font(.caption)
                    .foregroundColor(AppColors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(AppColors.reminderBackgroundTint)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .stroke(AppColors.reminderAccent.opacity(0.25), lineWidth: 1)
        )
    }

    private var reminderHintBody: String {
        if repeatInterval != nil {
            return "Appears in Reminders and creates a transaction automatically on every occurrence."
        }
        return "Appears in Reminders until the selected date, then becomes a transaction automatically."
    }

    // MARK: - Sync helpers

    private func syncRepeatBinding() {
        repeatInterval = makeInterval(from: repeatChoice, date: date)
    }

    private func makeInterval(from choice: RepeatChoice, date: Date) -> RepeatInterval? {
        let cal = Calendar.current
        let comps = cal.dateComponents([.hour, .minute, .weekday, .day, .month], from: date)
        let hour = comps.hour ?? 0
        let minute = comps.minute ?? 0

        switch choice {
        case .none:
            return nil
        case .daily:
            return .daily(hour: hour, minute: minute)
        case .weekly:
            let weekday = comps.weekday ?? 1
            let dow = DayOfWeek(rawValue: weekday) ?? .sunday
            return .weekly(hour: hour, minute: minute, daysOfWeek: [dow])
        case .monthly:
            let day = comps.day ?? 1
            return .monthly(hour: hour, minute: minute, daysOfMonth: [day])
        case .yearly:
            let day = comps.day ?? 1
            let month = comps.month ?? 1
            let moy = MonthOfYear(rawValue: month) ?? .january
            return .yearly(hour: hour, minute: minute, month: moy, dayOfMonth: day)
        }
    }
}

// MARK: - Repeat Choice

enum RepeatChoice: String, CaseIterable, Identifiable {
    case none
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:    return "Does not repeat"
        case .daily:   return "Daily"
        case .weekly:  return "Weekly"
        case .monthly: return "Monthly"
        case .yearly:  return "Yearly"
        }
    }

    init(interval: RepeatInterval?) {
        guard let interval else { self = .none; return }
        switch interval {
        case .daily:   self = .daily
        case .weekly:  self = .weekly
        case .monthly: self = .monthly
        case .yearly:  self = .yearly
        }
    }
}

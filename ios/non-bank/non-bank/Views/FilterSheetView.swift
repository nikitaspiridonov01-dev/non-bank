import SwiftUI

struct FilterSheetView: View {
    @Binding var isPresented: Bool
    @Binding var selectedCategories: Set<String>
    @Binding var selectedTransactionTypes: Set<TransactionType>
    
    let allCategories: [String]
    let allTransactions: [Transaction]
    var onJumpToDate: ((Date) -> Void)?
    /// Lookup emoji for a category — uses allCategories source metadata
    let categoryEmojis: [String: String]

    @State private var showDatePicker: Bool = false
    @State private var pickedDate: Date = Date()
    @State private var showAllCategories: Bool = false

    /// Set of calendar day components that have at least one transaction
    private var transactionDays: Set<DateComponents> {
        let calendar = Calendar.current
        var days = Set<DateComponents>()
        for tx in allTransactions {
            let comps = calendar.dateComponents([.year, .month, .day], from: tx.date)
            days.insert(comps)
        }
        return days
    }

    /// Earliest transaction date (for limiting picker range)
    private var earliestDate: Date {
        allTransactions.map(\.date).min() ?? Date()
    }

    /// Categories sorted by usage frequency (highest first), tiebreaker = most recent
    private var sortedCategories: [String] {
        var stats: [String: (count: Int, lastDate: Date)] = [:]
        for tx in allTransactions {
            let cat = tx.category
            if let prev = stats[cat] {
                stats[cat] = (prev.count + 1, max(prev.lastDate, tx.date))
            } else {
                stats[cat] = (1, tx.date)
            }
        }
        return allCategories.sorted { a, b in
            let sa = stats[a] ?? (0, .distantPast)
            let sb = stats[b] ?? (0, .distantPast)
            if sa.count != sb.count { return sa.count > sb.count }
            return sa.lastDate > sb.lastDate
        }
    }

    private func emojiFor(_ category: String) -> String? {
        categoryEmojis[category]
    }

    @State private var displayedMonth: Date = Date()

    /// Days in the currently displayed month
    private func daysInMonth(_ monthDate: Date) -> [Date] {
        let calendar = Calendar.current
        guard let range = calendar.range(of: .day, in: .month, for: monthDate),
              let first = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) else {
            return []
        }
        return range.compactMap { calendar.date(byAdding: .day, value: $0 - 1, to: first) }
    }

    /// Weekday index (0 = Sunday) of the first day of the month
    private func firstWeekdayOffset(_ monthDate: Date) -> Int {
        let calendar = Calendar.current
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: monthDate)) else { return 0 }
        return (calendar.component(.weekday, from: first) + 6) % 7 // Mon=0
    }

    private func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: date)
    }

    private func canGoForward(_ monthDate: Date) -> Bool {
        let calendar = Calendar.current
        let nowComps = calendar.dateComponents([.year, .month], from: Date())
        let dispComps = calendar.dateComponents([.year, .month], from: monthDate)
        return (dispComps.year!, dispComps.month!) < (nowComps.year!, nowComps.month!)
    }

    private func canGoBack(_ monthDate: Date) -> Bool {
        let calendar = Calendar.current
        let earlyComps = calendar.dateComponents([.year, .month], from: earliestDate)
        let dispComps = calendar.dateComponents([.year, .month], from: monthDate)
        return (dispComps.year!, dispComps.month!) > (earlyComps.year!, earlyComps.month!)
    }

    var body: some View {
        NavigationView {
            Form {
                // Date — jump to date navigation
                Section(header: Text("Jump to date")) {
                    Button(action: {
                        displayedMonth = pickedDate
                        showDatePicker = true
                    }) {
                        HStack {
                            Image(systemName: "calendar")
                            Text("Pick a date")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundColor(.secondary)
                                .font(AppFonts.caption)
                        }
                    }
                    .foregroundColor(.primary)
                    .sheet(isPresented: $showDatePicker) {
                        VStack(spacing: 0) {
                            // Month navigation
                            HStack {
                                Button(action: {
                                    if let prev = Calendar.current.date(byAdding: .month, value: -1, to: displayedMonth) {
                                        displayedMonth = prev
                                    }
                                }) {
                                    Image(systemName: "chevron.left")
                                        .font(AppFonts.subhead)
                                }
                                .disabled(!canGoBack(displayedMonth))
                                
                                Spacer()
                                Text(monthTitle(displayedMonth))
                                    .font(.system(size: 20, weight: .bold))
                                Spacer()
                                
                                Button(action: {
                                    if let next = Calendar.current.date(byAdding: .month, value: 1, to: displayedMonth) {
                                        displayedMonth = next
                                    }
                                }) {
                                    Image(systemName: "chevron.right")
                                        .font(AppFonts.subhead)
                                }
                                .disabled(!canGoForward(displayedMonth))
                            }
                            .padding(.horizontal, AppSpacing.xl)
                            .padding(.top, AppSpacing.xxl)
                            .padding(.bottom, AppSpacing.xl)

                            // Weekday headers (Mon–Sun)
                            let weekdaySymbols = ["M", "T", "W", "T", "F", "S", "S"]
                            HStack(spacing: 0) {
                                ForEach(0..<7, id: \.self) { i in
                                    Text(weekdaySymbols[i])
                                        .font(AppFonts.metaText)
                                        .foregroundColor(.secondary)
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)
                            .padding(.bottom, AppSpacing.sm)

                            // Day grid
                            let days = daysInMonth(displayedMonth)
                            let offset = firstWeekdayOffset(displayedMonth)
                            let txDays = transactionDays
                            let calendar = Calendar.current
                            let today = Date()

                            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 6) {
                                // Leading empty cells
                                ForEach(0..<offset, id: \.self) { _ in
                                    Color.clear.frame(height: 40)
                                }
                                ForEach(days, id: \.self) { day in
                                    let comps = calendar.dateComponents([.year, .month, .day], from: day)
                                    let hasData = txDays.contains(comps)
                                    let isSelected = calendar.isDate(day, inSameDayAs: pickedDate)
                                    let isFuture = day > today
                                    let dayNum = calendar.component(.day, from: day)

                                    Button(action: {
                                        pickedDate = day
                                    }) {
                                        Text("\(dayNum)")
                                            .font(.system(size: 16, weight: isSelected ? .bold : .regular))
                                            .foregroundColor(
                                                isFuture ? Color(.systemGray4) :
                                                isSelected ? .white :
                                                hasData ? .primary :
                                                Color(.systemGray3)
                                            )
                                            .frame(width: 40, height: 40)
                                            .background(
                                                isSelected && hasData
                                                    ? Circle().fill(Color.accentColor)
                                                    : isSelected
                                                        ? Circle().fill(Color(.systemGray4))
                                                        : nil
                                            )
                                    }
                                    .disabled(!hasData || isFuture)
                                }
                            }
                            .padding(.horizontal, AppSpacing.md)

                            Spacer(minLength: 12)

                            let selectedComps = calendar.dateComponents([.year, .month, .day], from: pickedDate)
                            let hasTransactions = txDays.contains(selectedComps)

                            Button("Go to date") {
                                showDatePicker = false
                                isPresented = false
                                onJumpToDate?(pickedDate)
                            }
                            .font(.headline)
                            .disabled(!hasTransactions)
                            .padding(.bottom, AppSpacing.xxl)
                        }
                        .presentationDetents([.medium])
                    }
                }

                // Categories — with emoji, sorted by frequency
                Section(header: Text("Categories")) {
                    let cats = sortedCategories
                    let displayCategories = showAllCategories ? cats : Array(cats.prefix(5))
                    ForEach(displayCategories, id: \.self) { cat in
                        let emoji = emojiFor(cat)
                        MultipleSelectionRow(
                            title: cat,
                            emoji: emoji,
                            isSelected: selectedCategories.contains(cat)
                        ) {
                            if selectedCategories.contains(cat) {
                                selectedCategories.remove(cat)
                            } else {
                                selectedCategories.insert(cat)
                            }
                        }
                    }
                    if !showAllCategories && cats.count > 5 {
                        Button(action: { showAllCategories = true }) {
                            Text("Show all \(cats.count) categories")
                                .font(.subheadline)
                                .foregroundColor(.accentColor)
                        }
                    }
                }

                // Transaction Type — plain text, no emoji
                Section(header: Text("Transaction Type")) {
                    ForEach(TransactionType.allCases, id: \.self) { type in
                        Button(action: {
                            if selectedTransactionTypes.contains(type) {
                                selectedTransactionTypes.remove(type)
                            } else {
                                selectedTransactionTypes.insert(type)
                            }
                        }) {
                            HStack {
                                Text(type.label)
                                Spacer()
                                if selectedTransactionTypes.contains(type) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundColor(.accentColor)
                                } else {
                                    Image(systemName: "circle")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }

            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .navigationBarTitle("All Filters", displayMode: .inline)
            .navigationBarItems(
                leading: Button("Clear all") {
                    selectedCategories.removeAll()
                    selectedTransactionTypes.removeAll()
                },
                trailing: Button("Done") { isPresented = false }
            )
        }
    }
}

struct MultipleSelectionRow: View {
    let title: String
    var emoji: String? = nil
    let isSelected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack {
                if let emoji = emoji {
                    Text(emoji).font(.system(size: 18))
                }
                Text(title)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                }
            }
        }
        .foregroundColor(.primary)
    }
}

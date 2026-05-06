import SwiftUI
import Combine

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()

    @State private var showSearchModal: Bool = false
    @State private var showReminders: Bool = false
    @State private var showDebtDetail: Bool = false
    /// Drives the Insights/Analytics sheet, opened from
    /// `PeriodPickerBar`'s "Insights" button. Independent from the
    /// home period filter — switching ranges inside Insights doesn't
    /// affect what the home screen displays.
    @State private var showInsights: Bool = false
    
    @State private var selectedTransaction: Transaction? = nil
    @State private var showTransactionDetail: Bool = false
    @State private var scrollToDate: Date? = nil
    
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var router: NavigationRouter

    @State private var showFilters: Bool = false

    // Стейты для скролла
    @State private var scrollOffset: CGFloat = 0
    @State private var collapseProgress: CGFloat = 0.0
    @State private var scrollToTopTrigger: UUID = UUID()
    @State private var stickyDateText: String = " "
    @State private var stickyDateVisible: Bool = false
    @State private var sectionOffsets: [String: CGFloat] = [:]

    @State private var lastHapticBarIdx: Int? = nil

    // MARK: - Store → ViewModel bridging helpers

    private var resolveCategory: (Transaction) -> String {
        { [categoryStore] tx in categoryStore.validatedCategory(for: tx.category).title }
    }

    private var convert: (Double, String, String) -> Double {
        { [currencyStore] amount, from, to in currencyStore.convert(amount: amount, from: from, to: to) }
    }

    private var filteredTransactions: [Transaction] {
        vm.filteredTransactions(from: transactionStore.homeTransactions, resolveCategory: resolveCategory)
    }

    private var groupedTransactions: [(date: Date, transactions: [Transaction])] {
        vm.groupedTransactions(from: filteredTransactions)
    }

    /// All transactions filtered only by date — used for quick filter candidates
    private var dateFilteredTransactions: [Transaction] {
        TransactionFilterService.filterByDate(transactions: transactionStore.homeTransactions, filter: vm.activeDateFilter)
    }

    private func refreshQuickFilters() {
        vm.refreshQuickFilters(
            allTransactions: transactionStore.homeTransactions,
            resolveCategory: resolveCategory
        )
    }

    // MARK: - Главный Экран
    var body: some View {
        let baseBalance = vm.balanceForPeriod(
            allTransactions: transactionStore.homeTransactions,
            currency: currencyStore.selectedCurrency,
            convert: convert
        )
        let trendBars = vm.trendBars(
            allTransactions: transactionStore.homeTransactions,
            currency: currencyStore.selectedCurrency,
            convert: convert
        )
        let debtSummary = vm.debtSummary(
            allTransactions: transactionStore.transactions,
            currency: currencyStore.selectedCurrency,
            convert: convert
        )
        let extraHeaderTopPadding: CGFloat = AppSizes.headerExtraTopPadding
        // Убрали NavigationView, так как он создавал системные баги с прыжком верхнего SafeArea
        ZStack(alignment: .top) {
            // Строгий черный фон
            AppColors.backgroundPrimary
                .ignoresSafeArea()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        
                        GeometryReader { geoProxy in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: geoProxy.frame(in: .named("scroll")).minY
                            )
                        }
                        .frame(height: 0)
                        .id("topScrollBoundary")
                        
                        if !transactionStore.homeTransactions.isEmpty {
                            // Прозрачный отступ под шапку (учитывает дополнительный верхний padding хедера)
                            Spacer()
                                .frame(height: (vm.hasActiveFilters ? AppSizes.headerFilterHeight : AppSizes.headerExpandedHeight) + extraHeaderTopPadding)
                            
                            // Блок быстрых фильтров и поиска
                            VStack(spacing: AppSpacing.md) {
                                actionButtonsView()
                                    .padding(.horizontal, AppSpacing.pageHorizontal)
                                QuickFiltersBar(
                                    topCategories: vm.cachedTopCategories,
                                    getEmoji: { cat in vm.getEmoji(for: cat, in: categoryStore.categories, transactions: transactionStore.transactions) ?? "📁" },
                                    isActive: { vm.isQuickFilterActive($0) },
                                    onToggle: { vm.toggleQuickFilter($0) }
                                )
                            }
                            .padding(.bottom, AppSpacing.lg)
                        }
                        
                        // Секции транзакций
                        transactionsListView()
                        
                        Spacer().frame(height: 100)
                    }
                }
                .coordinateSpace(name: "scroll")
                .ignoresSafeArea(edges: .top) // Защита от прыжка при возврате из настроек
                .onChange(of: scrollToTopTrigger) { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                        proxy.scrollTo("topScrollBoundary", anchor: .top)
                    }
                }
                .onChange(of: scrollToDate) { date in
                    guard let date = date else { return }
                    let calendar = Calendar.current
                    // Find the section date that matches the picked day
                    if let sectionDate = groupedTransactions.first(where: {
                        calendar.isDate($0.date, inSameDayAs: date)
                    })?.date {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                            proxy.scrollTo(sectionDate, anchor: .top)
                        }
                    } else {
                        // Find the closest earlier section
                        if let closest = groupedTransactions.filter({ $0.date <= date }).first {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
                                proxy.scrollTo(closest.date, anchor: .top)
                            }
                        }
                    }
                    scrollToDate = nil
                }
                .onPreferenceChange(ScrollOffsetKey.self) { value in
                    let currentOffset = min(value, 0)
                    let rawProgress = -currentOffset / AppSizes.headerCollapseThreshold
                    let clamped = min(max(rawProgress, 0.0), 1.0)
                    
                    // Применяем кривую ease-out (синус) для естественного сворачивания
                    collapseProgress = sin(clamped * .pi / 2.0)
                }
                .onPreferenceChange(SectionOffsetPreferenceKey.self) { offsets in
                    let threshold: CGFloat = 200
                    // Find the section whose header is closest above/at the threshold
                    let candidates = offsets.filter { $0.value < threshold }
                    if let current = candidates.min(by: { $0.value > $1.value }) {
                        // Always update text to the topmost visible section
                        if stickyDateText != current.key { stickyDateText = current.key }
                        if !stickyDateVisible { stickyDateVisible = true }
                    } else {
                        // No section has scrolled past threshold — hide sticky header
                        if stickyDateVisible { stickyDateVisible = false }
                    }
                }
            }
            
            // 2. ZSTACK HEADER
            if !transactionStore.homeTransactions.isEmpty {
            VStack(spacing: 0) {
                BalanceHeaderView(
                    balance: baseBalance,
                    onCurrencyChange: { code in currencyStore.selectedCurrency = code },
                    dateFilter: $vm.dateFilter,
                    hoveredBarIdx: $vm.hoveredBarIdx,
                    lastHapticBarIdx: $lastHapticBarIdx,
                    trendBars: trendBars,
                    debtSummary: debtSummary,
                    friends: friendStore.friends,
                    onDebtTap: { showDebtDetail = true },
                    collapseProgress: collapseProgress,
                    onTap: { scrollToTopTrigger = UUID() },
                    extraTopPadding: extraHeaderTopPadding,
                    onInsightsTap: { showInsights = true }
                )
                .environmentObject(currencyStore)
                
                if vm.hasActiveFilters {
                    ActiveFiltersBar(
                        activeCategories: vm.activeCategories,
                        activeTypes: vm.activeTypes,
                        getEmoji: { cat in vm.getEmoji(for: cat, in: categoryStore.categories, transactions: transactionStore.transactions) ?? "📁" },
                        onRemoveCategory: { vm.activeCategories.remove($0) },
                        onRemoveType: { vm.activeTypes.remove($0) },
                        onClearAll: { vm.clearAllFilters() }
                    )
                }
                
                // Sticky date header — persistent element, text updates in-place
                StickyDateLabel(text: stickyDateText, visible: stickyDateVisible && !groupedTransactions.isEmpty)
            }
            .background(
                ZStack {
                    // Adaptive blur material (no forced scheme) — fades in with scroll
                    Color.clear
                        .background(.ultraThinMaterial)
                        .opacity(collapseProgress > 0.05 ? min(Double(collapseProgress) * 2.0, 1.0) : 0)
                    // Adaptive overlay from tokens — only visible when scrolling
                    AppColors.backgroundOverlay
                        .opacity(collapseProgress > 0.05 ? min(Double(collapseProgress) * 2.0, 1.0) : 0)
                }
                .ignoresSafeArea(edges: .top)
            )
            .overlay(
                Divider().background(AppColors.border).opacity(collapseProgress > 0.9 ? 1 : 0), alignment: .bottom
            )
            .overlay(alignment: .topLeading) {
                remindersButton
            }
            .zIndex(1)
            } // end if !isEmpty

            // Empty state — centred on screen whenever the user has
            // no past-dated transactions for Home. Previously gated
            // on **both** home + reminder transactions being empty,
            // but that left a blank middle when a user had reminders
            // only: the BalanceHeader VStack is also gated on
            // `!homeTransactions.isEmpty`, so neither rendered.
            // Reminders stay reachable via the top-left toolbar
            // button — the empty state can claim the centre.
            if transactionStore.homeTransactions.isEmpty {
                EmptyTransactionsView()
                    .zIndex(0)
            }
        }
        // Empty home hides the BalanceHeader VStack (and with it the
        // header-overlay reminders chip), so we re-render the chip
        // here at the same top-leading anchor. Without this, a user
        // whose only entries are reminders has no entry point to the
        // Reminders sheet.
        .overlay(alignment: .topLeading) {
            if transactionStore.homeTransactions.isEmpty {
                remindersButton
            }
        }
        .sheet(isPresented: $showReminders) {
            RemindersView()
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(friendStore)
                .environmentObject(currencyStore)
        }
        .sheet(isPresented: $showDebtDetail) {
            DebtSummaryView()
                .environmentObject(transactionStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
                .environmentObject(categoryStore)
        }
        // Insights/Analytics screen — presented from the Insights
        // button in PeriodPickerBar. We pass the same store
        // environment as the other sheets so the analytics service
        // can read transactions, categories (for live emoji), and
        // currencies (for amount conversion).
        .sheet(isPresented: $showInsights) {
            InsightsView()
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(currencyStore)
        }
        .sheet(isPresented: $showFilters, onDismiss: {
            vm.applyFilterSheet()
        }) {
            FilterSheetView(
                isPresented: $showFilters,
                selectedCategories: $vm.filterSheetCategories,
                selectedTransactionTypes: $vm.filterSheetTypes,
                allCategories: categoryStore.categories.map { $0.title },
                allTransactions: transactionStore.homeTransactions,
                onJumpToDate: { date in
                    scrollToDate = date
                },
                categoryEmojis: Dictionary(uniqueKeysWithValues: categoryStore.categories.map { ($0.title, $0.emoji) })
            )
        }
        .sheet(isPresented: $showSearchModal) {
            SearchTransactionsView(
                isPresented: $showSearchModal,
                transactions: filteredTransactions,
                onSelect: { tx in
                    selectedTransaction = tx
                    showTransactionDetail = true
                }
            )
        }
        .sheet(isPresented: Binding(
            get: { showTransactionDetail && selectedTransaction != nil },
            set: { newValue in
                if (!newValue) {
                    showTransactionDetail = false
                    selectedTransaction = nil
                }
            }
        )) {
            if let tx = selectedTransaction {
                TransactionDetailView(
                    transaction: tx,
                    onEdit: {
                        let txToEdit = tx
                        showTransactionDetail = false
                        selectedTransaction = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            router.showEditTransaction(txToEdit)
                        }
                    },
                    onDelete: {
                        transactionStore.delete(id: tx.id)
                        showTransactionDetail = false
                        selectedTransaction = nil
                    },
                    onClose: {
                        showTransactionDetail = false
                        selectedTransaction = nil
                    }
                )
                .environmentObject(categoryStore)
                .environmentObject(transactionStore)
                .environmentObject(friendStore)
                .environmentObject(currencyStore)
            }
        }
        .task {
            transactionStore.processRecurringSpawns()
            refreshQuickFilters()
            currencyStore.updateTransactions(transactionStore.homeTransactions)
        }
        .onChange(of: transactionStore.transactions.count) { _ in
            transactionStore.processRecurringSpawns()
            refreshQuickFilters()
            currencyStore.updateTransactions(transactionStore.homeTransactions)
        }
        .onChange(of: vm.activeDateFilter) { _ in refreshQuickFilters() }
    }

    // MARK: - Вынесенные UI Компоненты

    @ViewBuilder
    private func actionButtonsView() -> some View {
        HStack {
            Text("QUICK FILTERS")
                .font(AppFonts.labelSmall)
                .foregroundColor(AppColors.textSecondary)
                .tracking(1.0)
            
            Spacer()
            
            Button(action: { showSearchModal = true }) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.accentColor)
                    Text("Search")
                        .foregroundColor(AppColors.textPrimary)
                }
                .font(AppFonts.labelCaption)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColors.backgroundElevated)
                .cornerRadius(AppRadius.large)
            }
            
            Button(action: {
                vm.prepareFilterSheet()
                showFilters = true
            }) {
                HStack(spacing: 6) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundColor(.accentColor)
                    Text("All Filters")
                        .foregroundColor(AppColors.textPrimary)
                }
                .font(AppFonts.labelCaption)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, AppSpacing.sm)
                .background(AppColors.backgroundElevated)
                .cornerRadius(AppRadius.large)
            }
        }
    }

    @ViewBuilder
    private func transactionsListView() -> some View {
        if !transactionStore.homeTransactions.isEmpty && groupedTransactions.isEmpty {
            VStack {
                Spacer().frame(height: 50)
                Text("No transactions match the selected filters")
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity)
        } else if !transactionStore.homeTransactions.isEmpty {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(groupedTransactions, id: \.date) { group in
                    let label = vm.formattedSectionDate(group.date)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(label)
                            .font(AppFonts.sectionHeader)
                            .foregroundColor(AppColors.textSecondary)
                            .tracking(1.0)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.top, AppSpacing.xxl)
                            .padding(.bottom, AppSpacing.sm)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: SectionOffsetPreferenceKey.self,
                                        value: [label: geo.frame(in: .named("scroll")).minY]
                                    )
                                }
                            )
                        
                        ForEach(Array(group.transactions.enumerated()), id: \.element.id) { idx, tx in
                            TransactionRowView(
                                transaction: tx,
                                emoji: vm.validatedEmoji(for: tx, in: categoryStore.categories),
                                isLast: idx == group.transactions.count - 1,
                                onTap: {
                                    selectedTransaction = tx
                                    showTransactionDetail = true
                                },
                                onDelete: {
                                    transactionStore.delete(id: tx.id)
                                }
                            )
                        }
                    }
                    .id(group.date)
                }
            }
        }
    }

    // Top-left toolbar chip — opens the Reminders sheet. Native iOS
    // 26 Liquid Glass capsule so the chip refracts whatever scrolls
    // beneath (trend chart in non-empty mode, empty illustration in
    // empty mode) instead of sitting flat on top of it.
    @ViewBuilder
    private var remindersButton: some View {
        let count = vm.reminderCount(from: transactionStore.transactions)
        Button(action: { showReminders = true }) {
            HStack(spacing: 5) {
                Image(systemName: count > 0 ? "clock.badge" : "clock")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(count > 0 ? AppColors.reminderAccent : AppColors.textSecondary)
                if count > 0 {
                    Text("\(count)")
                        .font(AppFonts.footnote)
                        .foregroundColor(AppColors.textPrimary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, AppSpacing.md)
            .padding(.vertical, AppSpacing.sm)
            .glassEffect(.regular, in: .capsule)
            // Explicit hit shape so taps register reliably across the
            // whole pill (not just the icon/text glyphs).
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .padding(.leading, AppSpacing.md)
    }

    // MARK: - Helper Methods (moved to HomeViewModel + TransactionFilterService)
}

// MARK: - Sticky Date Label (flicker-free)

struct StickyDateLabel: View, Equatable {
    let text: String
    let visible: Bool

    static func == (lhs: StickyDateLabel, rhs: StickyDateLabel) -> Bool {
        lhs.text == rhs.text && lhs.visible == rhs.visible
    }

    var body: some View {
        Text(text)
            .font(AppFonts.sectionHeader)
            .foregroundColor(AppColors.textTertiary)
            .tracking(1.0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.vertical, AppSpacing.sm)
            .opacity(visible ? 1 : 0)
            .animation(nil, value: text)
            .animation(nil, value: visible)
    }
}

// DateFilterType and TrendBarPoint moved to Models/FilterTypes.swift

struct HomeView_Previews: PreviewProvider {
    static var previews: some View {
        HomeView()
    }
}

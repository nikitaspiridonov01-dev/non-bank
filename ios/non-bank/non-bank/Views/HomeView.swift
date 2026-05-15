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
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    @EnvironmentObject var router: NavigationRouter

    /// Observed so the home balance / trend / per-row display rebuild
    /// the moment the user flips the "include potential expenses"
    /// switch in Settings — without re-rendering, the numbers would
    /// stay stale until the next mutation in `transactionStore`.
    @ObservedObject private var insightsSettings = InsightsSettings.shared

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
        // Balance and trend bars sum amounts, so they go through the
        // insights-normalised list (drops `excludedFromInsights`, swaps
        // split `amount` for `myShare` when the setting is ON). The
        // raw `homeTransactions` is reserved for the list view below —
        // the user should still see (and unhide) excluded rows.
        let insightsHome = transactionStore.homeTransactionsForInsights
        let baseBalance = vm.balanceForPeriod(
            allTransactions: insightsHome,
            currency: currencyStore.selectedCurrency,
            convert: convert
        )
        let trendBars = vm.trendBars(
            allTransactions: insightsHome,
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
            .overlay(alignment: .topTrailing) {
                scanReceiptButton
            }
            .zIndex(1)
            } // end if !isEmpty

            // Cold-start skeleton state. Shown while the first
            // `transactionStore.load()` is still in flight so the user
            // sees a hint of "stuff is coming" instead of a flash of
            // the empty illustration (which would look like "you have
            // nothing" for a beat before the real list pops in).
            if !transactionStore.hasLoadedOnce && transactionStore.homeTransactions.isEmpty {
                SkeletonTransactionList()
                    .zIndex(0)
            } else if transactionStore.homeTransactions.isEmpty {
                // Empty state — centred on screen whenever the user has
                // no past-dated transactions for Home. Previously gated
                // on **both** home + reminder transactions being empty,
                // but that left a blank middle when a user had reminders
                // only: the BalanceHeader VStack is also gated on
                // `!homeTransactions.isEmpty`, so neither rendered.
                // Reminders stay reachable via the top-left toolbar
                // button — the empty state can claim the centre.
                EmptyTransactionsView(onAdd: { router.showCreateTransaction() })
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
        // Top-right corner: scan-receipt entry point. Same geometry
        // as `remindersButton` (left-side chip) so the two visually
        // bracket the header without one being taller than the other.
        .overlay(alignment: .topTrailing) {
            if transactionStore.homeTransactions.isEmpty {
                scanReceiptButton
            }
        }
        .sheet(isPresented: $showReminders) {
            RemindersView()
                .environmentObject(transactionStore)
                .environmentObject(categoryStore)
                .environmentObject(friendStore)
                .environmentObject(currencyStore)
                .environmentObject(receiptItemStore)
        }
        .sheet(isPresented: $showDebtDetail) {
            DebtSummaryView()
                .environmentObject(transactionStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
                .environmentObject(categoryStore)
                .environmentObject(receiptItemStore)
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
                .environmentObject(receiptItemStore)
            }
        }
        .task {
            transactionStore.processRecurringSpawns()
            refreshQuickFilters()
            currencyStore.updateTransactions(transactionStore.homeTransactions)
        }
        // `.onChange(of: array)` — Transaction is Equatable, so this
        // fires on add/edit/delete (the previous `.onReceive($transactions)`
        // would intermittently fail to populate `cachedTopCategories`
        // on first launch — the publisher's emission timing didn't
        // line up with the subscription, and the QUICK FILTERS row
        // would render with the header but no chips).
        .onChange(of: transactionStore.transactions) { _ in
            transactionStore.processRecurringSpawns()
            refreshQuickFilters()
            currencyStore.updateTransactions(transactionStore.homeTransactions)
        }
        // Re-run when the categories finish loading too — first
        // launch can race the `.task` fire (which uses `resolveCategory`
        // off `categoryStore`) against the store's async DB load. If
        // categories arrive after the first refresh, the cached
        // top-categories would be stuck on whatever was resolvable at
        // task time.
        .onChange(of: categoryStore.categories.count) { _ in
            refreshQuickFilters()
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
                    .foregroundColor(AppColors.textSecondary)
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

    // MARK: - Header toolbar chips
    //
    // The Home header doesn't have a real `NavigationStack` toolbar
    // (the screen is laid out as a `ScrollView` with overlays), so we
    // hand-build the chips. To keep them pixel-identical to the
    // native `ToolbarItem` chips on every other screen (create
    // transaction, debts, friend detail), all three icon-only chips
    // — reminder default, reminder-with-counter (capsule because the
    // text widens it), and scan — share the same metrics:
    //
    //   • Fixed 36 × 36 pt visible footprint (iOS-26 toolbar metric)
    //   • 17 pt semibold glyph (`AppFonts.bodyEmphasized`)
    //   • `glassEffect(.regular, in: .circle)` for the icon-only
    //     variants → renders as a clean disc identical to the system
    //     button shape; the reminder-with-counter variant switches to
    //     `.capsule` because the digit makes it elongate horizontally.

    /// Common chip diameter / row height. 36 pt matches the rendered
    /// width of an iOS 26 `.primaryAction` toolbar item, so the Home
    /// chips and the create-transaction toolbar icon read at the
    /// same size when the user pivots between screens.
    private static let headerChipSize: CGFloat = 36

    @ViewBuilder
    private var remindersButton: some View {
        let count = vm.reminderCount(from: transactionStore.transactions)
        Button(action: { showReminders = true }) {
            if count > 0 {
                // Counter present → capsule (icon + digit stack).
                // Pinned to `headerChipSize` height so the chip lines
                // up with the scan disc on the right.
                HStack(spacing: 5) {
                    Image(systemName: "clock.badge")
                        .font(AppFonts.bodyEmphasized)
                        .foregroundColor(AppColors.reminderAccent)
                    Text("\(count)")
                        .font(AppFonts.footnote)
                        .foregroundColor(AppColors.textPrimary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 10)
                .frame(height: Self.headerChipSize)
                .glassEffect(.regular, in: .capsule)
                .contentShape(Capsule())
            } else {
                // No counter → perfect circle, same shape + size as
                // the scan disc. Image is intrinsic-sized; the fixed
                // 36 × 36 frame centres it deterministically.
                Image(systemName: "clock")
                    .font(AppFonts.bodyEmphasized)
                    .foregroundColor(AppColors.textSecondary)
                    .frame(width: Self.headerChipSize, height: Self.headerChipSize)
                    .glassEffect(.regular, in: .circle)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.plain)
        // VoiceOver: glyph-only chip with no inline text. Read out
        // the pending count when present so users hear "Reminders,
        // 3 pending" rather than a bare "Button". Same label drives
        // Voice Control's verbal addressing of the button.
        .accessibilityLabel(count > 0 ? "Reminders, \(count) pending" : "Reminders")
        .padding(.top, 6)
        .padding(.leading, AppSpacing.md)
    }

    @ViewBuilder
    private var scanReceiptButton: some View {
        Button(action: {
            router.showCreateTransaction(autoOpenScanFlow: true)
        }) {
            Image(systemName: "viewfinder")
                .font(AppFonts.bodyEmphasized)
                .foregroundColor(AppColors.textSecondary)
                .frame(width: Self.headerChipSize, height: Self.headerChipSize)
                .glassEffect(.regular, in: .circle)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Scan receipt")
        .accessibilityHint("Opens the camera to capture a receipt")
        .padding(.top, 6)
        .padding(.trailing, AppSpacing.md)
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

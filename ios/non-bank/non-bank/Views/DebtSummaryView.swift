import SwiftUI

struct DebtSummaryView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var categoryStore: CategoryStore

    @State private var selectedTransaction: Transaction? = nil
    @State private var showTransactionDetail: Bool = false
    @State private var editingTransaction: Transaction? = nil
    /// Active group filter. `nil` = all groups.
    @State private var selectedGroup: String? = nil

    private var convert: (Double, String, String) -> Double {
        { [currencyStore] amount, from, to in
            currencyStore.convert(amount: amount, from: from, to: to)
        }
    }

    /// Friend IDs that belong to the currently selected group. `nil` means
    /// no filter is active and all transactions should be considered.
    private var friendIDsInSelectedGroup: Set<String>? {
        guard let group = selectedGroup else { return nil }
        return Set(friendStore.friends.filter { $0.groups.contains(group) }.map(\.id))
    }

    /// Transactions restricted to the active group. A transaction passes when
    /// *all* of its split participants are friends in the selected group —
    /// mixed-group transactions are excluded so the view stays "pure".
    private var groupFilteredTransactions: [Transaction] {
        let all = transactionStore.transactions
        guard let groupFriendIDs = friendIDsInSelectedGroup else { return all }
        return all.filter { tx in
            let ids = tx.splitInfo?.friends.map(\.friendID) ?? []
            guard !ids.isEmpty else { return false }
            return ids.allSatisfy { groupFriendIDs.contains($0) }
        }
    }

    private var pastSplitTransactions: [Transaction] {
        SplitDebtService.pastSplitTransactions(from: groupFilteredTransactions)
    }

    /// Group-filtered summary — drives the debts rows and the transactions list.
    private var summary: SimplifiedDebtsSummary {
        SplitDebtService.simplifiedDebts(
            transactions: groupFilteredTransactions,
            targetCurrency: currencyStore.selectedCurrency,
            convert: convert
        )
    }

    /// Total summary across *all* transactions — used for the header amount and
    /// label so the "You lent in total / You borrow in total" value stays
    /// constant while the user flips group filters.
    private var totalSummary: SimplifiedDebtsSummary {
        SplitDebtService.simplifiedDebts(
            transactions: transactionStore.transactions,
            targetCurrency: currencyStore.selectedCurrency,
            convert: convert
        )
    }

    private var groupedTransactions: [(date: Date, transactions: [Transaction])] {
        TransactionFilterService.groupByDay(pastSplitTransactions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    headerTitle
                    groupsChipBar
                    debtsSection
                    transactionsSection
                    Spacer().frame(height: 40)
                }
            }
            .background(AppColors.backgroundPrimary)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark")
                            .font(AppFonts.bodySmallEmphasized)
                            .foregroundColor(AppColors.textPrimary)
                    }
                }
            }
            .navigationDestination(for: FriendDetailRoute.self) { route in
                if let friend = friendStore.friend(byID: route.friendID) {
                    FriendDetailView(friend: friend)
                        .environmentObject(transactionStore)
                        .environmentObject(currencyStore)
                        .environmentObject(friendStore)
                        .environmentObject(categoryStore)
                } else {
                    // Defensive: friend record is gone from FriendStore
                    // but transactions still reference the ID (legacy
                    // data from before we added the delete guard). Show
                    // a graceful placeholder instead of an empty grey
                    // navigation page.
                    deletedFriendPlaceholder
                }
            }
            .sheet(isPresented: Binding(
                get: { showTransactionDetail && selectedTransaction != nil },
                set: { newValue in
                    if !newValue {
                        showTransactionDetail = false
                        selectedTransaction = nil
                    }
                }
            )) {
                if let selected = selectedTransaction,
                   let tx = transactionStore.transactions.first(where: { $0.id == selected.id }) {
                    TransactionDetailView(
                        transaction: tx,
                        onEdit: {
                            editingTransaction = tx
                        },
                        onDelete: {
                            transactionStore.delete(id: tx.id)
                            showTransactionDetail = false
                            selectedTransaction = nil
                        },
                        onClose: {
                            showTransactionDetail = false
                            selectedTransaction = nil
                        },
                        source: .debts
                    )
                    .environmentObject(categoryStore)
                    .environmentObject(transactionStore)
                    .environmentObject(friendStore)
                    .environmentObject(currencyStore)
                    .sheet(item: $editingTransaction) { editTx in
                        CreateTransactionModal(
                            isPresented: Binding(
                                get: { true },
                                set: { if !$0 { editingTransaction = nil } }
                            ),
                            editingTransaction: editTx
                        )
                        .environmentObject(categoryStore)
                        .environmentObject(transactionStore)
                        .environmentObject(currencyStore)
                        .environmentObject(friendStore)
                    }
                }
            }
        }
    }

    // MARK: - Header

    @ViewBuilder
    /// Shown when a Friend record can't be resolved by ID — we got
    /// here from a transaction that still references a deleted friend.
    /// Pre-Phase-X data could land here; new deletions are blocked by
    /// `FriendsView.handleDelete`.
    private var deletedFriendPlaceholder: some View {
        VStack(spacing: 14) {
            Spacer().frame(height: 40)
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56, weight: .light))
                .foregroundColor(AppColors.textTertiary)
            Text("Contact unavailable")
                .font(AppFonts.subhead)
                .foregroundColor(AppColors.textPrimary)
            Text("This friend was removed from your contacts but still appears in some transactions. Edit those transactions to assign a different participant.")
                .font(AppFonts.caption)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xxxl)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppColors.backgroundPrimary)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var headerTitle: some View {
        VStack(spacing: AppSpacing.md) {
            PixelCatView(id: UserIDService.currentID(), size: 72, blackAndWhite: false)
                .clipShape(Circle())
            Text(headerLabelText)
                .font(AppFonts.bodyLarge)
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            headerAmount
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, AppSpacing.xxl)
        .padding(.bottom, AppSpacing.xxl)
    }

    private var headerLabelText: String {
        switch totalSummary.status {
        case .settled:     return "You're settled with all your friends"
        case .youLent:     return "You lent in total"
        case .youOwe:      return "You borrow in total"
        }
    }

    @ViewBuilder
    private var headerAmount: some View {
        switch totalSummary.status {
        case .settled:
            // No amount / no currency — the label already conveys the state.
            EmptyView()
        case .youLent(let amount), .youOwe(let amount):
            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                Text(NumberFormatting.integerPart(amount))
                    .font(AppFonts.balanceInteger)
                    .foregroundColor(AppColors.textPrimary)
                    .kerning(2)
                Text(NumberFormatting.decimalPart(amount))
                    .font(AppFonts.balanceDecimal)
                    .foregroundColor(AppColors.textPrimary.opacity(0.8))
                currencyMenu
                    .padding(.leading, AppSpacing.xs)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
        }
    }

    /// Tappable currency picker — synchronized with the global `selectedCurrency`,
    /// so changing it here also updates the Home header.
    private var currencyMenu: some View {
        Menu {
            ForEach(currencyStore.currencyOptions, id: \.self) { code in
                Button {
                    currencyStore.selectedCurrency = code
                } label: {
                    Text("\(code) \(CurrencyInfo.byCode[code]?.emoji ?? "💱")")
                }
            }
        } label: {
            Text(currencyStore.selectedCurrency)
                .font(AppFonts.balanceCurrency)
                .foregroundColor(AppColors.balanceCurrency)
        }
    }

    // MARK: - Groups Filter

    /// Horizontal chip scroll with an "All" chip plus one chip per group the
    /// user has defined. Hidden entirely when no groups exist.
    @ViewBuilder
    private var groupsChipBar: some View {
        let groups = friendStore.allGroups
        if groups.isEmpty {
            EmptyView()
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    GroupChip(
                        label: "All",
                        isActive: selectedGroup == nil
                    ) {
                        selectedGroup = nil
                    }
                    ForEach(groups, id: \.self) { group in
                        GroupChip(
                            label: group,
                            isActive: selectedGroup == group
                        ) {
                            selectedGroup = (selectedGroup == group) ? nil : group
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
            }
            .padding(.bottom, AppSpacing.lg)
        }
    }

    // MARK: - Debts Section

    @ViewBuilder
    private var debtsSection: some View {
        VStack(spacing: AppSpacing.sm) {
            ForEach(summary.rows) { row in
                let friend = friendStore.friend(byID: row.friendID)
                let friendName = friend?.name ?? "Friend"
                NavigationLink(value: FriendDetailRoute(friendID: row.friendID)) {
                    DebtRowView(
                        kind: rowKind(for: row, friendName: friendName),
                        currency: currencyStore.selectedCurrency,
                        isConnected: friend?.isConnected ?? false
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    private func rowKind(for row: SimplifiedDebt, friendName: String) -> DebtRowView.Kind {
        if abs(row.amount) < 0.005 {
            return .balancesOut(friendID: row.friendID, friendName: friendName)
        }
        if row.amount > 0 {
            return .youLent(friendID: row.friendID, friendName: friendName, amount: row.amount)
        }
        return .youBorrow(friendID: row.friendID, friendName: friendName, amount: abs(row.amount))
    }

    // MARK: - Transactions Section

    @ViewBuilder
    private var transactionsSection: some View {
        if groupedTransactions.isEmpty {
            VStack {
                Spacer().frame(height: 40)
                Text("No split transactions")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(groupedTransactions, id: \.date) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        SectionHeader(text: formattedSectionDate(group.date), color: AppColors.textSecondary)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.top, AppSpacing.xxl)
                            .padding(.bottom, AppSpacing.sm)

                        ForEach(Array(group.transactions.enumerated()), id: \.element.id) { idx, tx in
                            DebtTransactionRowView(
                                transaction: tx,
                                emoji: categoryStore.validatedCategory(for: tx.category).emoji,
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
                }
            }
        }
    }

    // MARK: - Formatting

    private func formattedSectionDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let isCurrentYear = calendar.component(.year, from: date) == calendar.component(.year, from: Date())
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = isCurrentYear ? "EEE, MMM d" : "EEE, MMM d, yyyy"
        return formatter.string(from: date).uppercased()
    }
}

// MARK: - Navigation Route

struct FriendDetailRoute: Hashable {
    let friendID: String
}

// MARK: - Debt Row

struct DebtRowView: View {
    enum Kind {
        case balancesOut(friendID: String, friendName: String)
        case youLent(friendID: String, friendName: String, amount: Double)
        case youBorrow(friendID: String, friendName: String, amount: Double)
    }

    let kind: Kind
    let currency: String
    /// `true` when the friend is a real user (their ID matches a real
    /// userID via share-link round-trip or phantom upgrade). Drives
    /// the avatar colour: connected → coloured, manual contact → B&W.
    /// Defaults to `false` (grayscale) so callers that haven't yet
    /// been updated render with the safe legacy treatment.
    var isConnected: Bool = false

    var body: some View {
        HStack(spacing: AppSpacing.md) {
            avatar
            label
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .frame(maxWidth: .infinity)
        .background(AppColors.backgroundElevated)
        .cornerRadius(AppRadius.large)
    }

    // MARK: - Avatar

    @ViewBuilder
    private var avatar: some View {
        switch kind {
        case .balancesOut(let friendID, _),
             .youLent(let friendID, _, _),
             .youBorrow(let friendID, _, _):
            PixelCatView(id: friendID, size: 32, blackAndWhite: !isConnected)
                .clipShape(Circle())
        }
    }

    // MARK: - Label

    @ViewBuilder
    private var label: some View {
        switch kind {
        case .balancesOut(_, let name):
            Text(name)
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textPrimary)
        case .youLent(_, let name, _):
            Text("You lent ").font(AppFonts.labelPrimary).foregroundColor(AppColors.textSecondary)
                + Text(name).font(AppFonts.labelPrimary).foregroundColor(AppColors.textPrimary)
        case .youBorrow(_, let name, _):
            Text("You borrow ").font(AppFonts.labelPrimary).foregroundColor(AppColors.textSecondary)
                + Text(name).font(AppFonts.labelPrimary).foregroundColor(AppColors.textPrimary)
        }
    }

    // MARK: - Trailing

    @ViewBuilder
    private var trailing: some View {
        switch kind {
        case .balancesOut:
            Text("balances out")
                .font(AppFonts.labelCaption)
                .foregroundColor(AppColors.textSecondary)
        case .youLent(_, _, let amount),
             .youBorrow(_, _, let amount):
            amountText(amount)
        }
    }

    private func amountText(_ amount: Double) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(NumberFormatting.integerPart(amount))
                .font(AppFonts.rowAmountInteger)
                .foregroundColor(AppColors.textPrimary)
            Text(NumberFormatting.decimalPartIfAny(amount))
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
            Text(currency)
                .font(AppFonts.rowAmountCurrency)
                .foregroundColor(AppColors.textSecondary)
                .padding(.leading, 3)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}

// MARK: - Group Chip

struct GroupChip: View {
    let label: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppFonts.labelCaption)
                .foregroundColor(isActive ? AppColors.textOnAccent : AppColors.textPrimary)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(isActive ? AppColors.balanceCurrency : AppColors.backgroundChip)
                )
        }
        .buttonStyle(.plain)
    }
}

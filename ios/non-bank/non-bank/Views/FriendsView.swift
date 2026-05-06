import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var transactionStore: TransactionStore
    @State private var searchText = ""
    @State private var selectedGroup: String? = nil
    @State private var sheetFriend: FriendSheetItem? = nil
    /// Drives the "can't delete — friend has transactions" alert. We
    /// stash the offending friend + transaction count for the alert
    /// message so the user knows exactly why the swipe-delete didn't
    /// take effect.
    @State private var deleteBlockedFriend: (friend: Friend, txCount: Int)? = nil

    /// Wrapper to distinguish create vs edit vs view in a single sheet
    private enum FriendSheetItem: Identifiable {
        case create
        case view(Friend)
        case edit(Friend)
        var id: String {
            switch self {
            case .create: return "__create__"
            case .view(let f): return "__view__\(f.id)"
            case .edit(let f): return "__edit__\(f.id)"
            }
        }
    }

    private var filteredFriends: [Friend] {
        var result = friendStore.friends

        if let group = selectedGroup {
            result = result.filter { $0.groups.contains(group) }
        }

        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.id.lowercased().contains(query) ||
                $0.groups.contains(where: { $0.lowercased().contains(query) })
            }
        }

        return result
    }

    var body: some View {
        List {
            if !friendStore.allGroups.isEmpty {
                groupFilterSection
            }

            if filteredFriends.isEmpty {
                emptyState
            } else {
                friendsListSection
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .searchable(text: $searchText, prompt: "Search friends")
        .navigationTitle("Friends")
        // The parent `SettingsView` calls `.navigationBarHidden(true)`
        // for its own screen. That leaks into pushed children inside
        // `NavigationView` and forces an inline title here. Re-exposing
        // the bar + asking for a large title explicitly restores the
        // Reminders-style hero header on this screen only.
        .navigationBarHidden(false)
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { sheetFriend = .create }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $sheetFriend) { item in
            switch item {
            case .create:
                FriendFormView(existingGroups: friendStore.allGroups) { newFriend in
                    Task { await friendStore.add(newFriend) }
                }
            case .view(let friend):
                FriendCardView(friend: friend) {
                    sheetFriend = nil
                    // Small delay so the dismiss animation finishes before presenting edit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        sheetFriend = .edit(friend)
                    }
                }
            case .edit(let friend):
                FriendFormView(
                    friend: friend,
                    existingGroups: friendStore.allGroups
                ) { updated in
                    friendStore.update(updated)
                }
            }
        }
        // "Cannot delete" alert. Driven by `deleteBlockedFriend`
        // (non-nil when the swipe-action found referencing transactions).
        // Tells the user how many transactions are blocking and what
        // their options are — we don't offer "delete anyway" because
        // it'd orphan the transactions and break their debt screens.
        .alert(
            "Can't delete this friend",
            isPresented: Binding(
                get: { deleteBlockedFriend != nil },
                set: { if !$0 { deleteBlockedFriend = nil } }
            ),
            presenting: deleteBlockedFriend
        ) { _ in
            Button("OK", role: .cancel) { deleteBlockedFriend = nil }
        } message: { ctx in
            let txWord = ctx.txCount == 1 ? "transaction" : "transactions"
            Text("\(ctx.friend.name) is part of \(ctx.txCount) split \(txWord). Delete those transactions first, or keep the contact for history.")
        }
    }

    // MARK: - Group Filter

    private var groupFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    groupChip(label: "All", isSelected: selectedGroup == nil) {
                        selectedGroup = nil
                    }
                    ForEach(friendStore.allGroups, id: \.self) { group in
                        groupChip(label: group, isSelected: selectedGroup == group) {
                            selectedGroup = (selectedGroup == group) ? nil : group
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.xs)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }

    private func groupChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppFonts.captionEmphasized)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.15) : AppColors.backgroundChip)
                .foregroundColor(isSelected ? .accentColor : AppColors.textPrimary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Friends List

    private var friendsListSection: some View {
        Section {
            ForEach(filteredFriends) { friend in
                friendRow(friend)
                    .listRowInsets(EdgeInsets(
                        top: AppSpacing.xxs,
                        leading: AppSpacing.pageHorizontal,
                        bottom: AppSpacing.xxs,
                        trailing: AppSpacing.pageHorizontal
                    ))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            handleDelete(friend)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(AppColors.danger)
                    }
            }
        }
    }

    /// Guarded delete: blocked when this friend appears in any
    /// `splitInfo.friends`, because removing them would orphan those
    /// transactions (debt screens then resolve no `Friend` record and
    /// render a blank page). The alert tells the user what to do —
    /// delete the transactions first or just keep the contact.
    private func handleDelete(_ friend: Friend) {
        let count = transactionsReferencing(friend).count
        if count > 0 {
            deleteBlockedFriend = (friend, count)
            return
        }
        friendStore.remove(friend)
    }

    /// Transactions whose `splitInfo.friends` references the given
    /// friend ID. Computed at delete-time only (not on every render),
    /// so the cost is fine even on large transaction lists.
    private func transactionsReferencing(_ friend: Friend) -> [Transaction] {
        transactionStore.transactions.filter { tx in
            tx.splitInfo?.friends.contains(where: { $0.friendID == friend.id }) ?? false
        }
    }

    private func friendRow(_ friend: Friend) -> some View {
        // Cream pill-card row, mirroring `WhoPaidPickerView.compactRow`
        // and `DebtRowView` shape so all three friend list surfaces
        // share one visual pattern. Tinted with `backgroundElevated`
        // (cream) instead of `splitCardFill` (lavender) — Friends is
        // a neutral page, not a Split sub-context.
        Button(action: { sheetFriend = .view(friend) }) {
            HStack(spacing: AppSpacing.md) {
                PixelCatView(id: friend.id, size: 36, blackAndWhite: !friend.isConnected)
                    .clipShape(Circle())

                Text(friend.name)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if let mode = friend.splitMode {
                    HStack(spacing: AppSpacing.xs) {
                        SplitModeIcon(mode: mode, size: 18)
                        Text(mode.displayLabel)
                            .font(.system(size: 11))
                            .foregroundColor(AppColors.textTertiary)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.rowVertical)
            .frame(maxWidth: .infinity)
            .background(AppColors.backgroundElevated)
            .cornerRadius(AppRadius.large)
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Section {
            VStack(spacing: AppSpacing.md) {
                // Different pixel figure per state — `emptyBox` reads
                // as "container with nothing in it" for the no-friends-
                // ever case; `search` reads as "active hunt with no
                // hits" for the search-with-zero-results case.
                if searchText.isEmpty {
                    EmptyBoxIllustration(tint: .neutral, size: .standard)
                } else {
                    SearchIllustration(tint: .neutral, size: .standard)
                }
                Text(searchText.isEmpty ? "No friends yet" : "No results")
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textSecondary)
                Button { sheetFriend = .create } label: {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "person.badge.plus")
                            .font(AppFonts.captionEmphasized)
                        Text("Add new friend")
                            .font(AppFonts.captionEmphasized)
                    }
                    .foregroundColor(.accentColor)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
    }
}

// MARK: - Friend Card View
//
// Mirrors `FriendDetailView` (the Debts-tab friend screen) so the
// profile-side friend page and the debts-side friend page share one
// pattern: circular avatar → name → debt-status pill → date-grouped
// past split transactions, on a Split lavender tint. The only
// difference vs the Debts version is the toolbar — Close on the left
// (sheet dismiss) and Edit on the right (forwards to the friend form).

struct FriendCardView: View {
    let friend: Friend
    var onEdit: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var categoryStore: CategoryStore

    @State private var selectedTransaction: Transaction? = nil
    @State private var showTransactionDetail: Bool = false
    @State private var editingTransaction: Transaction? = nil

    private var convert: (Double, String, String) -> Double {
        { [currencyStore] amount, from, to in
            currencyStore.convert(amount: amount, from: from, to: to)
        }
    }

    private var pastSplitTransactions: [Transaction] {
        SplitDebtService.pastSplitTransactions(from: transactionStore.transactions)
            .filter { tx in
                tx.splitInfo?.friends.contains { $0.friendID == friend.id } ?? false
            }
    }

    private var myDebt: SimplifiedDebt? {
        SplitDebtService.simplifiedDebts(
            transactions: transactionStore.transactions,
            targetCurrency: currencyStore.selectedCurrency,
            convert: convert
        )
        .rows
        .first { $0.friendID == friend.id }
    }

    private var groupedTransactions: [(date: Date, transactions: [Transaction])] {
        TransactionFilterService.groupByDay(pastSplitTransactions)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    profileHeader
                    debtStatusRow
                    transactionsSection
                    Spacer().frame(height: 40)
                }
            }
            .background(AppColors.splitBackgroundTint)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if onEdit != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Edit") {
                            dismiss()
                            onEdit?()
                        }
                    }
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
                        onEdit: { editingTransaction = tx },
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

    // MARK: - Profile Header

    @ViewBuilder
    private var profileHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            PixelCatView(id: friend.id, size: 72, blackAndWhite: !friend.isConnected)
                .clipShape(Circle())
                .padding(.bottom, AppSpacing.xs)
            Text(friend.name)
                .font(AppFonts.heading)
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
            FriendIDCopyLine(id: friend.id)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, AppSpacing.xxl)
        .padding(.bottom, AppSpacing.xl)
    }

    // MARK: - Debt Status

    @ViewBuilder
    private var debtStatusRow: some View {
        let currency = currencyStore.selectedCurrency
        let amount = myDebt?.amount ?? 0

        let kind: DebtRowView.Kind = {
            if abs(amount) < 0.005 {
                return .balancesOut(friendID: friend.id, friendName: friend.name)
            }
            if amount > 0 {
                return .youLent(friendID: friend.id, friendName: friend.name, amount: amount)
            }
            return .youBorrow(friendID: friend.id, friendName: friend.name, amount: abs(amount))
        }()

        DebtRowView(kind: kind, currency: currency, isConnected: friend.isConnected)
            .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Transactions Section

    @ViewBuilder
    private var transactionsSection: some View {
        if groupedTransactions.isEmpty {
            VStack(spacing: AppSpacing.md) {
                Spacer().frame(height: 40)
                SleepingCatIllustration(tint: .split, size: .standard)
                Text("No splits yet with \(friend.name)")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, AppSpacing.pageHorizontal)
            }
            .frame(maxWidth: .infinity)
        } else {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(groupedTransactions, id: \.date) { group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(formattedSectionDate(group.date))
                            .font(AppFonts.sectionHeader)
                            .foregroundColor(AppColors.textSecondary)
                            .tracking(AppFonts.sectionHeaderTracking)
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

// MARK: - Friend ID Copy Line
//
// Mono ID with a copy-to-clipboard affordance, matching the user's own
// ID treatment in `SettingsView`. Shared between `FriendCardView`
// (Profile-side friend page) and `FriendDetailView` (Debts-side friend
// page) so the two friend hero pages stay visually identical.

struct FriendIDCopyLine: View {
    let id: String
    @State private var copied = false

    var body: some View {
        Button(action: {
            UIPasteboard.general.string = id
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                copied = false
            }
        }) {
            HStack(spacing: 6) {
                Text(id)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundColor(AppColors.textSecondary)
                    .lineLimit(1)
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12))
                    .foregroundColor(copied ? .green : AppColors.textTertiary)
            }
        }
        .buttonStyle(.plain)
    }
}

import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var router: NavigationRouter
    @Environment(\.analytics) private var analytics
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

    /// True when there's no friend record at all — neither in the store
    /// nor in any group. We swap the List for a centred placeholder
    /// because the search bar / group filter chips have nothing to
    /// operate on, and the List doesn't centre an empty section
    /// vertically.
    private var isFullyEmpty: Bool {
        friendStore.friends.isEmpty
    }

    var body: some View {
        Group {
            if !friendStore.hasLoadedOnce && isFullyEmpty {
                // Cold-launch skeleton — better than flashing the
                // sleeping-cat empty state before SQLite finishes
                // its first `fetchAll`.
                SkeletonTransactionList(rowCount: 4)
            } else if isFullyEmpty {
                emptyPlaceholder
            } else {
                friendsList
            }
        }
        .background(AppColors.backgroundPrimary)
        .navigationTitle("Friends")
        // The parent `SettingsView` calls `.navigationBarHidden(true)`
        // for its own screen. That leaks into pushed children inside
        // `NavigationView` and forces an inline title here. Re-exposing
        // the bar + asking for a large title explicitly restores the
        // Reminders-style hero header on this screen only.
        .navigationBarHidden(false)
        .navigationBarTitleDisplayMode(.large)
        // Hide the global tab bar while this screen is up — the friends
        // list scrolls full-height and the floating tab bar + FAB would
        // overlap the lowest rows (and the per-row swipe / tap targets).
        // Restored centrally by `SettingsView`'s `.onAppear` when the
        // user pops back to the Settings root — same convention as
        // Import / Export Transactions.
        .onAppear { router.hideTabBar = true }
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

    // MARK: - Friends List
    //
    // List with per-row Liquid Glass background pills. Trading
    // ScrollView + LazyVStack for List: SwiftUI's List handles search
    // diffing without dropping scroll position, and per-row glass
    // containers stay stable across cell recycling (one giant glass
    // container around the whole list flickers on scroll/tap).
    // Native `.swipeActions` carries the delete affordance — on guard
    // failure the row stays in place because the data hasn't changed,
    // sidestepping the awkward "row faded out then snaps back" of the
    // earlier `SwipeToDeleteRow` approach.

    private var friendsList: some View {
        List {
            if !friendStore.allGroups.isEmpty {
                groupFilterBar
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: AppSpacing.sm, trailing: 0))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if filteredFriends.isEmpty {
                // Active search returned no rows — inline "No results"
                // (the parent body's `isFullyEmpty` branch only catches
                // the never-had-friends case).
                noResultsInline
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            } else {
                ForEach(filteredFriends) { friend in
                    friendRowContent(friend)
                        // Glass on the content (not via
                        // `listRowBackground`, which would render
                        // edge-to-edge regardless of insets and make
                        // adjacent rows merge into one slab).
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .listRowInsets(EdgeInsets(
                            top: AppSpacing.xs,
                            leading: AppSpacing.pageHorizontal,
                            bottom: AppSpacing.xs,
                            trailing: AppSpacing.pageHorizontal
                        ))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                handleDelete(friend)
                            } label: {
                                // `iconOnly` so iOS renders the trash
                                // glyph the same way on every row
                                // height — without it, taller rows
                                // (with avatars) get a stacked icon+
                                // label and shorter rows get inline,
                                // making the destructive affordance
                                // visually inconsistent across the
                                // Friends / Categories list family.
                                Label("Delete", systemImage: "trash")
                                    .labelStyle(.iconOnly)
                            }
                            .tint(AppColors.danger)
                        }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .searchable(text: $searchText, prompt: "Search friends")
        .onChange(of: searchText) { newQuery in
            // No debounce — friend search is short-list / fast-typing;
            // the spam cost is negligible (≤20 keystrokes per query)
            // and the immediate fire keeps "user is frustrated"
            // closer to the actual frustration moment.
            let trimmed = newQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count >= 3, filteredFriends.isEmpty else { return }
            analytics.track(.searchNoResults(
                searchType: .friends,
                queryLengthBucket: AnalyticsBuckets.queryLength(trimmed.count)
            ))
        }
    }

    private var noResultsInline: some View {
        VStack(spacing: AppSpacing.md) {
            SearchIllustration(tint: .neutral, size: .standard)
            Text("No results")
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Group Filter

    private var groupFilterBar: some View {
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

    /// Single friend row content. Background-less — the parent
    /// `glassFriendsCard` provides one shared Liquid Glass surface for
    /// all rows. Tap routes to the friend's profile sheet.
    private func friendRowContent(_ friend: Friend) -> some View {
        Button(action: { sheetFriend = .view(friend) }) {
            HStack(spacing: AppSpacing.md) {
                PixelCatView(id: friend.id, size: AppSizes.emojiFrame, blackAndWhite: !friend.isConnected)
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty State (no friends ever)

    /// Centred placeholder shown when the user has zero friends in the
    /// store. Matches the Reminders / Home pattern: `.standard`-size
    /// figure, GeometryReader + `.position` for reliable visual
    /// centring inside the navigation child container.
    private var emptyPlaceholder: some View {
        GeometryReader { geo in
            VStack(spacing: AppSpacing.md) {
                EmptyBoxIllustration(tint: .neutral, size: .standard)
                Text("No friends yet")
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
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
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
    @Environment(\.analytics) private var analytics
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    @State private var selectedTransaction: Transaction? = nil
    @State private var showTransactionDetail: Bool = false
    @State private var editingTransaction: Transaction? = nil
    /// Drives the "Settle up" CTA's create-transaction sheet. Same
    /// shape as `FriendDetailView.pendingSettleUp` so both friend
    /// hero pages route into the same prefilled settle-up flow.
    @State private var pendingSettleUp: CreateTransactionModal.SettleUpPrefill? = nil

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
                    settleUpCTA
                    transactionsSection
                    Spacer().frame(height: 40)
                }
            }
            .background(SplitPageBackground())
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
            // Settle-up CTA target — same prefilled-modal route as
            // the Debts-side `FriendDetailView`.
            .sheet(item: $pendingSettleUp) { prefill in
                CreateTransactionModal(
                    settleUpPrefill: prefill
                )
                .environmentObject(categoryStore)
                .environmentObject(transactionStore)
                .environmentObject(currencyStore)
                .environmentObject(friendStore)
                .environmentObject(receiptItemStore)
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
                            analytics.trackTransactionDeleted(tx, hadReceiptItems: !receiptItemStore.items(forTransactionID: tx.id).isEmpty)
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
                    .environmentObject(receiptItemStore)
                    .sheet(item: $editingTransaction) { editTx in
                        CreateTransactionModal(
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
        .trackScreen("FriendsView")
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
            // Only surface the ID for friends who came through a share
            // round-trip (`isConnected == true`, colour avatar). For
            // local-only phantom contacts the ID is purely internal —
            // there's nothing for the user to do with it, and exposing
            // it just invites confusion about whether copying it does
            // anything.
            if friend.isConnected {
                FriendIDCopyLine(id: friend.id)
            }
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

    // MARK: - Settle Up CTA

    /// "Settle up" button under the debt row. Identical shape and
    /// behaviour to `FriendDetailView.settleUpCTA` — the Profile-side
    /// friend page (this view) needs the same affordance so users
    /// reaching the friend through Profile → Friends don't have to
    /// jump over to Debts to close the balance.
    @ViewBuilder
    private var settleUpCTA: some View {
        let amount = myDebt?.amount ?? 0
        if abs(amount) >= 0.005 {
            Button {
                pendingSettleUp = CreateTransactionModal.SettleUpPrefill(
                    friendID: friend.id,
                    amount: abs(amount),
                    currency: currencyStore.selectedCurrency,
                    // Positive (you lent) → friend pays you back.
                    // Negative (you borrowed) → you pay the friend.
                    direction: amount > 0 ? .friendPaysMe : .iPayFriend
                )
            } label: {
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(AppFonts.bodyEmphasized)
                    Text("Settle up")
                        .font(AppFonts.bodyEmphasized)
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous)
                        .fill(AppColors.splitAccentBold)
                )
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.md)
        }
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
                        Text(group.date.formattedSectionDate())
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
                                    analytics.trackTransactionDeleted(tx, hadReceiptItems: !receiptItemStore.items(forTransactionID: tx.id).isEmpty)
                                    transactionStore.delete(id: tx.id)
                                }
                            )
                        }
                    }
                }
            }
        }
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

import SwiftUI

struct FriendDetailView: View {
    let friend: Friend

    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore

    @State private var selectedTransaction: Transaction? = nil
    @State private var showTransactionDetail: Bool = false
    @State private var editingTransaction: Transaction? = nil
    /// Drives the empty-state CTA's create-split sheet. Local to this
    /// view so the participant prefill (you + this friend) flows
    /// directly through `CreateTransactionModal`'s init parameters.
    @State private var showCreateSplit: Bool = false
    /// Drives the "Settle up" CTA's create-transaction sheet. Set
    /// when the user taps the button under the debt row; carries the
    /// prefill payload (amount, currency, who pays) so the modal opens
    /// at a transaction that already zeros out the debt.
    @State private var pendingSettleUp: CreateTransactionModal.SettleUpPrefill? = nil

    /// True when the currently-presented detail sheet has a backing
    /// transaction that's still a split. Mirror of the same hook in
    /// `DebtSummaryView` — when the user edits a split here to "Pay
    /// for yourself" and saves, `splitInfo` goes nil and the
    /// `.debts` detail layout has nothing to render, so we close the
    /// sheet instead of leaving an empty card on screen.
    private var selectedTransactionIsSplit: Bool {
        guard let selected = selectedTransaction,
              let tx = transactionStore.transactions.first(where: { $0.id == selected.id }) else {
            return false
        }
        return tx.splitInfo != nil
    }

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                profileHeader
                debtStatusRow
                settleUpCTA
                transactionsSection
                Spacer().frame(height: 40)
            }
        }
        // Inherits the Split sub-palette from `DebtSummaryView`'s
        // NavigationStack via `.colorContext(.split)`. Background
        // matches that sub-palette's surface tint so the screen
        // doesn't lose the "Split atmosphere" on push.
        .background(FriendDetailPageBackground())
        .navigationBarTitleDisplayMode(.inline)
        // Empty-state CTA target — pre-selects you + this friend as
        // split participants so the user lands on the amount step.
        .sheet(isPresented: $showCreateSplit) {
            CreateTransactionModal(
                autoOpenSplitFlow: true,
                prefilledFriendIDs: [friend.id]
            )
            .environmentObject(categoryStore)
            .environmentObject(transactionStore)
            .environmentObject(currencyStore)
            .environmentObject(friendStore)
        }
        // Settle-up CTA target — opens create-transaction modal with
        // amount + payer + category prefilled so the new transaction
        // zeros out the existing debt on save.
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
        // Close the detail sheet when the underlying transaction stops
        // being a split (typically: user opened the debt-side detail
        // card, hit Edit, switched to "Pay for yourself", and saved).
        // Without this hook `TransactionDetailView` re-renders for the
        // updated (non-split) transaction with all its breakdown
        // sections gated out, surfacing as an empty grey card.
        .onChange(of: selectedTransactionIsSplit) { isSplit in
            if !isSplit && showTransactionDetail {
                showTransactionDetail = false
                selectedTransaction = nil
            }
        }
    }

    // MARK: - Profile Header

    @ViewBuilder
    private var profileHeader: some View {
        VStack(spacing: AppSpacing.sm) {
            // Coloured avatar = friend's ID is verified (linked via
            // share-link round-trip). B&W = local-only phantom contact.
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

    // MARK: - Settle Up CTA

    /// "Settle up" button shown under the debt row whenever there's a
    /// non-zero balance with this friend. Tapping it opens the create-
    /// transaction modal pre-configured as a settle-up transaction —
    /// amount = |debt|, payer side flipped so the new transaction
    /// zeros out whichever direction the debt currently runs.
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
                    // Same glyph the mode picker uses for `.settleUp`
                    // — keeps the CTA and the mode chip visually
                    // linked when the user lands inside the create
                    // modal.
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
                        // `splitAccentBold` is the same saturated
                        // violet in both light and dark mode so the
                        // white label stays at ~5:1 contrast. The
                        // adaptive `splitAccent` would fade to pale
                        // lavender at night and the button lost
                        // weight against the dark surface.
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
                // Sleeping cat in the Split (lavender) tint —
                // matches the sub-palette of the parent screen.
                SleepingCatIllustration(tint: .split, size: .standard)
                Text("No split transactions")
                    .font(AppFonts.labelCaption)
                    .foregroundColor(AppColors.textSecondary)
                // Lavender CTA — opens create-split with you + this
                // friend pre-wired so the participant picker is skipped.
                Button(action: { showCreateSplit = true }) {
                    HStack(spacing: AppSpacing.xs) {
                        Image(systemName: "person.2.fill")
                            .font(AppFonts.captionEmphasized)
                        Text("Split with \(friend.name)")
                            .font(AppFonts.captionEmphasized)
                    }
                    .foregroundColor(AppColors.splitAccent)
                }
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

                        // Per-group iOS 26 Liquid Glass container —
                        // matches the debt summary pattern.
                        // `.clipShape` keeps the swipe-delete red layer
                        // inside the rounded corners.
                        VStack(spacing: 0) {
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
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .padding(.horizontal, AppSpacing.pageHorizontal)
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

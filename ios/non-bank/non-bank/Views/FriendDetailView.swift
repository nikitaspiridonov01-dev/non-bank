import SwiftUI

struct FriendDetailView: View {
    let friend: Friend

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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                profileHeader
                debtStatusRow
                transactionsSection
                Spacer().frame(height: 40)
            }
        }
        // Inherits the Split sub-palette from `DebtSummaryView`'s
        // NavigationStack via `.colorContext(.split)`. Background
        // matches that sub-palette's surface tint so the screen
        // doesn't lose the "Split atmosphere" on push.
        .background(AppColors.splitBackgroundTint)
        .navigationBarTitleDisplayMode(.inline)
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

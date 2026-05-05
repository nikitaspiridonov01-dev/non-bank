import SwiftUI

struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ReminderViewModel()
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @State private var selectedTransaction: Transaction? = nil
    @State private var editingTransaction: Transaction? = nil

    var body: some View {
        NavigationStack {
            Group {
                if vm.reminders.isEmpty {
                    emptyState
                } else {
                    remindersList
                }
            }
            .navigationTitle("Reminders")
            .toolbarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .background(AppColors.reminderBackgroundTint)
        }
        // Two sibling sheets. On "Edit rules" we close the detail sheet first
        // and then open the editor after a short delay so SwiftUI can present
        // them sequentially — nested sheets were proving unreliable on iOS.
        .sheet(item: $selectedTransaction) { tx in
            TransactionDetailView(
                transaction: tx,
                onEdit: {
                    let txToEdit = tx
                    selectedTransaction = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        editingTransaction = txToEdit
                    }
                },
                onDelete: {
                    transactionStore.delete(id: tx.id)
                    selectedTransaction = nil
                },
                onClose: { selectedTransaction = nil },
                source: .reminders
            )
            .environmentObject(categoryStore)
            .environmentObject(transactionStore)
            .environmentObject(friendStore)
            .environmentObject(currencyStore)
        }
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
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(16)
        .presentationBackground(AppColors.reminderBackgroundTint)
        .onAppear { vm.refresh(from: transactionStore.transactions) }
        .onChange(of: transactionStore.transactions.count) { _ in
            vm.refresh(from: transactionStore.transactions)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: AppSpacing.lg) {
            Image(systemName: "bell.slash")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(AppColors.textTertiary)
            Text("No Reminders")
                .font(AppFonts.labelPrimary)
                .foregroundColor(AppColors.textSecondary)
            Text("Future and recurring transactions\nwill appear here.")
                .font(AppFonts.rowDescription)
                .foregroundColor(AppColors.textTertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - List

    private var remindersList: some View {
        let groups = vm.groupedByNextDay()
        return ScrollView {
            LazyVStack(spacing: 0, pinnedViews: []) {
                ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(vm.sectionLabel(for: group.date))
                            .font(AppFonts.sectionHeader)
                            .foregroundColor(AppColors.textSecondary)
                            .tracking(AppFonts.sectionHeaderTracking)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.top, AppSpacing.xxl)
                            .padding(.bottom, AppSpacing.sm)

                        ForEach(Array(group.reminders.enumerated()), id: \.element.id) { idx, tx in
                            let emoji = categoryStore.validatedCategory(for: tx.category).emoji
                            ReminderRowView(
                                transaction: tx,
                                emoji: emoji,
                                nextDateLabel: vm.formattedNextDate(for: tx),
                                isLast: idx == group.reminders.count - 1,
                                onTap: { selectedTransaction = tx },
                                onDelete: { transactionStore.delete(id: tx.id) }
                            )
                        }
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }
}

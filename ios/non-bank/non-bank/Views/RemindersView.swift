import SwiftUI

struct RemindersView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var vm = ReminderViewModel()
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
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
            .background(ReminderPageBackground())
        }
        // Declares the entire Reminders screen as living in the
        // `.reminders` colour context — descendants that read
        // `@Environment(\.colorContext)` automatically pick up the
        // warm-red sub-palette (accent, surface tint, pixel tint).
        .colorContext(.reminders)
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
            .environmentObject(receiptItemStore)
        }
        .sheet(item: $editingTransaction) { editTx in
            CreateTransactionModal(
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
        .presentationBackground { ReminderPageBackground() }
        .onAppear { vm.refresh(from: transactionStore.transactions) }
        .onReceive(transactionStore.$transactions) { txs in
            vm.refresh(from: txs)
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        // Sleeping cat in the `.reminders` tint (warm calendar-red)
        // visually anchors the empty state to the Reminders sub-
        // palette, so it doesn't read as a generic neutral empty.
        // `.ignoresSafeArea()` on the GeometryReader is load-bearing:
        // without it the geo's frame is the area *below* the large
        // navigation title, so its midpoint sits well below the visual
        // centre of the screen and the figure reads as floating low.
        // Spanning full-screen and centring there puts the figure at
        // the actual screen midpoint, matching `EmptyTransactionsView`.
        GeometryReader { geo in
            VStack(spacing: AppSpacing.md) {
                SleepingCatIllustration(tint: .reminders, size: .standard)
                Text("No Reminders")
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textSecondary)
                Text("Future and recurring transactions\nwill appear here.")
                    .font(AppFonts.caption)
                    .foregroundColor(AppColors.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
        }
        .ignoresSafeArea()
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

                        // Per-group iOS 26 Liquid Glass container —
                        // matches the timeline-list pattern in
                        // `TransactionDetailView`. Rows inside stay
                        // transparent text + dividers; the group as a
                        // whole reads as one frosted card lifting off
                        // the warm-cream gradient page.
                        //
                        // `.clipShape` after the glass effect — the
                        // SwipeToDeleteRow's UIKit red layer extends
                        // the full row width and would otherwise spill
                        // past the rounded corners on swipe. Clipping
                        // the container to the same shape as the
                        // glass keeps the swipe layer inside the pill.
                        VStack(spacing: 0) {
                            ForEach(Array(group.reminders.enumerated()), id: \.element.id) { idx, tx in
                                let emoji = categoryStore.validatedCategory(for: tx.category).emoji
                                ReminderRowView(
                                    transaction: tx,
                                    emoji: emoji,
                                    isLast: idx == group.reminders.count - 1,
                                    onTap: { selectedTransaction = tx },
                                    onDelete: { transactionStore.delete(id: tx.id) }
                                )
                            }
                        }
                        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                    }
                }
            }
            .padding(.bottom, 40)
        }
    }
}

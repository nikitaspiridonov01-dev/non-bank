import SwiftUI

enum TransactionDetailSource {
    case home
    case reminders
    case linkedReminder   // opened from a transaction card's recurring badge
    case debts            // opened from the debt summary / friend detail screens

    var isReminder: Bool {
        self == .reminders || self == .linkedReminder
    }

    /// True when the detail view should show the extended split breakdown
    /// (shares, upfront payers, per-transaction settlement).
    var showsSplitBreakdown: Bool {
        self == .debts
    }
}

struct TransactionDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorContext) private var colorContext
    @EnvironmentObject var categoryStore: CategoryStore
    @EnvironmentObject var transactionStore: TransactionStore
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var currencyStore: CurrencyStore
    @State private var showDeleteAlert: Bool = false
    @State private var linkedReminder: Transaction? = nil
    /// Set when the user taps the "purchase in split" block on the home version
    /// of the card — opens the same transaction with the debts breakdown.
    @State private var splitBreakdownTransaction: Transaction? = nil
    /// Set when the user taps Edit from inside the nested breakdown sheet —
    /// presents the edit modal inline so the breakdown card is preserved
    /// underneath and reappears after save/cancel.
    @State private var editingFromBreakdown: Transaction? = nil
    /// Set when the user taps Edit rules inside a linkedReminder sheet —
    /// presents the edit modal inline. Without this the Edit button in a
    /// deeply-nested reminder sheet had no callback wired and did nothing.
    @State private var editingFromLinkedReminder: Transaction? = nil
    /// Drives the share flow — single sheet that swaps content between
    /// "ask for name" and "system share sheet" depending on state.
    /// Modeled as one piece of state so SwiftUI never tries to stack
    /// two sheets at once (the source of the infinite-cycle bug from
    /// the previous alert-then-sheet pattern: TextField alert
    /// dismissing while .sheet(item:) was trying to present caused
    /// SwiftUI to repeatedly reset the share-URL binding).
    @State private var shareFlow: ShareFlowStep? = nil

    /// One-shot state machine for the share flow. `Identifiable`
    /// because `.sheet(item:)` requires it.
    enum ShareFlowStep: Identifiable {
        /// User tapped Share without a profile name — present the
        /// `ProfileNameSheet`. Carries the current draft so editing
        /// mid-flow doesn't reset the input.
        case askName(initial: String)
        /// Name is set (either pre-existing or just entered) — present
        /// the system `UIActivityViewController` with this URL.
        case share(URL)

        var id: String {
            switch self {
            case .askName: return "askName"
            case .share(let url): return "share-\(url.absoluteString)"
            }
        }
    }

    var transaction: Transaction
    var onEdit: (() -> Void)?
    var onDelete: (() -> Void)?
    var onClose: (() -> Void)?
    var source: TransactionDetailSource = .home

    /// When the parent context is the split card and this view was opened via
    /// the recurring badge, this closure pops us back to the parent instead of
    /// nesting another split-breakdown sheet on top when the user taps the
    /// "purchase in split" block. Breaks split ↔ reminder navigation cycles.
    var onTapSplitInstead: (() -> Void)? = nil

    // MARK: - Share link

    /// Builds a deep-link URL for the current transaction so the user can
    /// share it with one of the other participants. Returns nil — and the
    /// Share button hides itself — when:
    ///  - The transaction isn't a split (`splitInfo == nil`).
    ///  - The category referenced by `transaction.category` no longer
    ///    exists on this device (was renamed/deleted). In that case the
    ///    encoder can't fill `cn` / `ce` honestly, so we'd rather not
    ///    offer Share than ship a broken link.
    ///
    /// All inputs are pulled from environment stores; the encoder itself
    /// is a pure function (`SharedTransactionLink.encode`).
    /// Resolved category record for this transaction's `category`
    /// title. `nil` if the user renamed/deleted the category — in that
    /// case the Share button is hidden because the encoder can't fill
    /// the payload's `cn` / `ce` fields honestly.
    private var resolvedCategory: Category? {
        categoryStore.categories.first(where: { $0.title == transaction.category })
    }

    /// Build the share-link URL using the current profile name. Pulls
    /// `displayName()` lazily so a name set during this view's lifetime
    /// (via the share-flow name prompt) is reflected immediately.
    private func buildShareURL() -> URL? {
        guard let category = resolvedCategory else { return nil }
        return try? SharedTransactionLink.encode(
            transaction: transaction,
            sharerID: UserIDService.currentID(),
            sharerName: UserProfileService.displayName(),
            friends: friendStore.friends,
            category: category
        )
    }

    /// Tap handler for the Share button. Decides whether to ask for the
    /// profile name first or jump straight to the system share sheet.
    private func handleShareTap() {
        if UserProfileService.isNameSet {
            if let url = buildShareURL() {
                shareFlow = .share(url)
            }
        } else {
            shareFlow = .askName(initial: "")
        }
    }

    /// Called by `ProfileNameSheet` after the user enters a valid
    /// name. Persists the name, then transitions the share flow from
    /// "asking" to "sharing" — the single `.sheet(item:)` re-renders
    /// with the URL content and SwiftUI animates the swap cleanly.
    private func handleProfileNameSaved(_ newName: String) {
        UserProfileService.setDisplayName(newName)
        guard let url = buildShareURL() else {
            shareFlow = nil
            return
        }
        // The ProfileNameSheet's own `dismiss()` fires before this
        // closure returns, so by the time `shareFlow` flips to
        // `.share` the previous sheet content is already torn down —
        // SwiftUI sees a single-item swap (askName → share) and
        // smoothly transitions instead of double-presenting.
        shareFlow = .share(url)
    }

    /// Symmetric to `onTapSplitInstead`: when the parent is a reminder card and
    /// this view was opened via "purchase in split", this closure pops us back
    /// to the parent instead of nesting another linked-reminder sheet when the
    /// user taps the recurring badge.
    var onTapRecurringInstead: (() -> Void)? = nil
    @State private var isCollapsedTitleVisible: Bool = false

    /// Safe emoji lookup — falls back to transaction emoji if categoryStore isn't ready
    private var displayEmoji: String {
        categoryStore.validatedCategory(for: transaction.category).emoji
    }

    /// Safe category title lookup
    private var displayCategory: String {
        categoryStore.validatedCategory(for: transaction.category).title
    }
    
    /// Amount displayed in the primary amount row. For home/reminders this is
    /// the transaction amount; for the debts card it's the user's personal
    /// lent/borrowed amount in that transaction.
    private var primaryDisplayAmount: Double {
        if source.showsSplitBreakdown {
            switch SplitDebtService.userPosition(in: transaction) {
            case .lent(let amount), .borrowed(let amount): return amount
            case .notInvolved, .settled: return 0
            }
        }
        return transaction.amount
    }

    private var formattedIntegerPart: String {
        NumberFormatting.integerPart(primaryDisplayAmount)
    }

    private var formattedDecimalPart: String {
        NumberFormatting.decimalPart(primaryDisplayAmount)
    }

    /// Title above the amount. On the debts card reflects the user's position
    /// in the split rather than the generic expense/income type.
    private var detailTitle: String {
        if source.showsSplitBreakdown {
            switch SplitDebtService.userPosition(in: transaction) {
            case .lent:        return "You lent"
            case .borrowed:    return "You borrow"
            case .notInvolved: return "You're not involved in this expense"
            case .settled:     return "Your share is settled"
            }
        }
        return transaction.isIncome ? "Your income" : "Your expense"
    }

    /// True when the amount row should render. Hidden on the debts card
    /// when the user isn't a participant OR when they're a participant
    /// whose contribution balances out — there's no lent/borrowed
    /// number to show in either case.
    private var showsPrimaryAmount: Bool {
        guard source.showsSplitBreakdown else { return true }
        switch SplitDebtService.userPosition(in: transaction) {
        case .notInvolved, .settled: return false
        case .lent, .borrowed:       return true
        }
    }

    /// Sign prefix ("+" / "-") in front of the amount. Only shown for the
    /// expense/income card — the debts card already communicates direction
    /// through the "You lent" / "You borrow" label.
    private var showsAmountSign: Bool {
        !source.showsSplitBreakdown
    }

    /// Resolve repeat interval: from the transaction itself, or from its parent if it's a recurring child
    private var resolvedRepeatInterval: RepeatInterval? {
        if let interval = transaction.repeatInterval {
            return interval
        }
        if let parentID = transaction.parentReminderID,
           let parent = transactionStore.transactions.first(where: { $0.id == parentID }) {
            return parent.repeatInterval
        }
        return nil
    }

    /// The parent recurring transaction (for children) or the transaction itself (if it's a parent)
    private var parentReminderTransaction: Transaction? {
        if transaction.isRecurringParent {
            return transaction
        }
        if let parentID = transaction.parentReminderID {
            return transactionStore.transactions.first { $0.id == parentID }
        }
        return nil
    }

    /// Date section label
    private var dateLabel: String {
        if source.isReminder {
            return transaction.isIncome ? "Next income on" : "Next expense on"
        }
        return "Counted on"
    }

    /// Date to display
    private var displayDate: Date {
        if source.isReminder {
            return ReminderService.nextOccurrenceDate(for: transaction) ?? transaction.date
        }
        return transaction.date
    }
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xxl) {
                    HStack(alignment: .center, spacing: AppSpacing.lg) {
                        ZStack {
                            // Emoji tile: pick the same surface as the
                            // sub-app's row pills so the tile and rows
                            // read as one family. Reminders → translucent
                            // white (matches reminder cards); Debts →
                            // `splitCardFill` (matches "Debts to settle
                            // up" friend rows); standard → the same
                            // translucent white — sits on the same
                            // cream `backgroundPrimary` page as
                            // Reminders, and `backgroundChip` read as a
                            // noticeably darker tan tile against it.
                            RoundedRectangle(cornerRadius: AppRadius.xlarge, style: .continuous)
                                .fill(
                                    source == .debts
                                        ? AppColors.splitCardFill
                                        : AppColors.reminderEmojiBackground
                                )
                                .frame(width: 64, height: 64)
                            Text(displayEmoji)
                                .font(AppFonts.emojiLarge)
                        }
                        VStack(alignment: .leading, spacing: AppSpacing.xs) {
                            Text(transaction.title)
                                .font(.title2).bold()
                            Text(displayCategory)
                                .font(.subheadline)
                                .foregroundColor(AppColors.textSecondary)
                        }
                        Spacer(minLength: 8)
                        // Share button — only renders for split transactions
                        // where the encoder can build a valid URL.
                        // Tap behaviour:
                        //   - If the user has set a profile display name,
                        //     produce the URL and present the system share
                        //     sheet immediately.
                        //   - Otherwise, intercept and prompt for the name
                        //     first; on save the name is persisted and the
                        //     share sheet fires with a URL that includes
                        //     the freshly-saved name in `payload.sn`.
                        if transaction.isSplit && resolvedCategory != nil {
                            Button {
                                handleShareTap()
                            } label: {
                                // Share button only appears on split
                                // transactions, so the icon is always
                                // tinted with the Split palette's
                                // lavender — regardless of which screen
                                // opened the detail card.
                                Image(systemName: "square.and.arrow.up")
                                    .font(AppFonts.body)
                                    .foregroundColor(source == .debts ? AppColors.splitAccent : AppColors.textPrimary)
                                    .frame(width: 40, height: 40)
                                    .background(
                                        Circle()
                                            .fill(source == .debts ? AppColors.splitChipFill : AppColors.backgroundChip)
                                    )
                            }
                            .accessibilityLabel("Share transaction")
                            .tint(source == .debts ? AppColors.splitAccent : AppColors.textPrimary)
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(key: TransactionHeaderOffsetKey.self, value: proxy.frame(in: .named("txScroll")).minY)
                        }
                    )

                    // Title label + recurring schedule badge, above amount
                    VStack(alignment: .leading, spacing: AppSpacing.md) {
                        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.sm) {
                            Text(detailTitle)
                                .font(.subheadline)
                                .foregroundColor(AppColors.textSecondary)
                            if let interval = resolvedRepeatInterval {
                                if !source.isReminder {
                                    Button(action: {
                                        if let cycleBack = onTapRecurringInstead {
                                            cycleBack()
                                        } else {
                                            linkedReminder = parentReminderTransaction
                                        }
                                    }) {
                                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                                            Image(systemName: "repeat")
                                                .font(AppFonts.iconSmall)
                                            Text(interval.displayLabel)
                                                .font(AppFonts.metaText)
                                            Image(systemName: "arrow.up.right")
                                                .font(AppFonts.iconSmall)
                                        }
                                        .foregroundColor(AppColors.reminderAccent)
                                    }
                                } else {
                                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                                        Image(systemName: "repeat")
                                            .font(AppFonts.iconSmall)
                                        Text(interval.displayLabel)
                                            .font(AppFonts.metaText)
                                    }
                                    .foregroundColor(AppColors.reminderAccent)
                                }
                            }
                        }
                        if showsPrimaryAmount {
                            HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
                                if showsAmountSign {
                                    Text(transaction.isIncome ? "+" : "-")
                                        .font(AppFonts.displayMedium)
                                        .foregroundColor(AppColors.textSecondary)
                                }
                                Text(formattedIntegerPart)
                                    .font(.system(size: 32, weight: .bold))
                                    .foregroundColor(AppColors.textPrimary)
                                Text(formattedDecimalPart)
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(AppColors.textSecondary)
                                Text(transaction.currency)
                                    .font(AppFonts.bodyLarge)
                                    .foregroundColor(AppColors.textSecondary)
                            }
                        }

                        // Split card: "of X USD / purchase in split →"
                        // On the home/reminders card this is tappable — it opens
                        // the same transaction with the full debts breakdown.
                        // On the debts card the user is already at the destination,
                        // so it renders as a plain, non-interactive badge.
                        if let split = transaction.splitInfo {
                            splitCard(for: split)
                        }
                    }
                    if source.showsSplitBreakdown, let split = transaction.splitInfo {
                        SplitBreakdownView(
                            transaction: transaction,
                            split: split,
                            friendStore: friendStore
                        )
                    }
                    if source.isReminder, let interval = transaction.repeatInterval {
                        OccurrenceTimelineView(
                            interval: interval,
                            startDate: transaction.date,
                            amount: transaction.amount,
                            currency: transaction.currency,
                            isIncome: transaction.isIncome
                        )
                    } else if source.isReminder {
                        // Non-recurring future transaction — single-entry timeline
                        SingleOccurrenceView(
                            date: transaction.date,
                            amount: transaction.amount,
                            currency: transaction.currency,
                            isIncome: transaction.isIncome
                        )
                    } else {
                        VStack(alignment: .leading, spacing: AppSpacing.md) {
                            Text(dateLabel)
                                .font(.subheadline)
                                .foregroundColor(AppColors.textSecondary)
                            Text(formattedDateTime(displayDate))
                                .font(.body)
                        }
                    }
                    if let desc = transaction.description, !desc.isEmpty {
                        let notesContent: AttributedString = {
                            if let parsed = try? AttributedString(markdown: desc) {
                                return parsed
                            }
                            return AttributedString(desc)
                        }()

                        VStack(alignment: .leading, spacing: AppSpacing.sm) {
                            Text("Notes")
                                .font(.subheadline)
                                .foregroundColor(AppColors.textSecondary)
                            ZStack(alignment: .topLeading) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(source.isReminder ? AppColors.reminderNotesFill : AppColors.backgroundPrimary)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(source.isReminder ? AppColors.reminderNotesBorder : Color(.systemGray4), lineWidth: 1)
                                    )
                                Text(notesContent)
                                    .font(.body)
                                    .foregroundColor(AppColors.textPrimary)
                                    .multilineTextAlignment(.leading)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .padding(14)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, AppSpacing.xxs)
                    }
                    Button(role: .destructive) {
                        showDeleteAlert = true
                    } label: {
                        Label(source.isReminder ? "Delete from reminders" : "Delete transaction", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                            // `role: .destructive` forces the system-red
                            // foreground on plain buttons regardless of
                            // `.tint`, so we paint the Label directly to
                            // match the swipe-action `AppColors.danger`.
                            .foregroundStyle(AppColors.danger)
                    }
                    .padding(.top, AppSpacing.xxl)
                }
                .padding()
            }
            .coordinateSpace(name: "txScroll")
            .onPreferenceChange(TransactionHeaderOffsetKey.self) { y in
                let threshold: CGFloat = -44
                isCollapsedTitleVisible = y < threshold
            }
            // Sub-app background tint — switches per source so the
            // detail card carries the same atmosphere as the screen
            // that opened it: warm cream for Reminders, muted lavender
            // for Split / Debts, default elsewhere.
            .background(
                source == .debts ? AppColors.splitBackgroundTint :
                source.isReminder ? AppColors.reminderBackgroundTint :
                AppColors.backgroundPrimary
            )
            .navigationTitle(isCollapsedTitleVisible ? transaction.title : "")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        if let onClose = onClose {
                            onClose()
                        } else {
                            dismiss()
                        }
                    }
                }
                if source.isReminder {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 5) {
                            Image(systemName: "clock")
                                .font(AppFonts.footnote)
                                .foregroundColor(AppColors.reminderAccent)
                            Text("Reminder")
                                .font(AppFonts.bodySmallEmphasized)
                        }
                    }
                }
                if source.showsSplitBreakdown {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 5) {
                            Image(systemName: "person.2.fill")
                                .font(AppFonts.footnote)
                                .foregroundColor(AppColors.splitAccent)
                            Text("Split")
                                .font(AppFonts.bodySmallEmphasized)
                        }
                    }
                }
                // Share button used to live here (toolbar), but we moved
                // it inline with the header block so it's visually next to
                // the transaction it acts on. See `shareURL` use in the
                // header HStack above.
                ToolbarItem(placement: .confirmationAction) {
                    Button(source.isReminder ? "Edit rules" : "Edit") {
                        onEdit?()
                    }
                }
            }
            .sheet(item: $linkedReminder) { reminder in
                // Cycle-break only when this view (the presenter) is a split
                // breakdown: tapping "purchase in split" inside the nested
                // reminder pops back to the split underneath instead of
                // nesting another split sheet. For other sources (home,
                // reminders) the link behaves normally and opens a new split.
                let cycleBackToSplit: (() -> Void)? = source == .debts
                    ? { linkedReminder = nil }
                    : nil
                TransactionDetailView(
                    transaction: reminder,
                    onEdit: {
                        editingFromLinkedReminder = reminder
                    },
                    onDelete: {
                        transactionStore.delete(id: reminder.id)
                        linkedReminder = nil
                    },
                    onClose: { linkedReminder = nil },
                    source: .linkedReminder,
                    onTapSplitInstead: cycleBackToSplit
                )
                .environmentObject(categoryStore)
                .environmentObject(transactionStore)
                .environmentObject(friendStore)
                .environmentObject(currencyStore)
                .sheet(item: $editingFromLinkedReminder) { editTx in
                    CreateTransactionModal(
                        isPresented: Binding(
                            get: { true },
                            set: { if !$0 { editingFromLinkedReminder = nil } }
                        ),
                        editingTransaction: editTx
                    )
                    .environmentObject(categoryStore)
                    .environmentObject(transactionStore)
                    .environmentObject(currencyStore)
                    .environmentObject(friendStore)
                }
            }
            .sheet(item: $splitBreakdownTransaction) { breakdownTx in
                // Always resolve the latest version from the store so the card
                // re-renders reactively after an edit, without requiring reopen.
                // Lookup by `syncID` (not `id`) because Replace-reminder does
                // a delete-then-insert that rotates the autoincrement id;
                // syncID is preserved across that flow so this stays bound
                // to "the same logical transaction" instead of breaking.
                if let fresh = transactionStore.transactions.first(where: { $0.syncID == breakdownTx.syncID }) {
                    // Cycle-break only when this view (the presenter) is a
                    // reminder: tapping the recurring badge inside the nested
                    // split pops back to the reminder underneath instead of
                    // nesting another reminder sheet. For other sources (home,
                    // debts) the link behaves normally.
                    let cycleBackToReminder: (() -> Void)? = source.isReminder
                        ? { splitBreakdownTransaction = nil }
                        : nil
                    TransactionDetailView(
                        transaction: fresh,
                        onEdit: {
                            editingFromBreakdown = fresh
                        },
                        onClose: { splitBreakdownTransaction = nil },
                        source: .debts,
                        onTapRecurringInstead: cycleBackToReminder
                    )
                    .environmentObject(categoryStore)
                    .environmentObject(transactionStore)
                    .environmentObject(friendStore)
                    .environmentObject(currencyStore)
                    .sheet(item: $editingFromBreakdown) { editTx in
                        CreateTransactionModal(
                            isPresented: Binding(
                                get: { true },
                                set: { if !$0 { editingFromBreakdown = nil } }
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
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(16)
        .presentationBackground {
            if source.isReminder {
                AppColors.reminderBackgroundTint
            } else {
                Rectangle().fill(.regularMaterial)
                    .overlay(AppColors.backgroundOverlay)
            }
        }
        .alert(deleteAlertTitle, isPresented: $showDeleteAlert) {
            Button("Delete", role: .destructive) {
                onDelete?()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(deleteAlertMessage)
        }
        // Single sheet binding for the share flow. Content swaps
        // between `ProfileNameSheet` (when name isn't set) and
        // `ShareActivityView` (when ready) based on the `shareFlow`
        // state machine. This unified-sheet pattern is what fixed the
        // infinite-cycle bug — the previous alert-with-TextField then
        // separate `.sheet(item:)` for the share URL would conflict
        // when the alert dismissal animation overlapped with the sheet
        // present, causing SwiftUI to bounce between states.
        .sheet(item: $shareFlow) { step in
            switch step {
            case .askName(let initial):
                // `dismissOnSave: false` — `handleProfileNameSaved`
                // flips `shareFlow` from `.askName` to `.share(url)`,
                // which is what should drive the sheet content swap.
                // If we let the sheet call `dismiss()` after `onSave`,
                // it would write `nil` back to `$shareFlow` (the bound
                // state) and clobber the transition — the share sheet
                // would never appear and the user would have to tap
                // Share a second time. Letting the parent's state
                // change be the only mutation gives SwiftUI a clean
                // single-item swap.
                ProfileNameSheet(
                    initialName: initial,
                    title: "Your name",
                    subtitle: "This is shown to people you share split transactions with. You can change it anytime in Settings.",
                    saveButtonTitle: "Continue",
                    dismissOnSave: false
                ) { newName in
                    handleProfileNameSaved(newName)
                }
            case .share(let url):
                ShareActivityView(items: [url])
            }
        }
    }

    /// Delete-alert copy that switches based on whether this is a reminder
    /// (one-off future or recurring parent) or a regular transaction.
    private var deleteAlertTitle: String {
        if transaction.isRecurringParent { return "Delete reminder?" }
        if source.isReminder { return "Delete reminder?" }
        return "Delete transaction?"
    }

    private var deleteAlertMessage: String {
        if transaction.isRecurringParent {
            // Only warn about surviving past transactions when at least one
            // occurrence has actually been spawned. Freshly scheduled recurring
            // reminders (first occurrence still in the future) don't need
            // that extra reassurance.
            let hasSpawnedChildren = transactionStore.transactions
                .contains { $0.parentReminderID == transaction.id }
            if hasSpawnedChildren {
                return "Transactions already created from this reminder will not be deleted, but no new transactions will be created."
            }
            return "This reminder will stop. No transactions will be created from it."
        }
        if source.isReminder {
            return "The planned transaction will not be created."
        }
        return "This action cannot be undone."
    }
    
    // MARK: - Split Section

    @ViewBuilder
    private func splitCard(for split: SplitInfo) -> some View {
        if source.showsSplitBreakdown {
            // Hidden on the debts card — the chart below already encodes the
            // same information in a richer form.
            EmptyView()
        } else {
            Button(action: {
                if let cycleBack = onTapSplitInstead {
                    cycleBack()
                } else {
                    splitBreakdownTransaction = transaction
                }
            }) {
                splitCardContent(for: split, showsArrow: true)
            }
            .buttonStyle(.plain)
        }
    }

    private func splitCardContent(for split: SplitInfo, showsArrow: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: AppSpacing.xs) {
                (Text("of ")
                    .foregroundColor(AppColors.textSecondary)
                + Text(formatAmountWithCents(split.totalAmount))
                    .foregroundColor(AppColors.textPrimary)
                + Text(" \(transaction.currency)")
                    .foregroundColor(AppColors.textSecondary))
                    .font(AppFonts.metaText)
                HStack(spacing: AppSpacing.xs) {
                    Image(systemName: "person.2.fill")
                        .font(AppFonts.iconSmall)
                    Text("purchase in split")
                        .font(AppFonts.metaText)
                }
                .foregroundColor(AppColors.splitAccent)
            }
            Spacer()
            if showsArrow {
                Image(systemName: "arrow.up.right")
                    .font(AppFonts.iconSmall)
                    .foregroundColor(AppColors.splitAccent)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: AppRadius.medium)
                .stroke(AppColors.border, lineWidth: 1)
        )
    }

    /// Format amount with decimals if needed
    /// Always includes cents (e.g. "116.80")
    private func formatAmountWithCents(_ value: Double) -> String {
        let intPart = NumberFormatting.integerPart(value)
        let cents = Int((abs(value) * 100).rounded()) % 100
        return "\(intPart).\(String(format: "%02d", cents))"
    }

    private func formatAmount(_ value: Double) -> String {
        let intPart = NumberFormatting.integerPart(value)
        let decimal = abs(value) - Double(Int(abs(value)))
        if decimal < 0.005 {
            return intPart
        }
        let cents = Int((decimal * 100).rounded())
        return "\(intPart).\(String(format: "%02d", cents))"
    }



    private func formattedDateTime(_ date: Date) -> String {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        if calendar.isDateInToday(date) {
            formatter.dateFormat = "'Today at' HH:mm"
        } else if calendar.isDateInTomorrow(date) {
            formatter.dateFormat = "'Tomorrow at' HH:mm"
        } else {
            formatter.dateFormat = "MMMM d, yyyy 'at' HH:mm"
        }
        return formatter.string(from: date)
    }

    /// Short date label for the upcoming occurrences list: "Today", "Tomorrow", "Mon · Apr 21"
    private func shortDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE · MMM d"
        return formatter.string(from: date)
    }

    /// Time string for the upcoming occurrences list: "09:00"
    private func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Single Occurrence (non-recurring future)

private struct SingleOccurrenceView: View {
    let date: Date
    let amount: Double
    let currency: String
    let isIncome: Bool

    private static let currentYear = Calendar.current.component(.year, from: Date())

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Circle()
                .fill(AppColors.reminderAccent)
                .frame(width: 8, height: 8)
                .modifier(PulseModifier(active: true))
            Text(Self.shortDateLabel(date))
                .font(.body)
                .foregroundColor(AppColors.textPrimary)
            Spacer()
            Text(Self.timeString(date))
                .font(AppFonts.caption)
                .foregroundColor(AppColors.textTertiary)
                .padding(.trailing, 6)
            Text("\(isIncome ? "+" : "–")\(NumberFormatting.integerPart(amount))\(NumberFormatting.decimalPartIfAny(amount)) \(currency)")
                .font(AppFonts.captionEmphasized)
                .foregroundColor(AppColors.textSecondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, AppSpacing.md)
        .background(AppColors.reminderTimelineBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    private static func shortDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = year == currentYear ? "EEE · MMM d" : "EEE · MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

// MARK: - Occurrence Timeline

private struct OccurrenceEntry: Identifiable {
    let id: Int
    let date: Date
    let isPast: Bool
    let isNext: Bool
}

private struct OccurrenceTimelineView: View {
    let interval: RepeatInterval
    let startDate: Date
    let amount: Double
    let currency: String
    let isIncome: Bool

    private static let futurePageSize = 30

    @State private var allEntries: [OccurrenceEntry] = []
    @State private var anchorEntryID: Int = 0
    @State private var showBackButton = false
    @State private var lastVisibleID: Int? = nil
    @State private var futureCursor: Date = Date()
    @State private var isReady = false

    private static let currentYear = Calendar.current.component(.year, from: Date())

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(allEntries.enumerated()), id: \.element.id) { idx, entry in
                        VStack(spacing: 0) {
                            HStack(spacing: AppSpacing.sm) {
                                Circle()
                                    .fill(entry.isPast ? AppColors.textTertiary : AppColors.reminderAccent)
                                    .frame(width: 8, height: 8)
                                    .opacity(entry.isNext ? 1 : (entry.isPast ? 0.5 : 1))
                                    .modifier(PulseModifier(active: entry.isNext))
                                Text(Self.shortDateLabel(entry.date))
                                    .font(.body)
                                    .foregroundColor(entry.isPast ? .secondary : .primary)
                                Spacer()
                                Text(Self.timeString(entry.date))
                                    .font(AppFonts.caption)
                                    .foregroundColor(AppColors.textTertiary)
                                    .padding(.trailing, 6)
                                Text("\(isIncome ? "+" : "–")\(NumberFormatting.integerPart(amount))\(NumberFormatting.decimalPartIfAny(amount)) \(currency)")
                                    .font(AppFonts.captionEmphasized)
                                    .foregroundColor(entry.isPast ? AppColors.textTertiary : .secondary)
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, AppSpacing.md)
                            .id(entry.id)
                            .onAppear {
                                lastVisibleID = entry.id
                                if isReady {
                                    updateBackButton(visibleID: entry.id)
                                }
                                if entry.id >= allEntries.count - 5 {
                                    loadMoreFuture()
                                }
                            }
                            if idx < allEntries.count - 1 {
                                Divider()
                                    .padding(.leading, 28)
                            }
                        }
                    }
                    // Footer
                    Text("✨ The future holds many mysteries")
                        .font(.system(size: 12))
                        .foregroundColor(AppColors.textTertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.rowVertical)
                }
            }
            .onAppear {
                buildInitialEntries()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    proxy.scrollTo(anchorEntryID, anchor: .top)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        isReady = true
                    }
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if showBackButton {
                    Button {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(anchorEntryID, anchor: .top)
                        }
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                            .font(AppFonts.footnote)
                            .foregroundColor(AppColors.textPrimary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                    }
                    .padding(8)
                    .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .frame(height: 220)
        .background(AppColors.reminderTimelineBackground)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
    }

    // MARK: - Data

    private func buildInitialEntries() {
        let now = Date()
        var pastDates: [Date] = []
        var cursor = startDate
        for _ in 0..<500 {
            guard let next = interval.nextOccurrence(after: cursor) else { break }
            if next > now { break }
            pastDates.append(next)
            cursor = next
        }
        let futureDates = interval.nextOccurrences(Self.futurePageSize, after: now)
        futureCursor = futureDates.last ?? now

        var result: [OccurrenceEntry] = []
        let firstFutureIdx = pastDates.count
        for (i, d) in pastDates.enumerated() {
            result.append(OccurrenceEntry(id: i, date: d, isPast: true, isNext: false))
        }
        for (i, d) in futureDates.enumerated() {
            result.append(OccurrenceEntry(id: firstFutureIdx + i, date: d, isPast: false, isNext: i == 0))
        }

        allEntries = result
        anchorEntryID = max(firstFutureIdx - 1, 0)
    }

    private func loadMoreFuture() {
        let cursor = futureCursor
        let newDates = interval.nextOccurrences(Self.futurePageSize, after: cursor)
        guard !newDates.isEmpty else { return }
        futureCursor = newDates.last!
        let baseID = allEntries.count
        let newEntries = newDates.enumerated().map { i, d in
            OccurrenceEntry(id: baseID + i, date: d, isPast: false, isNext: false)
        }
        allEntries.append(contentsOf: newEntries)
    }

    private func updateBackButton(visibleID: Int) {
        let distance = abs(visibleID - anchorEntryID)
        let shouldShow = distance > 3
        if shouldShow != showBackButton {
            withAnimation(.easeInOut(duration: 0.2)) {
                showBackButton = shouldShow
            }
        }
    }

    // MARK: - Formatting

    private static func shortDateLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = year == currentYear ? "EEE · MMM d" : "EEE · MMM d, yyyy"
        return formatter.string(from: date)
    }

    private static func timeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct PulseModifier: ViewModifier {
    let active: Bool
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && isPulsing ? 0.4 : 1.0)
            .opacity(active && isPulsing ? 0.3 : 1.0)
            .animation(
                active ? .easeInOut(duration: 1.0).repeatForever(autoreverses: true) : .default,
                value: isPulsing
            )
            .onAppear {
                if active { isPulsing = true }
            }
    }
}

private struct TransactionHeaderOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// Preview
struct TransactionDetailView_Previews: PreviewProvider {
    static var tx: Transaction = Transaction(
        id: 1,
        emoji: "☕️",
        category: "Food",
        title: "Coffee",
        description: "Morning coffee at Starbucks",
        amount: 3.5,
        currency: "USD",
        date: Date(),
        type: .expenses,
        tags: nil
    )
    static var previews: some View {
        Group {
            TransactionDetailView(transaction: tx)
            TransactionDetailView(transaction: tx, source: .reminders)
        }
        .environmentObject(CategoryStore())
        .environmentObject(TransactionStore())
        .environmentObject(FriendStore())
        .environmentObject(CurrencyStore())
    }
}


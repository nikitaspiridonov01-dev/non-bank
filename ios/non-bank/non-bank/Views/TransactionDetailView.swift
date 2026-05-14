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
    @EnvironmentObject var receiptItemStore: ReceiptItemStore
    /// Needed so we can consume the queued post-create share prompt
    /// when the user opens the share sheet from this view first. See
    /// `consumeQueuedSharePromptIfMatching()` for the rationale.
    @EnvironmentObject var router: NavigationRouter

    /// Observed so the primary amount + title + include/exclude row
    /// react live to the global "include potential expenses" toggle
    /// and to the per-tx flag (which itself flips the row only after
    /// the transaction reloads from the store, but the toggle row's
    /// label needs the live setting to decide "what would this
    /// transaction count for in insights?").
    @ObservedObject private var insightsSettings = InsightsSettings.shared
    @State private var showDeleteAlert: Bool = false
    @State private var showAllItems: Bool = false
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

    /// Snapshot captured at present time. Used solely as the syncID
    /// anchor for `transaction` below — and as the fallback when the
    /// store lookup misses (e.g. mid-delete). Don't read other fields
    /// off this directly; they go stale the moment the user edits.
    private let initialTransaction: Transaction

    /// The live transaction. Resolved from the store on every render
    /// so that an edit committed in `CreateTransactionModal` (which
    /// writes to `transactionStore`) immediately propagates into this
    /// card without the parent needing to re-present the sheet. Lookup
    /// is by `syncID`, not `id`: `id` rotates through the Replace-
    /// reminder flow's delete-then-insert, while `syncID` is preserved
    /// as the logical-identity anchor.
    private var transaction: Transaction {
        transactionStore.transactions.first { $0.syncID == initialTransaction.syncID }
            ?? initialTransaction
    }

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
            category: category,
            // Walk to the parent reminder so child-occurrences ship
            // their parent's recurring rule. Without this, every spawn
            // looks like a one-off on the recipient and the recurring
            // badge silently disappears.
            repeatInterval: resolvedRepeatInterval
        )
    }

    /// Builds the `UIActivityItemSource` the share sheet will see.
    /// Bundles the URL + a pre-rendered human summary (title, items,
    /// recurring info, total) so messenger destinations get rich text
    /// while plain destinations (AirDrop/Copy/Files) get just the URL.
    /// All inputs resolved up-front from the same env stores the rest
    /// of this view uses — receipt items in particular live outside
    /// the URL (variant D), so this is the only path by which the
    /// receiver sees the line-item breakdown at all.
    private func shareItemSource(for url: URL) -> TransactionShareItemSource {
        let context = TransactionShareSummary.Context(
            title: transaction.title,
            categoryEmoji: displayEmoji,
            totalAmount: transaction.splitInfo?.totalAmount ?? transaction.amount,
            currency: transaction.currency,
            isExpense: transaction.type != .income,
            date: transaction.date,
            sharerName: UserProfileService.displayName(),
            items: receiptItems,
            // Same parent-walking trick as `buildShareURL` — children
            // of a recurring reminder don't carry the rule themselves,
            // we pull it from their parent so the share text labels
            // them as recurring just like the URL preview does.
            recurring: resolvedRepeatInterval
        )
        let summary = TransactionShareSummary.build(context)
        return TransactionShareItemSource(url: url, summaryText: summary)
    }

    /// Tap handler for the Share button. Decides whether to ask for the
    /// profile name first or jump straight to the system share sheet.
    private func handleShareTap() {
        if UserProfileService.isNameSet {
            if let url = buildShareURL() {
                shareFlow = .share(url)
                consumeQueuedSharePromptIfMatching()
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
        consumeQueuedSharePromptIfMatching()
    }

    /// Clears the queued post-create `ShareSplitPromptSheet` if it's
    /// queued for *this* transaction.
    ///
    /// Why this exists: `CreateTransactionModal` queues a share-prompt
    /// nudge (`router.promptSplitShare(syncID:)`) after saving a new
    /// split. It fires from `MainTabView` once the modal animation
    /// completes. But if the user happens to be quick — opens the
    /// freshly-saved transaction's detail card and taps Share from
    /// there before the nudge presents (or while it's still queued
    /// behind the detail sheet) — they'll see the "Split saved"
    /// prompt redundantly the moment they leave the detail screen,
    /// even though they already shared. Consuming the queue once the
    /// share-activity sheet is actually about to present avoids that
    /// double-prompt without affecting anyone who *doesn't* share
    /// from detail (the queued nudge still fires for them normally).
    ///
    /// We deliberately call this only on the transition to
    /// `.share(url)` — not on `.askName`. If the user opens the name
    /// gate and then cancels, they haven't actually shared, so the
    /// queued nudge is still valuable.
    private func consumeQueuedSharePromptIfMatching() {
        if router.pendingSplitShareSyncID == transaction.syncID {
            router.dismissSplitSharePrompt()
        }
    }

    /// Symmetric to `onTapSplitInstead`: when the parent is a reminder card and
    /// this view was opened via "purchase in split", this closure pops us back
    /// to the parent instead of nesting another linked-reminder sheet when the
    /// user taps the recurring badge.
    var onTapRecurringInstead: (() -> Void)? = nil
    @State private var isCollapsedTitleVisible: Bool = false

    init(
        transaction: Transaction,
        onEdit: (() -> Void)? = nil,
        onDelete: (() -> Void)? = nil,
        onClose: (() -> Void)? = nil,
        source: TransactionDetailSource = .home,
        onTapSplitInstead: (() -> Void)? = nil,
        onTapRecurringInstead: (() -> Void)? = nil
    ) {
        self.initialTransaction = transaction
        self.onEdit = onEdit
        self.onDelete = onDelete
        self.onClose = onClose
        self.source = source
        self.onTapSplitInstead = onTapSplitInstead
        self.onTapRecurringInstead = onTapRecurringInstead
    }

    /// Whether the nested split-breakdown sheet's transaction is still
    /// a split. When the user edits via `editingFromBreakdown` and
    /// switches to "Pay for yourself" (or otherwise drops `splitInfo`),
    /// the breakdown-style detail has no shares / settlement to show —
    /// the body gates out into a near-empty card. Mirrors the same
    /// auto-close guard that `DebtSummaryView` and `FriendDetailView`
    /// already apply to their own `.debts` detail sheets.
    private var splitBreakdownTransactionIsSplit: Bool {
        guard let selected = splitBreakdownTransaction,
              let tx = transactionStore.transactions.first(where: { $0.syncID == selected.syncID }) else {
            return false
        }
        return tx.splitInfo != nil
    }

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
        // Same rule the row + reminder views use: include-potential mode
        // pushes split rows to render their `myShare`; legacy mode shows
        // the stored amount (== `paidByMe`).
        return transaction.displayPrimaryAmount(includePotentialExpenses: insightsSettings.includePotentialExpenses)
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
        // In include-potential mode the primary amount is the user's
        // share, so the label switches to "Your share" — same word the
        // row's subtitle uses. Income splits don't exist per the spec,
        // but if they ever do, fall through to the generic income copy.
        if insightsSettings.includePotentialExpenses,
           transaction.isSplit,
           !transaction.isIncome {
            return "Your share"
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

    private var receiptItems: [ReceiptItem] {
        receiptItemStore.items(forTransactionID: transaction.id)
    }

    /// Sub-app palette to forward into the items sheet. Mirrors the
    /// branching this view's own `presentationBackground` already does
    /// (lines ~632-647) so the sheet matches the parent atmosphere
    /// rather than landing as a dark slab on a lavender / warm-red
    /// detail card.
    private var receiptSheetContext: ColorContext {
        if source.isReminder { return .reminders }
        if source == .debts { return .split }
        return .standard
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.xxl) {
                    HStack(alignment: .center, spacing: AppSpacing.lg) {
                        // `.glassEffect(.regular, in: shape)` — same
                        // iOS 26 native Liquid Glass that the system
                        // uses for toolbar pills (Close, Edit, Done).
                        // The older `.regularMaterial` rendered
                        // visibly darker than the toolbar pills above
                        // it; `.glassEffect` is the API specifically
                        // intended for iOS 26 chip surfaces and
                        // reads as the same near-white frosted pill
                        // on every page atmosphere.
                        Text(displayEmoji)
                            .font(AppFonts.emojiLarge)
                            .frame(width: 64, height: 64)
                            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.xlarge, style: .continuous))
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
                                // Share button — Split-only, tinted
                                // with the lavender accent. Background
                                // mirrors the emoji tile next to it
                                // via `.glassEffect(.regular, in:)` so
                                // the tile, the share circle, and the
                                // Close / Edit toolbar buttons all
                                // read as one family of iOS 26 Liquid
                                // Glass pills.
                                Image(systemName: "square.and.arrow.up")
                                    .font(AppFonts.body)
                                    .foregroundColor(source == .debts ? AppColors.splitAccent : AppColors.textPrimary)
                                    .frame(width: 40, height: 40)
                                    .glassEffect(.regular, in: .circle)
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
                            // Long-press the hero amount → native
                            // copy menu. The clipboard payload is
                            // the unsigned "<value> <currency>"
                            // string ("100.50 AMD") rather than the
                            // signed form: the sign is implicit from
                            // the income/expense type on this view,
                            // and pasting back into the create
                            // screen's amount field stays clean
                            // (the parser strips currency codes
                            // either way). `contentShape` ensures
                            // the press registers even on the gaps
                            // between glyphs.
                            .contentShape(Rectangle())
                            .contextMenu {
                                Button {
                                    let int = NumberFormatting.integerPart(primaryDisplayAmount)
                                    let dec = NumberFormatting.decimalPartIfAny(primaryDisplayAmount)
                                    UIPasteboard.general.string =
                                        "\(int)\(dec) \(transaction.currency)"
                                } label: {
                                    Label("Copy amount", systemImage: "doc.on.doc")
                                }
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
                    // Insights toggle sits directly under whichever
                    // timing block was rendered above — the
                    // occurrences timeline for reminders, the
                    // "Counted on" date for past transactions. The
                    // user just reasoned about "when this row counts"
                    // while reading the dates, so the toggle that
                    // controls *whether* it counts belongs adjacent.
                    // Was previously split into two placements
                    // (reminders here, past-tx down by Delete); the
                    // past-tx placement felt disconnected — the user
                    // had to scroll past Notes to find a control that
                    // semantically belonged with the date. Negative
                    // top padding tightens the default VStack `xxl`
                    // (24pt) to ~12pt so the block reads as
                    // "attached to" the timing block above rather
                    // than as a standalone section.
                    if showsInsightsToggleRow {
                        insightsStatusBlock
                            .padding(.top, -AppSpacing.md)
                    }
                    receiptItemsSection
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
                            // Notes card uses iOS 26 native Liquid
                            // Glass (`.glassEffect(.regular, in:)`) so
                            // it sits in the same family as the
                            // emoji tile, share button, timeline rows
                            // and the toolbar Close / Edit pills —
                            // one frosted-pill vocabulary across the
                            // detail card. No explicit border: the
                            // glass material's own edge reads as
                            // sufficient elevation.
                            Text(notesContent)
                                .font(.body)
                                .foregroundColor(AppColors.textPrimary)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
            // Sub-app page background — switches per source so the
            // detail card carries the same atmosphere as the screen
            // that opened it. Each sub-app uses its own gradient
            // *variant* so a pushed detail doesn't render identically
            // to the list it was pushed from: `SplitDetailPageBackground`
            // and `ReminderDetailPageBackground` re-arrange the same
            // sub-app palette into a different mesh layout. Default
            // home stays flat.
            .background(
                Group {
                    if source == .debts {
                        SplitDetailPageBackground()
                    } else if source.isReminder {
                        ReminderDetailPageBackground()
                    } else {
                        AppColors.backgroundPrimary
                    }
                }
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
                .environmentObject(receiptItemStore)
                .sheet(item: $editingFromLinkedReminder) { editTx in
                    CreateTransactionModal(
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
                    .environmentObject(receiptItemStore)
                    .sheet(item: $editingFromBreakdown) { editTx in
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
            // Auto-close the nested split-breakdown sheet the moment its
            // backing transaction stops being a split (most often: user
            // edited via `editingFromBreakdown` and switched to "Pay for
            // yourself"). Without this the `source: .debts` detail
            // re-renders with `splitInfo == nil` and all breakdown
            // sections gate out, leaving a near-empty card stranded on
            // top of the home detail.
            .onChange(of: splitBreakdownTransactionIsSplit) { isSplit in
                if !isSplit && splitBreakdownTransaction != nil {
                    splitBreakdownTransaction = nil
                }
            }
            .sheet(isPresented: $showAllItems) {
                ReceiptItemsReadOnlySheet(
                    items: receiptItems,
                    currency: transaction.currency,
                    // Carry this view's sub-app palette through to the
                    // sheet — `.sheet(isPresented:)` content doesn't
                    // inherit `.colorContext` from the env, and a
                    // dark-grey tray landing on top of the lavender or
                    // warm-red detail card is the dissonance the user
                    // pointed out.
                    colorContext: receiptSheetContext
                )
            }
        }
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(16)
        .presentationBackground {
            if source.isReminder {
                ReminderDetailPageBackground()
            } else if source == .debts {
                SplitDetailPageBackground()
            } else {
                // Solid `backgroundPrimary` for home detail. The
                // earlier `Rectangle().fill(.regularMaterial)` +
                // `backgroundOverlay` showed grey artifacts at the
                // top and bottom edges of the sheet — the material
                // was picking up dark elements (analytics charts,
                // etc.) on the home tab through the iOS 26 sheet
                // and the resulting tint clashed with the warm-cream
                // detail content.
                AppColors.backgroundPrimary
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
                // Use a `UIActivityItemSource` so messengers / mail
                // get a rich human summary (title, items list,
                // recurring info) appended to the URL, while
                // AirDrop / Copy / Files keep receiving just the
                // bare URL. The summary is built from the same
                // stores the rest of this view reads — items are
                // not in the URL itself (variant D), so this share
                // text is the only path by which the receiver sees
                // them at all.
                ShareActivityView(items: [shareItemSource(for: url)])
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
    
    // MARK: - Insights toggle

    /// Hide on the debts breakdown card — that surface is focused on
    /// the split settlement, not the kind of meta-toggle this row
    /// represents. Every other entry point (home, reminders, linked
    /// reminder) shows it.
    private var showsInsightsToggleRow: Bool {
        source != .debts
    }

    /// Bordered insights status card — uniform shape for both past
    /// transactions and reminders. Eye glyph on the leading edge,
    /// state title (`Counted in insights` / `Hidden from insights`),
    /// and a context-aware description that adapts copy to past-tx,
    /// recurring parent, or one-off future. Whole card is tappable.
    @ViewBuilder
    private var insightsStatusBlock: some View {
        let excluded = transaction.excludedFromInsights
        Button(action: handleInsightsToggle) {
            HStack(alignment: .top, spacing: AppSpacing.sm) {
                Image(systemName: excluded ? "eye.slash" : "eye")
                    .font(AppFonts.body)
                    .foregroundColor(excluded ? AppColors.textTertiary : AppColors.textPrimary)
                    // Lock both dimensions — `eye` and `eye.slash`
                    // have different intrinsic sizes (the slash adds
                    // visual height), so without a fixed frame the
                    // icon would jump on swap. The 22×22 box matches
                    // the body-font cap height comfortably.
                    .frame(width: 22, height: 22)
                    .contentTransition(.symbolEffect(.replace))
                    .animation(.easeInOut(duration: 0.18), value: excluded)
                VStack(alignment: .leading, spacing: 2) {
                    Text(excluded ? "Hidden from insights" : "Counted in insights")
                        .font(AppFonts.bodySmall)
                        .foregroundColor(AppColors.textPrimary)
                    Text(insightsStatusDescription)
                        .font(AppFonts.metaText)
                        .foregroundColor(AppColors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: AppRadius.medium)
                    .stroke(AppColors.border, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    /// Description text under the status title. Copy adapts to:
    ///   - Past tx: a "tap to flip" action hint (since flipping has
    ///     an immediate, observable effect on totals).
    ///   - Recurring parent reminder: short note that the flag only
    ///     touches new entries.
    ///   - One-off future reminder: short note that the flag takes
    ///     effect when the transaction is recorded.
    private var insightsStatusDescription: String {
        if source.isReminder {
            if transaction.isRecurringParent {
                return "Affects future records only."
            }
            return "Takes effect when recorded."
        }
        return transaction.excludedFromInsights
            ? "Hidden from totals and insights calculation. Tap to show."
            : "Shows in your totals and insights calculation. Tap to hide."
    }

    /// Flip the flag, persist via `transactionStore.update`, fire a
    /// light haptic so the user feels the change. The detail view's
    /// `transaction` accessor resolves the latest record from the
    /// store on every render, so the row re-renders with the updated
    /// label once the write lands.
    private func handleInsightsToggle() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let next = !transaction.excludedFromInsights
        transactionStore.update(transaction.settingExcludedFromInsights(next))
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

    // MARK: - Receipt items section

    @ViewBuilder
    private var receiptItemsSection: some View {
        if !receiptItems.isEmpty {
            // When there's a "Show all" affordance the whole block — header,
            // preview rows, and the link itself — acts as one tap target so
            // the user doesn't have to thread the needle on the small text
            // link. The threshold is `>= 2` rather than `> 2`: even when
            // both items are already visible inline, the sheet's per-row
            // detail (qty × unit price, kind icon variants) gives the
            // tap-through value beyond "see more rows". The single-item
            // case stays non-interactive — there's literally nothing more
            // to reveal there.
            if receiptItems.count >= 2 {
                Button {
                    showAllItems = true
                } label: {
                    receiptItemsContent
                }
                .buttonStyle(.plain)
            } else {
                receiptItemsContent
            }
        }
    }

    private var receiptItemsContent: some View {
        VStack(alignment: .leading, spacing: AppSpacing.md) {
            // Header row: "Items" on the left, "Show all (N)" on the
            // right when there's something to tap through to. The
            // whole VStack is wrapped in a Button outside, so tapping
            // anywhere on the block opens the full sheet — the
            // right-side affordance is just a visual hint, not a
            // separate tap target.
            HStack(alignment: .firstTextBaseline) {
                Text("Items")
                    .font(.subheadline)
                    .foregroundColor(AppColors.textSecondary)
                Spacer()
                if receiptItems.count >= 2 {
                    HStack(spacing: 3) {
                        Text("Show all")
                            .font(AppFonts.metaText)
                        Image(systemName: "arrow.up.right")
                            .font(AppFonts.iconSmall)
                    }
                    .foregroundColor(AppColors.textPrimary)
                }
            }
            VStack(spacing: AppSpacing.xs) {
                ForEach(Array(receiptItems.prefix(2))) { item in
                    receiptItemRow(item)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func receiptItemRow(_ item: ReceiptItem) -> some View {
        let kind = item.kind
        let isDiscount = kind == .discount
        return HStack(spacing: AppSpacing.md) {
            ReceiptItemKindIcon(kind: kind)
            Text(item.name)
                .font(AppFonts.body)
                .foregroundColor(AppColors.textPrimary)
                .lineLimit(2)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: AppSpacing.xxs) {
                ReceiptItemAmountText(
                    amount: item.lineTotal,
                    currency: transaction.currency,
                    isDiscount: isDiscount
                )
                if let qty = item.quantity, qty > 1, let price = item.price {
                    Text("\(ReceiptItem.formatQuantity(qty)) × \(ReceiptItem.formatAmount(price)) \(transaction.currency)")
                        .font(.caption)
                        .foregroundColor(AppColors.textTertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, AppSpacing.rowVertical)
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
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
        // `.glassEffect(.regular, in:)` — iOS 26 Liquid Glass to
        // match the toolbar-pill weight on Close / Edit / Reminder
        // so each occurrence row reads as a near-white frosted pill
        // in the same family.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
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
                                    .foregroundColor(entry.isPast ? AppColors.textTertiary : AppColors.textPrimary)
                                Spacer()
                                Text(Self.timeString(entry.date))
                                    .font(AppFonts.caption)
                                    .foregroundColor(AppColors.textTertiary)
                                    .padding(.trailing, 6)
                                Text("\(isIncome ? "+" : "–")\(NumberFormatting.integerPart(amount))\(NumberFormatting.decimalPartIfAny(amount)) \(currency)")
                                    .font(AppFonts.captionEmphasized)
                                    .foregroundColor(entry.isPast ? AppColors.textTertiary : AppColors.textSecondary)
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
        // `.glassEffect(.regular, in:)` — iOS 26 Liquid Glass to
        // match the toolbar-pill weight on Close / Edit / Reminder
        // so each occurrence row reads as a near-white frosted pill
        // in the same family.
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: AppRadius.medium, style: .continuous))
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
        .environmentObject(ReceiptItemStore())
    }
}


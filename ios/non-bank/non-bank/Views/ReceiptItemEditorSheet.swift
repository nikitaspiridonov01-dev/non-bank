import SwiftUI
import UIKit

/// Full-screen editor for receipt line items, presented from the create-
/// transaction modal. Uses the same numpad pattern as `WhoPaidPickerView`
/// so the input model feels consistent across the app.
///
/// On save, optionally auto-balances the items sum to the original receipt
/// total by inserting a "Discount" or "Tips" line — or, if the user opts
/// out, prompts them to confirm the divergent total before persisting.
struct ReceiptItemEditorSheet: View {
    let receiptTotal: Double?
    /// Last param is the (possibly user-changed) currency code so the parent
    /// can update its draft alongside the items / total commit.
    var onSave: ([ReceiptItem], Double, String) -> Void
    var onCancel: () -> Void

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var currencyStore: CurrencyStore
    @EnvironmentObject private var transactionStore: TransactionStore

    /// Live-mutating set the user is editing.
    @State private var items: [EditableItem]
    /// Frozen snapshot of the items as they were when the sheet opened —
    /// the "Reset" button restores the editor to this state.
    @State private var initialItemsSnapshot: [EditableItem]

    @State private var activeItemID: UUID?
    @State private var activeInput: String = ""
    @State private var shakeOffset: CGFloat = 0

    /// Editable copy of the currency. Lets the user fix an OCR/AI miss
    /// without leaving the editor, mirroring the picker on the
    /// transaction-create header.
    @State private var currency: String

    /// Single state machine for every modal sheet this view spawns.
    /// Stacking four sibling `.sheet(isPresented:)` modifiers (the prior
    /// pattern) caused two intermittent bugs the user reported: the
    /// rename dialog opening empty, and an occasional hang/crash after
    /// saving a rename. SwiftUI doesn't fully serialise sibling sheet
    /// presentations on the same anchor, so dismissing one while
    /// mutating another's bound state leaves the system in an undefined
    /// state. One `.sheet(item:)` driven by an Identifiable enum
    /// guarantees only-one-presentation-at-a-time and gives each
    /// presentation a fresh, immutable payload.
    @State private var activeSheet: SheetTarget? = nil
    /// Set true when the user picks "Goods and services" inside the
    /// add-item sheet — we then dismiss that sheet and queue the name-
    /// entry sheet to open in `.onDismiss` (SwiftUI can't reliably swap
    /// two presented sheets from the same anchor in one hop).
    @State private var pendingShowAddName: Bool = false

    /// Drives `ScrollViewReader`. When non-nil the items list scrolls so
    /// the row with this id is visible; cleared after each scroll. Used
    /// to surface a freshly-added item that would otherwise land below
    /// the keyboard.
    @State private var scrollToID: UUID? = nil

    private let maxIntDigits = 8
    private let maxDecDigits = 2

    /// Floating-point comparison tolerance only — guards against IEEE-754
    /// noise (e.g. 0.1 + 0.2 ≠ 0.3). Anything above this counts as a real
    /// divergence the user should see, including 0.5 or 0.01 differences.
    private let exactMatchEpsilon: Double = 0.005

    /// Modal sheets the editor can present. Carrying the rename target
    /// inline (rather than via separate `@State` companions) means each
    /// presentation is bound to a fresh value — the previous bug where
    /// reopening Rename showed the prior-tap's name (or an empty field)
    /// can't recur because the sheet's content reads `target.initialName`
    /// directly from the enum payload.
    enum SheetTarget: Identifiable {
        case addMenu
        case addName
        case rename(itemID: UUID, initialName: String)
        case saveConfirmation

        var id: String {
            switch self {
            case .addMenu: return "addMenu"
            case .addName: return "addName"
            case .rename(let id, _): return "rename-\(id)"
            case .saveConfirmation: return "saveConfirmation"
            }
        }
    }

    init(
        initialItems: [ReceiptItem],
        receiptTotal: Double?,
        currency: String,
        onSave: @escaping ([ReceiptItem], Double, String) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.receiptTotal = receiptTotal
        self.onSave = onSave
        self.onCancel = onCancel
        _currency = State(initialValue: currency)
        let editable = initialItems.map(EditableItem.init(from:))
        _items = State(initialValue: editable)
        _initialItemsSnapshot = State(initialValue: editable)
    }

    // MARK: - Computed

    /// Sum of all items, applying the in-flight `activeInput` to the active
    /// row so the title updates live as the user types digits.
    private var sum: Double {
        items.reduce(0) { acc, item in
            if item.id == activeItemID {
                return acc + parseInput(activeInput)
            }
            return acc + item.lineTotal
        }
    }

    /// Signed difference vs. the receipt total. Positive = items exceed
    /// receipt; negative = short. `nil` when there's no receipt total OR
    /// the difference is within the float-precision epsilon.
    private var discrepancy: Double? {
        guard let target = receiptTotal, target > 0 else { return nil }
        let diff = sum - target
        return abs(diff) <= exactMatchEpsilon ? nil : diff
    }

    /// Save is disabled when the sum collapses to zero — saving an
    /// empty-net transaction makes no sense and the title also flips
    /// to `danger` so the user can see the gate before tapping. The
    /// discount sum-floor clamp guarantees the sum can't go negative,
    /// so this condition only ever bites at exactly zero.
    private var canSave: Bool { !items.isEmpty && sum > exactMatchEpsilon }

    private var totalColor: Color {
        sum > exactMatchEpsilon ? AppColors.textPrimary : AppColors.danger
    }

    /// Currency code colour follows the title's danger state so the
    /// "RSD" doesn't sit in calm orange while the digits next to it
    /// scream red — they're one phrase, they should fail together.
    private var currencyColor: Color {
        sum > exactMatchEpsilon ? AppColors.balanceCurrency : AppColors.danger
    }

    /// Adds the leading minus that `ReceiptItem.formatAmount` (and the
    /// underlying `NumberFormatting.integerPart`, which works on `abs`)
    /// strip. Used in two places where the sign matters but the
    /// formatter alone wouldn't carry it:
    ///   • the inactive editor row for discounts — without this, a
    ///     "-445 RSD" line would jump to "445 RSD" the moment the user
    ///     tapped another row, looking like the discount evaporated.
    ///   • the Total header — defensive: items can land on a negative
    ///     net through paths the discount sum-floor clamp doesn't
    ///     cover (parsed scan that arrives unbalanced, edge-case Reset
    ///     state), and "−X RSD" reads as "you owe more than you spent"
    ///     more honestly than a positive number in `danger` red.
    /// Tolerance matches `exactMatchEpsilon` so float noise around zero
    /// doesn't produce a stray "-0".
    private func signed(_ value: Double) -> String {
        let formatted = ReceiptItem.formatAmount(value)
        return value < -exactMatchEpsilon ? "-" + formatted : formatted
    }

    private var canReset: Bool {
        items != initialItemsSnapshot || !activeInput.isEmpty
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                titleHeader
                itemsList
                bottomControls
                numpadView
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, AppSpacing.md)
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        handleSaveTap()
                    } label: {
                        Image(systemName: "checkmark")
                            .fontWeight(.semibold)
                    }
                    .disabled(!canSave)
                    .accessibilityLabel("Save")
                }
            }
        }
        // Block accidental swipe-down dismiss — the editor holds in-flight
        // numpad input and a freshly-added item that would be lost on
        // dismissal. Mirrors `WhoPaidPickerView`'s `multiSelect` mode.
        .interactiveDismissDisabled(true)
        .presentationDragIndicator(.hidden)
        .onAppear {
            if activeItemID == nil, let first = items.first {
                activeItemID = first.id
                activeInput = formatForInput(first.lineTotal)
            }
        }
        .sheet(item: $activeSheet, onDismiss: {
            // Sequencing: when the add-menu closes via "Goods and services"
            // we re-open as the name-entry sheet on the next runloop tick.
            // Doing it inside `onDismiss` (instead of mutating `activeSheet`
            // synchronously inside the menu's tap handler) avoids the
            // "trying to present while dismissing" warning iOS emits when
            // two sheets fight for the same anchor in one frame.
            if pendingShowAddName {
                pendingShowAddName = false
                DispatchQueue.main.async {
                    activeSheet = .addName
                }
            }
        }) { target in
            switch target {
            case .addMenu:
                addItemMenuSheet
                    .presentationDetents([.height(420)])
                    .presentationDragIndicator(.hidden)
            case .addName:
                ProfileNameSheet(
                    initialName: "",
                    title: "New item",
                    subtitle: "What did you buy?",
                    saveButtonTitle: "Add"
                ) { name in
                    addItem(named: name)
                }
            case .rename(let itemID, let initialName):
                ProfileNameSheet(
                    initialName: initialName,
                    title: "Rename item",
                    subtitle: nil,
                    saveButtonTitle: "Save"
                ) { newName in
                    applyRename(targetID: itemID, to: newName)
                }
            case .saveConfirmation:
                saveConfirmationSheet
                    .presentationDetents([.medium])
                    .presentationDragIndicator(.hidden)
            }
        }
    }

    // MARK: - Title + compact Add-item button
    //
    // Single coloured line — same size for "Total:" and the amount, no
    // sub-text. Color logic mirrors `WhoPaidPickerView.computeTitleColor`:
    //   .green   → items match the receipt total
    //   .orange  → items overshoot the receipt total
    //   primary  → items still short of the receipt total OR no receipt
    //              total available
    // Add-item lives inline on the right as a compact accent capsule.
    // The HStack is centre-aligned and pinned to a fixed height so the
    // numpad/list below don't shift when the title font auto-scales for
    // a longer total (e.g. "Total: 1 234 567,89 RSD").
    private var titleHeader: some View {
        // Outer alignment is `.center` so the small Add capsule stays
        // vertically pinned at the row centre — `.firstTextBaseline`
        // tracked the title's baseline, which slides as the digits
        // scale, and that's what the user saw as the Add button
        // "jumping". Inner title HStack still uses `.firstTextBaseline`
        // so the integer digits and currency code remain typographically
        // aligned to each other.
        HStack(alignment: .center, spacing: AppSpacing.sm) {
            // `ViewThatFits` picks the largest size variant whose
            // natural width fits in the available column. Both the
            // digits and the currency code are siblings in the same
            // HStack inside each variant, so they always render at the
            // same point size — no more "RSD oversized vs. shrunken
            // digits" mismatch, no truncation ellipsis at the bottom of
            // the staircase. The size ladder bottoms out at 14 — enough
            // headroom for "Total: 999 999 999 999 RSD" without falling
            // through to truncation.
            ViewThatFits(in: .horizontal) {
                titleAmountAndCurrency(size: 28)
                titleAmountAndCurrency(size: 24)
                titleAmountAndCurrency(size: 20)
                titleAmountAndCurrency(size: 17)
                titleAmountAndCurrency(size: 14)
            }
            Spacer(minLength: 8)
            Button {
                activeSheet = .addMenu
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(AppFonts.footnote)
                    Text("Add")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundColor(AppColors.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(AppColors.backgroundElevated)
                )
            }
            .buttonStyle(.plain)
        }
        .frame(height: 44)
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.top, AppSpacing.md)
        .padding(.bottom, AppSpacing.sm)
    }

    @ViewBuilder
    private func titleAmountAndCurrency(size: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppSpacing.xs) {
            Text("Total: \(signed(sum))")
                .font(.system(size: size, weight: .bold))
                .foregroundColor(totalColor)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            CurrencyDropdownButton(
                selected: currency,
                onSelect: { code in currency = code }
            ) {
                Text(currency)
                    .font(.system(size: size, weight: .bold))
                    .foregroundColor(currencyColor)
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    // MARK: - Items list

    private var itemsList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(items) { item in
                    editorRow(item)
                        .id(item.id)
                        .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            // Explicit `.tint(AppColors.danger)` overrides
                            // iOS's `systemRed` so the swipe-delete picks
                            // up the warm wine/rose tone the rest of the
                            // app uses (matches CategoriesSheetView etc.).
                            Button(role: .destructive) {
                                deleteItem(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            .tint(AppColors.danger)
                        }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .onChange(of: scrollToID) { newID in
                guard let id = newID else { return }
                // Defer one runloop tick so the new row is in the layout
                // tree before scrollTo runs — without this the very first
                // call after `items.append(...)` no-ops because the row
                // doesn't exist yet from ScrollViewReader's perspective.
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                    scrollToID = nil
                }
            }
        }
    }

    private func editorRow(_ item: EditableItem) -> some View {
        let isActive = item.id == activeItemID
        // The kind classifier covers both signals that used to live here
        // separately: a negative `lineTotal` (cloud LLM tagged it as a
        // deduction) and a name match against discount keywords (user
        // typed/picked "Discount" before entering a digit). Beyond
        // discount, `.fee/.tip` now also surface their own icons so
        // the editor mirrors what the review/read-only sheets show.
        let kind = ReceiptItem.Kind.classify(name: item.name, lineTotal: item.lineTotal)
        let isDiscount = kind == .discount
        return Button {
            handleRowTap(item.id)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.md) {
                    ReceiptItemKindIcon(kind: kind)
                    Text(item.name)
                        .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? AppColors.textPrimary : AppColors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    // Identical structure across active/inactive states —
                    // a single amount `Text` plus a single currency `Text`,
                    // same fonts and frame. Only the *content* of the
                    // amount text and its weight change on tap, so SwiftUI
                    // crossfades cleanly instead of structurally swapping
                    // a 1-Text + 1-Text HStack for a 3-Text rich layout
                    // (which is what produced the ugly jump). Mirrors the
                    // payer-screen pattern (`WhoPaidPickerView` row uses
                    // the same trick). The rich `ReceiptItemAmountText`
                    // is intentionally kept for read-only surfaces only —
                    // there's no active state there to fight with.
                    HStack(spacing: 4) {
                        Text(isActive ? activeDisplayString : signed(item.lineTotal))
                            .font(.system(size: 16, weight: isActive ? .bold : .regular))
                            .foregroundColor(isDiscount ? AppColors.success : AppColors.textPrimary)
                        Text(currency)
                            .font(AppFonts.caption)
                            .foregroundColor(isDiscount ? AppColors.success.opacity(0.8) : AppColors.textTertiary)
                    }
                    .offset(x: isActive ? shakeOffset : 0)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.rowVertical)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .fill(isActive ? AppColors.backgroundElevated : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                // Carry the rename target inline in the sheet enum so the
                // ProfileNameSheet's `initialName` reads from a fresh
                // payload every presentation — fixes the "iindx empty
                // dialog" bug where the prior tap's name leaked through.
                activeSheet = .rename(itemID: item.id, initialName: item.name)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            // No `role: .destructive` — iOS forces the role's `systemRed`
            // on the menu *text* even when `.tint` is set (the icon
            // honours the tint, the label doesn't), which left the
            // "Delete" word in the wrong red. Plain Button + `.tint`
            // colours both the trash glyph and the label uniformly with
            // our warm-rose `AppColors.danger`, matching the swipe-to-
            // delete tone elsewhere.
            Button {
                deleteItem(item)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(AppColors.danger)
        }
    }

    /// Single source of truth for "is this a discount line" — used by row
    /// rendering, sign-locking on the numpad, and the active-row hint.
    /// Reuses the multi-language `ReceiptLineFilter` so the same word lists
    /// the parser already knows about (скидка / Rabatt / remise / sconto /
    /// descuento / etc.) drive the editor's behaviour without a parallel
    /// keyword list.
    private func isDiscountItem(_ item: EditableItem) -> Bool {
        ReceiptLineFilter.classify(item.name) == .discount
    }

    private var activeIsDiscount: Bool {
        guard let id = activeItemID,
              let item = items.first(where: { $0.id == id }) else { return false }
        return isDiscountItem(item)
    }

    // MARK: - Bottom controls (Reset / Backspace)

    private var bottomControls: some View {
        HStack {
            Button {
                resetToInitial()
            } label: {
                Text("Reset all")
                    .font(AppFonts.metaText)
                    .foregroundColor(canReset ? .accentColor : AppColors.textDisabled)
            }
            .disabled(!canReset)
            Spacer()
            Button {
                handleBackspace()
            } label: {
                Image(systemName: "delete.left.fill")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundColor(AppColors.textQuaternary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .opacity(activeInput.isEmpty ? 0 : 1)
            .animation(.easeInOut(duration: 0.15), value: activeInput.isEmpty)
        }
        .padding(.leading, 24)
        .padding(.trailing, AppSpacing.md)
    }

    // MARK: - Numpad — same layout as WhoPaidPickerView

    private var numpadView: some View {
        let rows = [["1","2","3"], ["4","5","6"], ["7","8","9"], [".","0","✔︎"]]
        return VStack(spacing: AppSpacing.md) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: AppSpacing.md) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            handleNumpadKey(key)
                        } label: {
                            ZStack {
                                RoundedRectangle(cornerRadius: AppRadius.medium)
                                    .fill(AppColors.backgroundElevated)
                                if key == "✔︎" {
                                    Image(systemName: "checkmark")
                                        .font(AppFonts.fabIcon)
                                        .foregroundColor(canSave ? AppColors.textPrimary : AppColors.textDisabled)
                                } else {
                                    Text(key)
                                        .font(.system(size: 28, weight: .medium))
                                        .foregroundColor(AppColors.textPrimary)
                                }
                            }
                            .frame(height: 56)
                        }
                        .disabled(key == "✔︎" && !canSave)
                    }
                }
            }
        }
    }

    private var activeDisplayString: String {
        guard !activeInput.isEmpty else { return "0" }
        let isNeg = activeInput.hasPrefix("-")
        let body = isNeg ? String(activeInput.dropFirst()) : activeInput
        // Group the integer part with thousand separators so the active
        // string matches the inactive `ReceiptItem.formatAmount` rendering
        // (which also groups). Without this the digit "1290" reads as
        // "1290" while typing and "1 290" the moment the row goes
        // inactive — the swap fed the visual jump the user reported.
        let display: String
        if body.contains(".") {
            let parts = body.split(separator: ".", omittingEmptySubsequences: false)
            let intStr = String(parts.first ?? "0")
            let intVal = Int(intStr) ?? 0
            let grouped = NumberFormatting.integerPart(Double(intVal))
            if parts.count > 1 {
                display = grouped + "." + String(parts[1])
            } else {
                display = grouped + "."
            }
        } else {
            let intVal = Int(body) ?? 0
            display = NumberFormatting.integerPart(Double(intVal))
        }
        return isNeg ? "-\(display)" : display
    }

    // MARK: - Add-item menu sheet
    //
    // Bottom sheet (medium-ish detent) that lists the item types the user
    // can drop in: "Goods and services" routes through ProfileNameSheet so
    // the user can name it; the four preset rows (Fee/Tax/Tips/Discount)
    // add a zero-amount line immediately and activate it for the numpad.
    // Mirrors the visual rhythm of `exceedConfirmationSheet` so the two
    // editor-side bottom sheets feel like one family.
    private var addItemMenuSheet: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(AppColors.textQuaternary)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, AppSpacing.md)

            HStack {
                Text("Add item")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundColor(AppColors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.bottom, AppSpacing.md)

            VStack(spacing: AppSpacing.sm) {
                addItemMenuRow(
                    label: "Goods and services",
                    systemIcon: "bag.fill",
                    iconTint: .neutral,
                    showChevron: true
                ) {
                    // Two-step: close this sheet, then `onDismiss` opens
                    // the name-entry sheet on the next frame. SwiftUI
                    // can't reliably swap two sibling sheets in one tick.
                    pendingShowAddName = true
                    activeSheet = nil
                }
                // Each preset row reads its glyph straight from
                // `ReceiptItem.Kind.iconSymbol` so the Add-item menu
                // and the rendered rows downstream (editor, review,
                // detail card) stay one source of truth — fixing a
                // glyph in one place updates both.
                addItemMenuRow(
                    label: "Fee",
                    systemIcon: ReceiptItem.Kind.fee.iconSymbol ?? "creditcard.fill",
                    iconTint: .neutral
                ) {
                    activeSheet = nil
                    addPresetItem(name: "Fee", isDiscount: false)
                }
                // (Tax preset removed: tax/VAT/sales-tax is store-side
                // metadata, never a buyer-tracked expense — see
                // `ReceiptLineFilter` for the classification rationale.
                // Tax-like buyer charges — city tax, tourist tax — would
                // be added manually under "Fee" with a descriptive name.)
                addItemMenuRow(
                    label: "Tips",
                    systemIcon: ReceiptItem.Kind.tip.iconSymbol ?? "hand.thumbsup.fill",
                    iconTint: .neutral
                ) {
                    activeSheet = nil
                    addPresetItem(name: "Tips", isDiscount: false)
                }
                addItemMenuRow(
                    label: "Discount",
                    systemIcon: ReceiptItem.Kind.discount.iconSymbol ?? "tag.fill",
                    iconTint: .discount
                ) {
                    activeSheet = nil
                    addPresetItem(name: "Discount", isDiscount: true)
                }
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)

            Spacer(minLength: 0)
        }
        .background(AppColors.backgroundPrimary)
    }

    /// Icon-tint style for the add-item menu rows. `.neutral` keeps the
    /// row visually quiet (textPrimary on a soft chip), `.discount` flips
    /// the icon to the green success tone we use elsewhere for deductions
    /// — same colour the row glyph in the editor uses for a discount line.
    private enum AddItemIconTint {
        case neutral
        case discount
    }

    private func addItemMenuRow(
        label: String,
        systemIcon: String,
        iconTint: AddItemIconTint,
        showChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let iconColor: Color = iconTint == .discount
            ? AppColors.success
            : AppColors.textPrimary
        let iconBackground: Color = iconTint == .discount
            ? AppColors.success.opacity(0.15)
            : AppColors.backgroundChip

        return Button(action: action) {
            HStack(spacing: AppSpacing.md) {
                ZStack {
                    Circle().fill(iconBackground)
                    Image(systemName: systemIcon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }
                .frame(width: 36, height: 36)

                Text(label)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 4)

                if showChevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(AppColors.textTertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .fill(AppColors.backgroundElevated)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save confirmation sheet (mirrors WhoPaidPickerView pattern)

    private var saveConfirmationSheet: some View {
        let isOver = (discrepancy ?? 0) > 0
        // Spell out which way the divergence goes — short titles like
        // "Items exceed receipt" parsed as instruction-form to some users
        // ("does this delete items?"). The longer phrasing is clearly a
        // statement of fact and matches the body copy below.
        let title = isOver
            ? "Items sum is more than receipt total"
            : "Items sum is less than receipt total"
        let direction = isOver ? "increased" : "decreased"
        let target = receiptTotal ?? 0
        let receiptStr = "\(ReceiptItem.formatAmount(target)) \(currency)"
        let itemsStr = "\(ReceiptItem.formatAmount(sum)) \(currency)"

        return VStack(spacing: 0) {
            // Drag handle — same shape we use everywhere else for sheets
            // we want to feel "modal-y" but still dismissible by swipe.
            Capsule()
                .fill(AppColors.textQuaternary)
                .frame(width: 36, height: 5)
                .padding(.top, 10)
                .padding(.bottom, AppSpacing.lg)

            // Mirrors `WhoPaidPickerView.exceedConfirmationSheet` exactly:
            // 30pt bold title, 18pt regular body lines split by a 10pt
            // gap, fixed 16pt Spacers around the title. Keeping the two
            // sheets typographically identical so the user reads them as
            // the same kind of confirmation surface.
            Spacer().frame(height: 16)

            Text(title)
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, AppSpacing.xxl)

            Spacer().frame(height: 16)

            // `Text` concatenation (vs. AttributedString) reliably honours
            // `multilineTextAlignment`. AttributedString sometimes refuses
            // to centre wrapped lines because the run's resolved layout
            // alignment overrides the view-level one — switching to native
            // `Text + Text` fixes that.
            (Text("Receipt total was ")
                + Text(receiptStr).foregroundColor(AppColors.textPrimary)
                + Text(", but items add up to ")
                + Text(itemsStr).foregroundColor(AppColors.textPrimary)
                + Text("."))
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, AppSpacing.xxl)

            Spacer().frame(height: 10)

            Text("Transaction amount will be \(direction).")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.horizontal, AppSpacing.xxl)

            Spacer()

            VStack(spacing: AppSpacing.md) {
                Button {
                    activeSheet = nil
                    commitSave()
                } label: {
                    Text("Save total as \(itemsStr)")
                        .font(AppFonts.bodyEmphasized)
                        .foregroundColor(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.lg)
                        .background(AppColors.backgroundElevated)
                        .cornerRadius(AppRadius.xlarge)
                }
                Button {
                    activeSheet = nil
                } label: {
                    Text("Go back and edit")
                        .font(AppFonts.body)
                        .foregroundColor(AppColors.textSecondary)
                        .padding(.vertical, AppSpacing.sm)
                }
            }
            .padding(.horizontal, AppSpacing.xxl)
            .padding(.bottom, AppSpacing.xxxl)
        }
        .background(AppColors.backgroundPrimary)
    }

    // (`receiptVsItemsString` removed — now built inline as `Text + Text`
    // concatenation in the save-confirmation sheet so `multilineTextAlignment`
    // reliably centres wrapped lines.)

    // MARK: - Actions

    private func handleRowTap(_ id: UUID) {
        if id == activeItemID { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        commitActiveInput()
        activeItemID = id
        if let item = items.first(where: { $0.id == id }) {
            var input = formatForInput(item.lineTotal)
            // Discount rows always carry the "-" sign in the input buffer
            // so subsequent numpad digits flow into the negative number.
            if isDiscountItem(item) && !input.hasPrefix("-") {
                input = "-" + input
            }
            activeInput = input
        } else {
            activeInput = ""
        }
    }

    private func handleNumpadKey(_ key: String) {
        if key == "✔︎" {
            handleSaveTap()
            return
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard activeItemID != nil else { return }
        let isNegative = activeInput.hasPrefix("-")
        var digits = isNegative ? String(activeInput.dropFirst()) : activeInput

        if key == "." {
            if digits.isEmpty {
                digits = "0."
            } else if !digits.contains(".") {
                digits.append(".")
            }
        } else {
            let parts = digits.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = parts.first ?? ""
            if !digits.contains(".") {
                if intPart.count >= maxIntDigits { return }
            } else {
                if parts.count > 1 && parts[1].count >= maxDecDigits { return }
            }
            if digits == "0" {
                digits = key
            } else {
                digits.append(key)
            }
        }

        var prospectiveInput = isNegative ? "-\(digits)" : digits
        // Lock the leading "-" for Discount rows: re-add it whenever the
        // user's edits would have stripped the sign. Keeps the discount
        // semantically negative no matter what the user types or deletes.
        if activeIsDiscount && !prospectiveInput.hasPrefix("-") {
            prospectiveInput = "-" + prospectiveInput
        }
        // Sum-floor clamp for discounts: silently reject digits that
        // would drive Σ items below zero (i.e. negative receipt total —
        // nonsensical). Sum can still LAND on exactly zero — Save itself
        // is gated by `canSave` (which requires sum > 0), and the title
        // colour flips to `danger` so the user can tell they've zeroed
        // out before tapping. Backspace, dot, and positive-row inputs
        // are unaffected by this guard.
        if activeIsDiscount {
            let prospectiveValue = parseInput(prospectiveInput)
            let sumOthers = items.reduce(0) { acc, item in
                item.id == activeItemID ? acc : acc + item.lineTotal
            }
            if (sumOthers + prospectiveValue) < 0 {
                return
            }
        }
        activeInput = prospectiveInput
        commitActiveInputToModel()
    }

    private func handleBackspace() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard !activeInput.isEmpty else { return }
        // Don't let backspace strip the locked "-" prefix on a Discount —
        // we want a Discount line to stay non-positive even at zero, so the
        // floor is "-" (parsed as 0), not "" (which a normal item uses).
        if activeIsDiscount && activeInput == "-" { return }
        activeInput.removeLast()
        if activeIsDiscount && !activeInput.hasPrefix("-") {
            activeInput = "-" + activeInput
        }
        commitActiveInputToModel()
    }

    /// Hard reset — restores the full items list to the snapshot taken when
    /// the sheet opened. Intentional, since users asked for "undo all my
    /// edits" rather than the per-row clear behavior of payers-screen.
    private func resetToInitial() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        items = initialItemsSnapshot
        if let first = items.first {
            activeItemID = first.id
            activeInput = formatForInput(first.lineTotal)
        } else {
            activeItemID = nil
            activeInput = ""
        }
    }

    private func commitActiveInputToModel() {
        guard let id = activeItemID,
              let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].lineTotal = parseInput(activeInput)
    }

    private func commitActiveInput() { commitActiveInputToModel() }

    private func deleteItem(_ item: EditableItem) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        items.removeAll { $0.id == item.id }
        if activeItemID == item.id {
            activeItemID = items.first?.id
            activeInput = items.first.map { formatForInput($0.lineTotal) } ?? ""
        }
    }

    private func addItem(named rawName: String) {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Item \(items.count + 1)" : trimmed
        let new = EditableItem(name: name, lineTotal: 0, original: nil)
        items.append(new)
        activeItemID = new.id
        activeInput = ""
        scrollToID = new.id
    }

    /// Insert a preset-named line (Fee/Tax/Tips/Discount) and activate it
    /// for numpad input. Discount entries start with `activeInput = "-"`
    /// so the next digit the user types is interpreted as a deduction —
    /// the numpad doesn't have a minus key, and forcing the user to think
    /// about sign isn't useful when the line type already implies it.
    private func addPresetItem(name: String, isDiscount: Bool) {
        commitActiveInput()
        let new = EditableItem(name: name, lineTotal: 0, original: nil)
        items.append(new)
        activeItemID = new.id
        activeInput = isDiscount ? "-" : ""
        scrollToID = new.id
    }

    private func applyRename(targetID: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = items.firstIndex(where: { $0.id == targetID })
        else { return }
        items[idx].name = trimmed
    }


    private func handleSaveTap() {
        commitActiveInput()
        guard canSave else { return }
        if discrepancy != nil {
            activeSheet = .saveConfirmation
        } else {
            commitSave()
        }
    }

    private func commitSave() {
        let receiptItems = items.compactMap { $0.toReceiptItem() }
        let total = items.reduce(0) { $0 + $1.lineTotal }
        onSave(receiptItems, total, currency)
        dismiss()
    }

    // MARK: - Number formatting (mirrors WhoPaidPickerView helpers)

    private func parseInput(_ input: String) -> Double {
        guard !input.isEmpty, input != "-" else { return 0 }
        return Double(input.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    private func formatForInput(_ value: Double) -> String {
        if value == 0 { return "" }
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        }
        return String(format: "%.2f", value)
    }

    // MARK: - Internal model

    /// Mutable view-model row. Keeps the original `ReceiptItem` around so
    /// persistence fields (`persistedID`, `transactionID`, `syncID`,
    /// `position`) survive the round-trip — without that, editing an item
    /// would orphan its DB row and leak it on next save.
    fileprivate struct EditableItem: Identifiable, Equatable {
        let id: UUID
        var name: String
        var lineTotal: Double
        let original: ReceiptItem?

        static func == (lhs: EditableItem, rhs: EditableItem) -> Bool {
            lhs.id == rhs.id && lhs.name == rhs.name && lhs.lineTotal == rhs.lineTotal
        }

        init(name: String, lineTotal: Double, original: ReceiptItem?) {
            self.id = original?.id ?? UUID()
            self.name = name
            self.lineTotal = lineTotal
            self.original = original
        }

        init(from receipt: ReceiptItem) {
            self.id = receipt.id
            self.name = receipt.name
            self.lineTotal = receipt.lineTotal
            self.original = receipt
        }

        /// Returns a `ReceiptItem` ready to be persisted. Drops `quantity`
        /// and `price` so an edited `total` remains the single source of
        /// truth (otherwise the review row would show a stale `qty × price`
        /// subtitle that doesn't match the displayed total).
        ///
        /// Items with `lineTotal == 0` are still preserved here — the user
        /// may have intentionally added a placeholder line (e.g. "tax — to
        /// fill later") and we shouldn't silently delete them on save.
        func toReceiptItem() -> ReceiptItem? {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty else { return nil }
            return ReceiptItem(
                name: trimmedName,
                quantity: nil,
                price: nil,
                total: lineTotal,
                persistedID: original?.persistedID,
                transactionID: original?.transactionID,
                syncID: original?.syncID ?? UUID().uuidString,
                position: original?.position ?? 0,
                lastModified: Date()
            )
        }
    }
}

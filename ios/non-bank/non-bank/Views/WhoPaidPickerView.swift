import SwiftUI
import UIKit

/// A participant in the "Who pay?" picker — either "You" or a friend.
struct WhoPaidParticipant: Identifiable {
    let id: String       // "me" or friend.id
    let name: String     // "You" or friend.name
}

// MARK: - Mode

private enum WhoPaidMode: Equatable {
    case compact
    case multiSelect
}

// MARK: - View

/// "Who pay?" picker — two modes in one sheet:
/// • Compact (single-select, tap = commit)
/// • Full multi-select (numpad + per-person amounts)
struct WhoPaidPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var friendStore: FriendStore

    let participants: [WhoPaidParticipant]
    let totalAmount: Double
    let currency: String
    let initialPayers: [Payer]
    let onConfirm: ([Payer]) -> Void
    var onConfirmWithNewTotal: (([Payer], Double) -> Void)?

    // MARK: - State

    @State private var mode: WhoPaidMode = .compact
    @State private var selectedSingleID: String
    @State private var amounts: [String: Double]
    @State private var activeRowID: String?
    @State private var activeInput: String = ""
    @State private var shakeOffset: CGFloat = 0
    @State private var selectedDetent: PresentationDetent = .medium
    @State private var showExceedConfirmation: Bool = false
    /// IDs of participants that have been "floated" to top (input went from 0 → non-zero)
    @State private var floatedIDs: Set<String> = []
    /// Cached title/subtitle to prevent flicker during row switch
    @State private var cachedTitle: String = "How much pay"
    @State private var cachedTitleColor: Color = AppColors.textPrimary
    @State private var cachedSubtitle: String?
    @State private var cachedSubtitleColor: Color = AppColors.textTertiary
    @State private var cachedSubtitleIsLeft: Bool = false

    // "Someone else paid" flow
    @State private var currentParticipants: [WhoPaidParticipant]
    @State private var showSomeoneElseFriendPicker = false
    @State private var showSomeoneElseFriendForm = false
    @State private var pendingNewFriendForPicker: Friend? = nil
    /// ID of a temporary payer (from "someone else paid") shown first in compact list — removed when user picks another
    @State private var temporaryPayerID: String? = nil

    private let maxIntDigits = 8
    private let maxDecDigits = 2

    init(
        participants: [WhoPaidParticipant],
        totalAmount: Double,
        currency: String,
        initialPayers: [Payer] = [],
        onConfirm: @escaping ([Payer]) -> Void,
        onConfirmWithNewTotal: (([Payer], Double) -> Void)? = nil
    ) {
        self.participants = participants
        self.totalAmount = totalAmount
        self.currency = currency
        self.initialPayers = initialPayers
        self.onConfirm = onConfirm
        self.onConfirmWithNewTotal = onConfirmWithNewTotal

        // Ensure all payers are in the participant list
        var initialParticipants = participants
        var tempPayerID: String? = nil
        if initialPayers.count == 1 {
            // Single "someone else" payer — add temporarily at top
            let payerID = initialPayers[0].id
            if !participants.contains(where: { $0.id == payerID }) {
                initialParticipants.insert(
                    WhoPaidParticipant(id: payerID, name: initialPayers[0].name),
                    at: 0
                )
                tempPayerID = payerID
            }
        } else if initialPayers.count > 1 {
            // Multi-payer — show exactly the payers as participants
            initialParticipants = initialPayers.map {
                WhoPaidParticipant(id: $0.id, name: $0.name)
            }
        }
        _currentParticipants = State(initialValue: initialParticipants)
        _temporaryPayerID = State(initialValue: tempPayerID)

        let defaultID: String
        if initialPayers.count > 1 {
            // Multiple payers — no one highlighted in compact mode
            defaultID = ""
        } else if let first = initialPayers.first {
            defaultID = first.id
        } else {
            defaultID = participants.first?.id ?? "me"
        }
        _selectedSingleID = State(initialValue: defaultID)

        var amts: [String: Double] = [:]
        var initialFloated: Set<String> = []
        if initialPayers.count > 1 {
            for p in initialPayers {
                amts[p.id] = p.amount
                if p.amount > 0 {
                    initialFloated.insert(p.id)
                }
            }
            _mode = State(initialValue: .multiSelect)
            _selectedDetent = State(initialValue: .large)
            _activeRowID = State(initialValue: initialPayers.first?.id)
            let firstAmt = initialPayers.first?.amount ?? 0
            _activeInput = State(initialValue: Self.formatForInput(firstAmt))
            _floatedIDs = State(initialValue: initialFloated)
        }
        _amounts = State(initialValue: amts)
    }

    // MARK: - Computed helpers

    private func amountFor(_ id: String) -> Double {
        if id == activeRowID {
            return parseInput(activeInput)
        }
        return amounts[id] ?? 0
    }

    private var allAmounts: [String: Double] {
        var result = amounts
        if let active = activeRowID {
            result[active] = parseInput(activeInput)
        }
        return result
    }

    private var payersWithAmount: [(id: String, name: String, amount: Double)] {
        currentParticipants.compactMap { p in
            let amt = amountFor(p.id)
            return amt > 0 ? (p.id, p.name, amt) : nil
        }
    }

    private var sum: Double {
        currentParticipants.reduce(0) { $0 + amountFor($1.id) }
    }

    private var isBalanced: Bool {
        let tolerance = 0.01 * Double(max(payersWithAmount.count, 1))
        return abs(sum - totalAmount) <= tolerance
    }

    private var isExceeding: Bool {
        sum > totalAmount + 0.001
    }

    private var canSave: Bool { isBalanced && sum > 0 }

    /// Can save with exceed confirmation
    private var canSaveWithExceed: Bool { isExceeding && sum > 0 }

    private func isRowDisabled(_ id: String) -> Bool {
        (sum >= totalAmount - 0.001) && amountFor(id) == 0 && id != activeRowID
    }

    /// Whether any amounts have been entered (for reset all button)
    private var hasAnyAmount: Bool {
        currentParticipants.contains { amountFor($0.id) > 0 }
    }

    // MARK: - Sorted participants for multi-select

    /// Floated IDs go to top, rest stay in original order
    private var sortedParticipants: [WhoPaidParticipant] {
        let floated = currentParticipants.filter { floatedIDs.contains($0.id) }
        let rest = currentParticipants.filter { !floatedIDs.contains($0.id) }
        return floated + rest
    }

    // MARK: - Title

    /// Truncate a name for display in the title
    private func titleName(_ name: String) -> String {
        if name.count > 12 { return String(name.prefix(10)) + "…" }
        return name
    }

    private func computeTitle() -> String {
        let payers = payersWithAmount
        let s = sum

        if s > totalAmount + 0.001 {
            return "Exceeds \(Self.formatDisplay(totalAmount)) \(currency)"
        } else if abs(s - totalAmount) <= 0.01 * Double(max(payers.count, 1)) && s > 0 {
            if payers.count == 1 {
                let name = payers[0].name
                return name == "You" ? "You pay" : "\(titleName(name)) pays"
            }
            return "\(payers.count) people pay"
        } else {
            switch payers.count {
            case 0: return "How much pay"
            case 1: return "\(titleName(payers[0].name)) chips in"
            default: return "\(payers.count) people chip in"
            }
        }
    }

    private func computeTitleColor() -> Color {
        let s = sum
        if s > totalAmount + 0.001 {
            return .orange
        } else if abs(s - totalAmount) <= 0.01 * Double(max(payersWithAmount.count, 1)) && s > 0 {
            return .green
        }
        return AppColors.textPrimary
    }

    /// Compute subtitle for the active row
    private func computeSubtitle() -> (text: String, color: Color, isLeft: Bool)? {
        guard activeRowID != nil else { return nil }
        let allZero = currentParticipants.allSatisfy { amountFor($0.id) == 0 }
        let s = sum

        if allZero {
            return ("Enter amount up to \(Self.formatDisplay(totalAmount)) \(currency)", AppColors.textTertiary, false)
        }
        if s > totalAmount + 0.001 {
            let delta = s - totalAmount
            return ("over by \(Self.formatDisplay(delta))", .orange, false)
        }
        if abs(s - totalAmount) <= 0.01 * Double(max(payersWithAmount.count, 1)) && s > 0 {
            return ("balances out", AppColors.textTertiary, false)
        }
        if s < totalAmount - 0.001 {
            let left = totalAmount - s
            return ("\(Self.formatDisplay(left)) left", Color(red: 0.78, green: 0.62, blue: 0.35), true)
        }
        return nil
    }

    /// Updates cached title/color/subtitle — call after data changes settle
    private func refreshCachedState() {
        let newTitle = computeTitle()
        let newColor = computeTitleColor()
        let newSub = computeSubtitle()

        if newTitle != cachedTitle || newColor != cachedTitleColor {
            withAnimation(.easeInOut(duration: 0.3)) {
                cachedTitle = newTitle
                cachedTitleColor = newColor
            }
        }

        cachedSubtitle = newSub?.text
        cachedSubtitleColor = newSub?.color ?? AppColors.textTertiary
        cachedSubtitleIsLeft = newSub?.isLeft ?? false
    }

    /// Display string for the active row — shows raw input including trailing dot
    private var activeDisplayString: String {
        guard !activeInput.isEmpty else { return "0" }

        if activeInput.contains(".") {
            let parts = activeInput.split(separator: ".", omittingEmptySubsequences: false)
            let intStr = String(parts.first ?? "0")
            let intVal = Int(intStr) ?? 0
            let grouped = NumberFormatting.integerPart(Double(intVal))
            if parts.count > 1 {
                return grouped + "." + String(parts[1])
            }
            return grouped + "."
        }

        let intVal = Int(activeInput) ?? 0
        return NumberFormatting.integerPart(Double(intVal))
    }

    /// Adaptive title font size — shrinks for long titles
    private var titleFontSize: CGFloat {
        let len = cachedTitle.count
        if len > 24 { return 24 }
        if len > 18 { return 28 }
        return 32
    }

    // MARK: - Body

    var body: some View {
        Group {
            switch mode {
            case .compact:
                compactSheet
            case .multiSelect:
                multiSelectSheet
            }
        }
        .presentationDetents(
            mode == .multiSelect ? [.large] : [.medium, .large],
            selection: $selectedDetent
        )
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled(mode == .multiSelect)
        .sheet(isPresented: $showExceedConfirmation) {
            exceedConfirmationSheet
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showSomeoneElseFriendForm, onDismiss: {
            if pendingNewFriendForPicker != nil {
                // Delay to let sheet dismiss animation complete
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    showSomeoneElseFriendPicker = true
                }
            }
        }) {
            FriendFormView(existingGroups: friendStore.allGroups, isCompact: true) { newFriend in
                Task {
                    await friendStore.add(newFriend)
                    pendingNewFriendForPicker = newFriend
                }
            }
        }
        .sheet(isPresented: $showSomeoneElseFriendPicker, onDismiss: {
            pendingNewFriendForPicker = nil
        }) {
            FriendPickerView(
                title: "Who pay",
                subtitle: "Select who's paying upfront for the purchase. They'll owe less since they already cover part of the cost.",
                initialSelection: pendingNewFriendForPicker.map { [$0] } ?? [],
                includeYou: true,
                youSelected: false
            ) { selectedFriends, youSelected in
                handleFriendPickerResult(selectedFriends, youSelected: youSelected)
            }
            .environmentObject(friendStore)
        }
    }

    // MARK: - Compact Sheet

    private var compactSheet: some View {
        VStack(spacing: 0) {
            dragHandle

            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Who pay")
                            .font(.system(size: 32, weight: .bold))
                            .foregroundColor(AppColors.textPrimary)

                        Text("Select who's paying upfront for the purchase.")
                            .font(AppFonts.bodySmallRegular)
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, AppSpacing.sm)
                    .padding(.bottom, AppSpacing.md)

                    HStack {
                        Spacer()
                        Button {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            handleSomeoneElsePaid()
                        } label: {
                            HStack(spacing: AppSpacing.xs) {
                                Image(systemName: "person.badge.plus")
                                    .font(AppFonts.captionEmphasized)
                                Text("More options")
                                    .font(AppFonts.captionEmphasized)
                            }
                            .foregroundColor(AppColors.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.bottom, AppSpacing.sm)

                    VStack(spacing: AppSpacing.sm) {
                        ForEach(currentParticipants) { participant in
                            compactRow(participant)
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.bottom, AppSpacing.lg)
            }
        }
        .background(AppColors.backgroundPrimary.ignoresSafeArea())
    }

    private func compactRow(_ participant: WhoPaidParticipant) -> some View {
        let isSelected = participant.id == selectedSingleID
        let isYou = participant.id == "me"

        return Button {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            selectSingleAndCommit(participant)
        } label: {
            HStack(spacing: AppSpacing.md) {
                PixelCatView(
                    id: isYou ? UserIDService.currentID() : participant.id,
                    size: 36,
                    blackAndWhite: !isYou
                )

                Text(participant.name)
                    .font(.system(size: 16, weight: isSelected ? .semibold : .regular))
                    .foregroundColor(isSelected ? AppColors.textPrimary : AppColors.textTertiary)
                    .lineLimit(1)

                Spacer(minLength: 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .fill(isSelected ? AppColors.backgroundElevated : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: AppRadius.large)
                            .stroke(isSelected ? Color.clear : AppColors.textQuaternary.opacity(0.3), lineWidth: 1)
                    )
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Multi-Select Sheet

    private var multiSelectSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Dynamic title — fixed height to prevent content jumping
                Text(cachedTitle)
                    .font(.system(size: titleFontSize, weight: .bold))
                    .foregroundColor(cachedTitleColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: 40)
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.top, AppSpacing.xs)
                    .padding(.bottom, AppSpacing.sm)

                // Participant list — uses List for native swipe support
                List {
                    ForEach(sortedParticipants) { participant in
                        multiSelectRow(participant)
                            .listRowInsets(EdgeInsets(top: 2, leading: 16, bottom: 2, trailing: 16))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if amountFor(participant.id) > 0 {
                                    Button {
                                        resetRowAmount(participant.id)
                                    } label: {
                                        Label("Reset", systemImage: "arrow.counterclockwise")
                                    }
                                    .tint(AppColors.textQuaternary)
                                }
                            }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .animation(.spring(response: 0.5, dampingFraction: 0.9), value: sortedParticipants.map(\.id))

                Spacer(minLength: 0)

                // Reset all + Backspace row
                HStack {
                    // Reset all button
                    Button {
                        resetAllAmounts()
                    } label: {
                        Text("Reset all")
                            .font(AppFonts.metaText)
                            .foregroundColor(hasAnyAmount ? .accentColor : AppColors.textDisabled)
                    }
                    .disabled(!hasAnyAmount)

                    Spacer()

                    // Backspace
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

                // Numpad
                numpadView
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.bottom, AppSpacing.md)
            }
            .background(AppColors.backgroundPrimary)
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        goBackToCompact()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        handleSaveAction()
                    }
                    .disabled(!canSave && !canSaveWithExceed)
                }
            }
        }
        .onAppear {
            cachedTitle = computeTitle()
            cachedTitleColor = computeTitleColor()
            refreshCachedState()
        }
    }

    // MARK: - Multi-Select Row

    private func multiSelectRow(_ participant: WhoPaidParticipant) -> some View {
        let isYou = participant.id == "me"
        let isActive = participant.id == activeRowID
        let amt = amountFor(participant.id)
        let disabled = isRowDisabled(participant.id)
        let balanced = canSave

        return Button {
            handleRowTap(participant.id)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: AppSpacing.md) {
                    PixelCatView(
                        id: isYou ? UserIDService.currentID() : participant.id,
                        size: 36,
                        blackAndWhite: !isYou
                    )
                    .opacity(disabled ? 0.35 : 1)

                    Text(participant.name)
                        .font(.system(size: 16, weight: isActive ? .semibold : .regular))
                        .foregroundColor(
                            disabled ? AppColors.textDisabled :
                            isActive ? AppColors.textPrimary :
                            amt > 0 ? AppColors.textSecondary : AppColors.textTertiary
                        )
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .contentTransition(.identity)

                    Spacer(minLength: 4)

                    HStack(spacing: AppSpacing.xs) {
                        Text(isActive ? activeDisplayString : (amt > 0 ? Self.formatDisplay(amt) : "0"))
                            .font(.system(size: 16, weight: isActive ? .bold : .regular))
                            .foregroundColor(amountColor(amt: amt, isActive: isActive, disabled: disabled, balanced: balanced))
                            .contentTransition(.identity)

                        Text(currency)
                            .font(.system(size: 16, weight: .regular))
                            .foregroundColor(disabled ? AppColors.textDisabled : AppColors.textTertiary)
                    }
                    .offset(x: isActive ? shakeOffset : 0)
                }

                // Subtitle — only on active row
                if isActive, let subText = cachedSubtitle {
                    if cachedSubtitleIsLeft {
                        Button {
                            addRemainingToActive()
                        } label: {
                            HStack(spacing: AppSpacing.xs) {
                                Text(subText)
                                    .font(AppFonts.metaRegular)
                                    .foregroundColor(cachedSubtitleColor)
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundColor(cachedSubtitleColor)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, AppSpacing.xxs)
                        .transition(.identity)
                    } else {
                        Text(subText)
                            .font(AppFonts.metaRegular)
                            .foregroundColor(cachedSubtitleColor)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .padding(.top, AppSpacing.xxs)
                            .transition(.identity)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, AppSpacing.rowVertical)
            .background(
                RoundedRectangle(cornerRadius: AppRadius.large)
                    .fill(isActive ? AppColors.backgroundElevated : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
            .animation(.easeInOut(duration: 0.3), value: isActive)
        }
        .buttonStyle(.plain)
    }

    private func amountColor(amt: Double, isActive: Bool, disabled: Bool, balanced: Bool) -> Color {
        if disabled { return AppColors.textDisabled }
        if balanced && amt > 0 { return .green }
        if isActive { return AppColors.textPrimary }
        if amt > 0 { return AppColors.textPrimary }
        return AppColors.textTertiary
    }

    // MARK: - Numpad (identical to CreateTransactionModal)

    private var numpadView: some View {
        let rows = [["1","2","3"], ["4","5","6"], ["7","8","9"], [".","0","✔︎"]]
        let saveEnabled = canSave || canSaveWithExceed

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
                                        .foregroundColor(saveEnabled ? AppColors.textPrimary : AppColors.textDisabled)
                                } else {
                                    Text(key)
                                        .font(.system(size: 28, weight: .medium))
                                        .foregroundColor(AppColors.textPrimary)
                                }
                            }
                            .frame(height: 56)
                        }
                        .disabled(key == "✔︎" && !saveEnabled)
                    }
                }
            }
        }
    }

    // MARK: - Drag Handle

    private var dragHandle: some View {
        Capsule()
            .fill(AppColors.textQuaternary)
            .frame(width: 36, height: 5)
            .padding(.top, 10)
            .padding(.bottom, AppSpacing.sm)
    }

    // MARK: - Exceed Confirmation Sheet

    private var exceedConfirmationSheet: some View {
        let payers = payersWithAmount
        let payerLabel: String = {
            if payers.count == 1 {
                return payers[0].name == "You" ? "You" : payers[0].name
            }
            return "\(payers.count) people"
        }()
        let verbSuffix = (payers.count == 1 && payers[0].name != "You") ? "s" : ""
        let newTotal = sum
        let overAmount = newTotal - totalAmount

        let fromAmount = Self.formatDisplay(totalAmount) + " " + currency
        let toAmount = Self.formatDisplay(newTotal) + " " + currency

        return VStack(spacing: 0) {
            dragHandle

            Spacer().frame(height: 16)

            Text("Exceeds purchase amount")
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(AppColors.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xxl)

            Spacer().frame(height: 16)

            Text("\(payerLabel) pay\(verbSuffix) \(Self.formatDisplay(overAmount)) \(currency) more than the purchase amount.")
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xxl)

            Spacer().frame(height: 10)

            Text(exceedFromToString(from: fromAmount, to: toAmount))
                .font(.system(size: 18, weight: .regular))
                .foregroundColor(AppColors.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, AppSpacing.xxl)

            Spacer()

            VStack(spacing: AppSpacing.md) {
                Button {
                    commitMultiSelectWithNewTotal(newTotal)
                } label: {
                    Text("Yes, set total to \(Self.formatDisplay(newTotal)) \(currency)")
                        .font(AppFonts.bodyEmphasized)
                        .foregroundColor(AppColors.textPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, AppSpacing.lg)
                        .background(AppColors.backgroundElevated)
                        .cornerRadius(AppRadius.xlarge)
                }

                Button {
                    showExceedConfirmation = false
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
    }

    // MARK: - Actions

    private func selectSingleAndCommit(_ participant: WhoPaidParticipant) {
        // Remove temporary payer if user selected a different person
        if let tempID = temporaryPayerID, tempID != participant.id {
            currentParticipants.removeAll { $0.id == tempID }
            temporaryPayerID = nil
        }
        let payer = Payer(id: participant.id, name: participant.name, amount: totalAmount)
        onConfirm([payer])
        dismiss()
    }

    // MARK: - Someone Else Paid Actions

    private func handleSomeoneElsePaid() {
        showSomeoneElseFriendPicker = true
    }

    private func handleFriendPickerResult(_ friends: [Friend], youSelected: Bool) {
        let totalSelected = friends.count + (youSelected ? 1 : 0)
        guard totalSelected > 0 else { return }

        if totalSelected == 1 && !youSelected {
            // Single friend selected → commit as sole payer → dismiss
            let payer = Payer(id: friends[0].id, name: friends[0].name, amount: totalAmount)
            onConfirm([payer])
            dismiss()
        } else if totalSelected == 1 && youSelected {
            // Only "You" selected → commit as sole payer → dismiss
            let payer = Payer(id: "me", name: "You", amount: totalAmount)
            onConfirm([payer])
            dismiss()
        } else {
            // Multiple people selected → show ONLY these in multi-select
            var selectedParticipants: [WhoPaidParticipant] = []
            if youSelected {
                selectedParticipants.append(WhoPaidParticipant(id: "me", name: "You"))
            }
            selectedParticipants += friends.map {
                WhoPaidParticipant(id: $0.id, name: $0.name)
            }
            currentParticipants = selectedParticipants

            // Reset amounts — all zero
            var amts: [String: Double] = [:]
            for p in selectedParticipants {
                amts[p.id] = 0
            }
            amounts = amts

            // Activate first participant
            activeRowID = selectedParticipants[0].id
            activeInput = ""
            floatedIDs = []

            withAnimation(.easeInOut(duration: 0.3)) {
                mode = .multiSelect
                selectedDetent = .large
            }

            cachedTitle = "How much pay"
            cachedTitleColor = AppColors.textPrimary
            cachedSubtitle = "Enter amount up to \(Self.formatDisplay(totalAmount)) \(currency)"
            cachedSubtitleColor = AppColors.textTertiary
            cachedSubtitleIsLeft = false
        }
    }

    private func enterMultiSelect() {
        commitActiveInput()

        activeRowID = selectedSingleID
        activeInput = ""

        var amts: [String: Double] = [:]
        for p in currentParticipants {
            amts[p.id] = 0
        }
        amounts = amts
        floatedIDs = []

        withAnimation(.easeInOut(duration: 0.3)) {
            mode = .multiSelect
            selectedDetent = .large
        }

        // Set initial title
        cachedTitle = "How much pay"
        cachedTitleColor = AppColors.textPrimary
        cachedSubtitle = "Enter amount up to \(Self.formatDisplay(totalAmount)) \(currency)"
        cachedSubtitleColor = AppColors.textTertiary
        cachedSubtitleIsLeft = false
    }

    private func goBackToCompact() {
        commitActiveInput()

        // Coming back from multi-select — no one should be highlighted in compact
        selectedSingleID = ""

        withAnimation(.easeInOut(duration: 0.3)) {
            mode = .compact
            selectedDetent = .medium
        }
    }

    private func handleRowTap(_ id: String) {
        if isRowDisabled(id) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            triggerShake()
            return
        }

        if id == activeRowID { return }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()

        // Commit current row value first (no animation)
        let previousActiveID = activeRowID
        commitActiveInput()

        // Float the previous row to top if it has a non-zero amount (sort on defocus)
        if let prevID = previousActiveID, amountFor(prevID) > 0, !floatedIDs.contains(prevID) {
            floatedIDs.insert(prevID)
        }

        // Load new row's value
        let currentAmt = amounts[id] ?? 0
        activeInput = currentAmt > 0 ? Self.formatForInput(currentAmt) : ""

        activeRowID = id

        // Update title and subtitle after switch settles
        refreshCachedState()
    }

    private func handleNumpadKey(_ key: String) {
        if key == "✔︎" {
            handleSaveAction()
            return
        }

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let activeID = activeRowID else { return }

        if key == "." {
            if activeInput.isEmpty {
                activeInput = "0."
            } else if !activeInput.contains(".") {
                activeInput.append(".")
            }
        } else {
            let parts = activeInput.split(separator: ".", omittingEmptySubsequences: false)
            let intPart = parts.first ?? ""
            if !activeInput.contains(".") {
                if intPart.count >= maxIntDigits { return }
            } else {
                if parts.count > 1 && parts[1].count >= maxDecDigits { return }
            }
            if activeInput == "0" {
                activeInput = key
            } else {
                activeInput.append(key)
            }
        }

        let newValue = parseInput(activeInput)
        amounts[activeID] = newValue

        // Update title and subtitle
        refreshCachedState()
    }

    private func handleBackspace() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        guard let activeID = activeRowID, !activeInput.isEmpty else { return }

        activeInput.removeLast()
        let newValue = parseInput(activeInput)
        amounts[activeID] = newValue

        refreshCachedState()
    }

    private func commitActiveInput() {
        guard let active = activeRowID else { return }
        amounts[active] = parseInput(activeInput)
    }

    /// Decides whether to save directly or show exceed confirmation
    private func handleSaveAction() {
        commitActiveInput()
        if canSave {
            commitMultiSelect()
        } else if canSaveWithExceed {
            showExceedConfirmation = true
        }
    }

    private func commitMultiSelect() {
        commitActiveInput()

        var result: [Payer] = []
        let final = allAmounts
        for p in currentParticipants {
            let amt = final[p.id] ?? 0
            if amt > 0 {
                result.append(Payer(id: p.id, name: p.name, amount: amt))
            }
        }

        let resultSum = result.reduce(0) { $0 + $1.amount }
        let delta = totalAmount - resultSum
        if abs(delta) > 0 && abs(delta) <= 0.01 * Double(result.count) {
            if !result.isEmpty {
                result[result.count - 1].amount += delta
            }
        }

        onConfirm(result)
        dismiss()
    }

    /// Save with updated total amount (exceed scenario)
    private func commitMultiSelectWithNewTotal(_ newTotal: Double) {
        commitActiveInput()

        var result: [Payer] = []
        let final = allAmounts
        for p in currentParticipants {
            let amt = final[p.id] ?? 0
            if amt > 0 {
                result.append(Payer(id: p.id, name: p.name, amount: amt))
            }
        }

        showExceedConfirmation = false

        if let handler = onConfirmWithNewTotal {
            handler(result, newTotal)
        } else {
            onConfirm(result)
        }
        dismiss()
    }

    /// Reset all amounts to 0
    private func resetAllAmounts() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        for p in currentParticipants {
            amounts[p.id] = 0
        }
        activeInput = ""
        floatedIDs.removeAll()
        refreshCachedState()
    }

    /// Reset a specific row's amount to 0
    private func resetRowAmount(_ id: String) {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        amounts[id] = 0
        if id == activeRowID {
            activeInput = ""
        }
        if floatedIDs.contains(id) {
            floatedIDs.remove(id)
        }
        refreshCachedState()
    }

    /// Add remaining amount to fill the total for the active row
    private func addRemainingToActive() {
        guard let activeID = activeRowID else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let currentAmt = amountFor(activeID)
        let remaining = totalAmount - sum
        if remaining > 0 {
            let newAmt = currentAmt + remaining
            activeInput = Self.formatForInput(newAmt)
            amounts[activeID] = newAmt
            refreshCachedState()
        }
    }

    private func triggerShake() {
        withAnimation(.default) {
            shakeOffset = 8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            withAnimation(.interpolatingSpring(stiffness: 600, damping: 10)) {
                shakeOffset = 0
            }
        }
    }

    // MARK: - Attributed String Helpers

    /// Builds an attributed string for "Would you like to increase ... from X to Y?"
    /// with amounts highlighted in bold + primary color.
    private func exceedFromToString(from fromAmount: String, to toAmount: String) -> AttributedString {
        var result = AttributedString("Would you like to increase the purchase amount from ")
        var fromPart = AttributedString(fromAmount)
        fromPart.foregroundColor = AppColors.textPrimary
        result.append(fromPart)
        result.append(AttributedString(" to "))
        var toPart = AttributedString(toAmount)
        toPart.foregroundColor = AppColors.textPrimary
        result.append(toPart)
        result.append(AttributedString("?"))
        return result
    }

    // MARK: - Formatting

    private func parseInput(_ input: String) -> Double {
        guard !input.isEmpty else { return 0 }
        return Double(input.replacingOccurrences(of: ",", with: ".")) ?? 0
    }

    static func formatDisplay(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            let intVal = Int(value)
            return NumberFormatting.integerPart(Double(intVal))
        } else {
            let intPart = NumberFormatting.integerPart(Double(Int(value)))
            let decimal = value - Double(Int(value))
            return intPart + String(format: ".%02d", Int((decimal * 100).rounded()))
        }
    }

    static func formatForInput(_ value: Double) -> String {
        if value.truncatingRemainder(dividingBy: 1) == 0 {
            return String(format: "%.0f", value)
        } else {
            return String(format: "%.2f", value)
        }
    }
}

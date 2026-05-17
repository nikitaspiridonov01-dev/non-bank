import SwiftUI
import UIKit

struct FriendPickerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var friendStore: FriendStore

    /// Currently selected friend IDs (toggle set)
    @State private var selection: Set<String>
    @State private var youSelected: Bool
    @State private var searchText = ""
    @State private var selectedGroup: String? = nil
    @State private var showFriendForm = false

    let title: String
    let subtitle: String
    let initialSelection: [Friend]
    let includeYou: Bool
    let initialYouSelected: Bool
    /// When true (default), wraps the body in its own `NavigationStack`
    /// + Cancel/Save toolbar — matches the historic standalone-sheet
    /// behavior. When false, returns only the content with a Continue
    /// toolbar item — used by the Phase 4.4 orchestrator which owns
    /// the parent NavigationStack and a Cancel/Back at root.
    let wrapInNavigationStack: Bool
    /// When true, the picker enforces single-selection semantics:
    /// tapping a row clears any previous selection and selects only
    /// that party. Used by the settle-up flow's payer / recipient
    /// pickers where the conceptual choice is "exactly one person",
    /// not "any subset". `Select all`/`Deselect all` is hidden.
    let singleSelect: Bool
    /// Optional ID to hide from the picker entirely. Pass `"me"` to
    /// suppress the "You" row, or a `Friend.id` to filter that friend
    /// out of the list. Used by the settle-up recipient step to avoid
    /// re-offering the party who was just picked as payer — tapping
    /// the same party twice was silently no-op'ed by the same-party
    /// guard downstream and read as a lag bug.
    let excludeID: String?
    let onConfirm: ([Friend], Bool) -> Void

    init(
        title: String = "Who to split with",
        subtitle: String = "Based on the number of people, we'll calculate how much each person owes.",
        initialSelection: [Friend] = [],
        includeYou: Bool = false,
        youSelected: Bool = true,
        wrapInNavigationStack: Bool = true,
        singleSelect: Bool = false,
        excludeID: String? = nil,
        onConfirm: @escaping ([Friend], Bool) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.initialSelection = initialSelection
        self.includeYou = includeYou
        self.initialYouSelected = youSelected
        self.wrapInNavigationStack = wrapInNavigationStack
        self.singleSelect = singleSelect
        self.excludeID = excludeID
        self.onConfirm = onConfirm
        _selection = State(initialValue: Set(initialSelection.map(\.id)))
        // Don't surface a pre-selected "You" when the row is hidden —
        // would otherwise leak through `selectedCount` as a phantom
        // "1 selected" badge with nothing visible to back it up.
        _youSelected = State(initialValue: (excludeID == "me") ? false : youSelected)
    }

    private var hasAnySelection: Bool {
        (effectiveIncludeYou && youSelected) || !selection.isEmpty
    }

    private var selectedCount: Int {
        var count = selection.count
        if effectiveIncludeYou && youSelected { count += 1 }
        return count
    }

    private var filteredFriends: [Friend] {
        var result = friendStore.friends
        if let excludeID, excludeID != "me" {
            result = result.filter { $0.id != excludeID }
        }
        if let group = selectedGroup {
            result = result.filter { $0.groups.contains(group) }
        }
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(query) ||
                $0.groups.contains(where: { $0.lowercased().contains(query) })
            }
        }
        return result
    }

    /// "You" row is hidden when the caller explicitly excludes the
    /// `"me"` sentinel — settle-up recipient step uses this so the
    /// payer (when they were "You") can't be re-picked as recipient.
    private var effectiveIncludeYou: Bool {
        includeYou && excludeID != "me"
    }

    private var allFilteredSelected: Bool {
        let visible = filteredFriends
        guard !visible.isEmpty || includeYou else { return false }
        let friendsAllSelected = visible.allSatisfy { selection.contains($0.id) }
        let youOk = !includeYou || youSelected
        return friendsAllSelected && youOk
    }

    @ViewBuilder
    var body: some View {
        if wrapInNavigationStack {
            NavigationStack { contentBody }
        } else {
            contentBody
        }
    }

    private var contentBody: some View {
        FriendPickerContent(
            title: title,
            subtitle: subtitle,
            includeYou: effectiveIncludeYou,
            youSelected: $youSelected,
            selection: $selection,
            searchText: $searchText,
            selectedGroup: $selectedGroup,
            showFriendForm: $showFriendForm,
            filteredFriends: filteredFriends,
            allFilteredSelected: allFilteredSelected,
            selectedCount: selectedCount,
            hasFriends: !friendStore.friends.isEmpty,
            allGroups: friendStore.allGroups,
            singleSelect: singleSelect,
            onSingleSelectAdvance: singleSelect
                ? { friends, you in
                    onConfirm(friends, you)
                    if wrapInNavigationStack { dismiss() }
                }
                : nil
        )
        .scrollContentBackground(.hidden)
        .background(AppColors.backgroundPrimary)
        .searchable(text: $searchText, prompt: "Search friends")
        // No `.navigationTitle` here. The orchestrator that embeds
        // this view (`wrapInNavigationStack: false`) sets the title
        // from outside so the system back-history menu reads each
        // step's name — an unconditional `.navigationTitle("")` in
        // here used to win against the outer modifier and left blank
        // rows in the menu. Standalone usage (the inner NavigationStack
        // branch in `body`) defaults to an empty bar with no visible
        // title, which is what we want there too.
        .toolbarTitleDisplayMode(.inline)
        .toolbar {
            // Standalone presentation owns Cancel; the orchestrator
            // wrap relies on the parent NavigationStack's back arrow
            // for "go back without confirming", so we only add the
            // confirmation action when embedded.
            if wrapInNavigationStack {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            // Multi-select needs an explicit confirm (no other commit
            // point). Single-select commits on tap via
            // `onSingleSelectAdvance`, so the toolbar checkmark would
            // just be dead weight.
            if !singleSelect {
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let selected = friendStore.friends.filter { selection.contains($0.id) }
                        onConfirm(selected, youSelected)
                        if wrapInNavigationStack { dismiss() }
                    } label: {
                        Image(systemName: "checkmark")
                            .font(AppFonts.bodyEmphasized)
                    }
                    .disabled(!hasAnySelection)
                }
            }
        }
        .sheet(isPresented: $showFriendForm, onDismiss: {
            if !searchText.isEmpty { searchText = "" }
        }) {
            FriendFormView(existingGroups: friendStore.allGroups, isCompact: true) { newFriend in
                Task {
                    await friendStore.add(newFriend)
                    selection.insert(newFriend.id)
                }
            }
        }
    }
}

// MARK: - Inner Content (reads @Environment(\.isSearching))

/// Internal so the Phase 4.4 orchestrator can reuse this as the body
/// of its `friendPicker` push step (without dragging in
/// `FriendPickerView`'s outer NavigationStack / dismiss toolbar). The
/// standalone sheet use-case keeps everything as before.
struct FriendPickerContent: View {
    @Environment(\.isSearching) private var isSearching

    let title: String
    let subtitle: String
    let includeYou: Bool
    @Binding var youSelected: Bool
    @Binding var selection: Set<String>
    @Binding var searchText: String
    @Binding var selectedGroup: String?
    @Binding var showFriendForm: Bool
    let filteredFriends: [Friend]
    let allFilteredSelected: Bool
    let selectedCount: Int
    let hasFriends: Bool
    let allGroups: [String]
    var singleSelect: Bool = false
    /// In `singleSelect` mode this is invoked the moment the user taps
    /// a row — the parent commits the choice and advances the flow
    /// without requiring a separate toolbar confirmation. `nil` in
    /// multi-select mode where the explicit confirm button is the
    /// commit point.
    var onSingleSelectAdvance: (([Friend], Bool) -> Void)? = nil

    var body: some View {
        List {
            if !isSearching {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 32, weight: .bold))
                        .foregroundColor(AppColors.textPrimary)

                    Text(subtitle)
                        .font(AppFonts.bodySmallRegular)
                        .foregroundColor(AppColors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .listRowInsets(EdgeInsets(top: 48, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .transition(.opacity.combined(with: .move(edge: .top)))

                // "Add new friend" above groups — only when groups exist
                if hasFriends && !allGroups.isEmpty {
                    Button { showFriendForm = true } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "person.badge.plus")
                                .font(AppFonts.captionEmphasized)
                            Text("Add new friend")
                                .font(AppFonts.bodySmallRegular)
                        }
                        .foregroundColor(AppColors.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: -6, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Group chips
                if !allGroups.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: AppSpacing.sm) {
                            groupChip(label: "All", isSelected: selectedGroup == nil) {
                                selectedGroup = nil
                            }
                            ForEach(allGroups, id: \.self) { group in
                                groupChip(label: group, isSelected: selectedGroup == group) {
                                    selectedGroup = selectedGroup == group ? nil : group
                                }
                            }
                        }
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.vertical, 10)
                    }
                    .background(AppColors.backgroundElevated)
                    .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
                    .listRowInsets(EdgeInsets(top: -4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // Add new friend (left) + Select all (right) row — only
                // when at least one side has something to show. In
                // `singleSelect` with groups present, neither side
                // renders, so we skip the row entirely instead of
                // letting an empty `HStack` reserve a 44pt row that
                // pushes the friend list down (see the gap in the
                // settle-up screenshot — there's nothing to put here).
                let showAddFriendInRow = hasFriends && allGroups.isEmpty
                let showSelectAll = !filteredFriends.isEmpty && !singleSelect
                if showAddFriendInRow || showSelectAll {
                    HStack {
                        if showAddFriendInRow {
                            Button { showFriendForm = true } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "person.badge.plus")
                                        .font(AppFonts.captionEmphasized)
                                    Text("Add new friend")
                                        .font(AppFonts.captionEmphasized)
                                }
                                .foregroundColor(AppColors.textTertiary)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        if showSelectAll {
                            Button {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    if allFilteredSelected {
                                        for f in filteredFriends { selection.remove(f.id) }
                                        if includeYou { youSelected = false }
                                    } else {
                                        for f in filteredFriends { selection.insert(f.id) }
                                        if includeYou { youSelected = true }
                                    }
                                }
                            } label: {
                                Text(allFilteredSelected ? "Deselect all" : "Select all")
                                    .font(AppFonts.captionEmphasized)
                                    .foregroundColor(.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: -8, trailing: 20))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                // "You" row
                if includeYou {
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if singleSelect {
                            // Single-select: tap commits "You" and
                            // immediately hands off to the parent's
                            // auto-advance callback. No toggle-off
                            // path — there's no need for a "blank"
                            // intermediate state when the next screen
                            // appears in the same gesture.
                            youSelected = true
                            selection.removeAll()
                            onSingleSelectAdvance?([], true)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                youSelected.toggle()
                            }
                        }
                    } label: {
                        // In `singleSelect` mode the row itself
                        // carries selection state (no radio icon).
                        // Mirrors `WhoPaidPickerView.compactRow`:
                        // selected rows sit on the filled chip
                        // surface with bold primary text, unselected
                        // rows stay outlined-on-clear with tertiary
                        // text. Multi-select keeps the original
                        // "everything filled, radio dot wins" look.
                        let isDimmed = singleSelect && !youSelected

                        HStack(spacing: 14) {
                            PixelCatView(id: UserIDService.currentID(), size: 44, blackAndWhite: false)
                                .clipShape(Circle())

                            Text("You")
                                .font(AppFonts.labelPrimary)
                                .fontWeight(singleSelect && youSelected ? .semibold : .regular)
                                .foregroundColor(isDimmed ? AppColors.textTertiary : AppColors.textPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            // Radio indicator only in multi-select —
                            // single-select rows auto-advance on tap,
                            // so there's no "selected but unconfirmed"
                            // state to visualise.
                            if !singleSelect {
                                Image(systemName: youSelected ? "checkmark.circle.fill" : "circle")
                                    .font(AppFonts.emojiMedium)
                                    .foregroundColor(youSelected ? .accentColor : AppColors.textTertiary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(
                            RoundedRectangle(cornerRadius: AppRadius.large)
                                .fill(isDimmed ? Color.clear : AppColors.backgroundElevated)
                                .overlay(
                                    RoundedRectangle(cornerRadius: AppRadius.large)
                                        .stroke(
                                            isDimmed ? AppColors.textQuaternary.opacity(0.3) : Color.clear,
                                            lineWidth: 1
                                        )
                                )
                        )
                        .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            // Friends list or empty state — same pattern as FriendsView:
            // emptyBox for "ever-empty", search for "no-results-now".
            if filteredFriends.isEmpty {
                VStack(spacing: AppSpacing.md) {
                    if searchText.isEmpty {
                        EmptyBoxIllustration(tint: .neutral, size: .standard)
                    } else {
                        SearchIllustration(tint: .neutral, size: .standard)
                    }
                    Text(searchText.isEmpty ? "No friends yet" : "No results")
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textSecondary)
                    Button { showFriendForm = true } label: {
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
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } else {
                ForEach(filteredFriends) { friend in
                    Button {
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        if singleSelect {
                            // Single-select: tap commits the friend
                            // and triggers auto-advance. No toggle-off
                            // — see the "You" branch above.
                            selection = [friend.id]
                            youSelected = false
                            onSingleSelectAdvance?([friend], false)
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                if selection.contains(friend.id) {
                                    selection.remove(friend.id)
                                } else {
                                    selection.insert(friend.id)
                                }
                            }
                        }
                    } label: {
                        friendRow(friend)
                    }
                    .buttonStyle(.plain)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }
        }
        .listStyle(.plain)
        .animation(.easeInOut(duration: 0.25), value: isSearching)
        .safeAreaInset(edge: .bottom) {
            // Always reserve space; animate content opacity to avoid layout jump
            HStack {
                Spacer()
                Text("\(selectedCount) selected")
                    .font(AppFonts.metaText)
                    .foregroundColor(AppColors.textSecondary)
                    .padding(.horizontal, AppSpacing.md)
                    .padding(.vertical, 6)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .opacity(selectedCount > 0 ? 1 : 0)
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.bottom, AppSpacing.xs)
            .animation(.easeInOut(duration: 0.2), value: selectedCount)
        }
    }

    // MARK: - Group Chip (matches FriendsView style)

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

    // MARK: - Friend Row

    private func friendRow(_ friend: Friend) -> some View {
        let isSelected = selection.contains(friend.id)
        // Same single-select highlight as the "You" row above — a
        // pre-filled selection (e.g. re-entering the settle-up
        // picker) becomes immediately visible without the radio
        // indicator we strip in `singleSelect`.
        let isDimmed = singleSelect && !isSelected

        return HStack(spacing: 14) {
            // Coloured if connected (verified ID via share-link),
            // greyscale otherwise. Same convention as FriendsView.
            PixelCatView(id: friend.id, size: 44, blackAndWhite: !friend.isConnected)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name)
                    .font(AppFonts.labelPrimary)
                    .fontWeight(singleSelect && isSelected ? .semibold : .regular)
                    .foregroundColor(isDimmed ? AppColors.textTertiary : AppColors.textPrimary)
                    .lineLimit(1)

                if !friend.groups.isEmpty {
                    Text(friend.groups.joined(separator: ", "))
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            // Same rationale as the "You" row — hide the radio
            // indicator under `singleSelect`, since tapping auto-
            // advances and there's no transient selection state to
            // reflect.
            if !singleSelect {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(AppFonts.emojiMedium)
                    .foregroundColor(isSelected ? .accentColor : AppColors.textTertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: AppRadius.large)
                .fill(isDimmed ? Color.clear : AppColors.backgroundElevated)
                .overlay(
                    RoundedRectangle(cornerRadius: AppRadius.large)
                        .stroke(
                            isDimmed ? AppColors.textQuaternary.opacity(0.3) : Color.clear,
                            lineWidth: 1
                        )
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
    }
}

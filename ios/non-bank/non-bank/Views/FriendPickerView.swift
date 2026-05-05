import SwiftUI

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
    let onConfirm: ([Friend], Bool) -> Void

    init(
        title: String = "Who to split with",
        subtitle: String = "Based on the number of people, we'll calculate how much each person owes.",
        initialSelection: [Friend] = [],
        includeYou: Bool = false,
        youSelected: Bool = true,
        onConfirm: @escaping ([Friend], Bool) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.initialSelection = initialSelection
        self.includeYou = includeYou
        self.initialYouSelected = youSelected
        self.onConfirm = onConfirm
        _selection = State(initialValue: Set(initialSelection.map(\.id)))
        _youSelected = State(initialValue: youSelected)
    }

    private var hasAnySelection: Bool {
        (includeYou && youSelected) || !selection.isEmpty
    }

    private var selectedCount: Int {
        var count = selection.count
        if includeYou && youSelected { count += 1 }
        return count
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
                $0.groups.contains(where: { $0.lowercased().contains(query) })
            }
        }
        return result
    }

    private var allFilteredSelected: Bool {
        let visible = filteredFriends
        guard !visible.isEmpty || includeYou else { return false }
        let friendsAllSelected = visible.allSatisfy { selection.contains($0.id) }
        let youOk = !includeYou || youSelected
        return friendsAllSelected && youOk
    }

    var body: some View {
        NavigationStack {
            FriendPickerContent(
                title: title,
                subtitle: subtitle,
                includeYou: includeYou,
                youSelected: $youSelected,
                selection: $selection,
                searchText: $searchText,
                selectedGroup: $selectedGroup,
                showFriendForm: $showFriendForm,
                filteredFriends: filteredFriends,
                allFilteredSelected: allFilteredSelected,
                selectedCount: selectedCount,
                hasFriends: !friendStore.friends.isEmpty,
                allGroups: friendStore.allGroups
            )
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .searchable(text: $searchText, prompt: "Search friends")
            .navigationTitle("")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        let selected = friendStore.friends.filter { selection.contains($0.id) }
                        onConfirm(selected, youSelected)
                        dismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(AppFonts.bodyEmphasized)
                    }
                    .disabled(!hasAnySelection)
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
}

// MARK: - Inner Content (reads @Environment(\.isSearching))

private struct FriendPickerContent: View {
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

                // Add new friend (left) + Select all (right) row
                if !filteredFriends.isEmpty || (hasFriends && allGroups.isEmpty) {
                    HStack {
                        // "Add new friend" on the left — only when no groups
                        if hasFriends && allGroups.isEmpty {
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

                        if !filteredFriends.isEmpty {
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            youSelected.toggle()
                        }
                    } label: {
                        HStack(spacing: 14) {
                            PixelCatView(id: UserIDService.currentID(), size: 44, blackAndWhite: false)

                            Text("You")
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textPrimary)
                                .lineLimit(1)

                            Spacer(minLength: 4)

                            Image(systemName: youSelected ? "checkmark.circle.fill" : "circle")
                                .font(AppFonts.emojiMedium)
                                .foregroundColor(youSelected ? .accentColor : AppColors.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .background(AppColors.backgroundElevated)
                        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            if selection.contains(friend.id) {
                                selection.remove(friend.id)
                            } else {
                                selection.insert(friend.id)
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
        HStack(spacing: 14) {
            // Coloured if connected (verified ID via share-link),
            // greyscale otherwise. Same convention as FriendsView.
            PixelCatView(id: friend.id, size: 44, blackAndWhite: !friend.isConnected)

            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                if !friend.groups.isEmpty {
                    Text(friend.groups.joined(separator: ", "))
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            Image(systemName: selection.contains(friend.id) ? "checkmark.circle.fill" : "circle")
                .font(AppFonts.emojiMedium)
                .foregroundColor(selection.contains(friend.id) ? .accentColor : AppColors.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(AppColors.backgroundElevated)
        .clipShape(RoundedRectangle(cornerRadius: AppRadius.large))
        .contentShape(RoundedRectangle(cornerRadius: AppRadius.large))
    }
}

import SwiftUI

struct FriendsView: View {
    @EnvironmentObject var friendStore: FriendStore
    @EnvironmentObject var transactionStore: TransactionStore
    @State private var searchText = ""
    @State private var selectedGroup: String? = nil
    @State private var sheetFriend: FriendSheetItem? = nil
    /// Drives the "can't delete — friend has transactions" alert. We
    /// stash the offending friend + transaction count for the alert
    /// message so the user knows exactly why the swipe-delete didn't
    /// take effect.
    @State private var deleteBlockedFriend: (friend: Friend, txCount: Int)? = nil

    /// Wrapper to distinguish create vs edit vs view in a single sheet
    private enum FriendSheetItem: Identifiable {
        case create
        case view(Friend)
        case edit(Friend)
        var id: String {
            switch self {
            case .create: return "__create__"
            case .view(let f): return "__view__\(f.id)"
            case .edit(let f): return "__edit__\(f.id)"
            }
        }
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
                $0.id.lowercased().contains(query) ||
                $0.groups.contains(where: { $0.lowercased().contains(query) })
            }
        }

        return result
    }

    var body: some View {
        List {
            if !friendStore.allGroups.isEmpty {
                groupFilterSection
            }

            if filteredFriends.isEmpty {
                emptyState
            } else {
                friendsListSection
            }
        }
        .searchable(text: $searchText, prompt: "Search friends")
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(action: { sheetFriend = .create }) {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(item: $sheetFriend) { item in
            switch item {
            case .create:
                FriendFormView(existingGroups: friendStore.allGroups) { newFriend in
                    Task { await friendStore.add(newFriend) }
                }
            case .view(let friend):
                FriendCardView(friend: friend) {
                    sheetFriend = nil
                    // Small delay so the dismiss animation finishes before presenting edit
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        sheetFriend = .edit(friend)
                    }
                }
            case .edit(let friend):
                FriendFormView(
                    friend: friend,
                    existingGroups: friendStore.allGroups
                ) { updated in
                    friendStore.update(updated)
                }
            }
        }
        // "Cannot delete" alert. Driven by `deleteBlockedFriend`
        // (non-nil when the swipe-action found referencing transactions).
        // Tells the user how many transactions are blocking and what
        // their options are — we don't offer "delete anyway" because
        // it'd orphan the transactions and break their debt screens.
        .alert(
            "Can't delete this friend",
            isPresented: Binding(
                get: { deleteBlockedFriend != nil },
                set: { if !$0 { deleteBlockedFriend = nil } }
            ),
            presenting: deleteBlockedFriend
        ) { _ in
            Button("OK", role: .cancel) { deleteBlockedFriend = nil }
        } message: { ctx in
            let txWord = ctx.txCount == 1 ? "transaction" : "transactions"
            Text("\(ctx.friend.name) is part of \(ctx.txCount) split \(txWord). Delete those transactions first, or keep the contact for history.")
        }
    }

    // MARK: - Group Filter

    private var groupFilterSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AppSpacing.sm) {
                    groupChip(label: "All", isSelected: selectedGroup == nil) {
                        selectedGroup = nil
                    }
                    ForEach(friendStore.allGroups, id: \.self) { group in
                        groupChip(label: group, isSelected: selectedGroup == group) {
                            selectedGroup = (selectedGroup == group) ? nil : group
                        }
                    }
                }
                .padding(.horizontal, AppSpacing.pageHorizontal)
                .padding(.vertical, AppSpacing.xs)
            }
        }
        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
    }

    private func groupChip(label: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppFonts.captionEmphasized)
                .padding(.horizontal, AppSpacing.md)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor.opacity(0.15) : Color(.systemGray5))
                .foregroundColor(isSelected ? .accentColor : AppColors.textPrimary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Friends List

    private var friendsListSection: some View {
        Section {
            ForEach(filteredFriends) { friend in
                friendRow(friend)
                    .contentShape(Rectangle())
                    .onTapGesture { sheetFriend = .view(friend) }
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            handleDelete(friend)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
    }

    /// Guarded delete: blocked when this friend appears in any
    /// `splitInfo.friends`, because removing them would orphan those
    /// transactions (debt screens then resolve no `Friend` record and
    /// render a blank page). The alert tells the user what to do —
    /// delete the transactions first or just keep the contact.
    private func handleDelete(_ friend: Friend) {
        let count = transactionsReferencing(friend).count
        if count > 0 {
            deleteBlockedFriend = (friend, count)
            return
        }
        friendStore.remove(friend)
    }

    /// Transactions whose `splitInfo.friends` references the given
    /// friend ID. Computed at delete-time only (not on every render),
    /// so the cost is fine even on large transaction lists.
    private func transactionsReferencing(_ friend: Friend) -> [Transaction] {
        transactionStore.transactions.filter { tx in
            tx.splitInfo?.friends.contains(where: { $0.friendID == friend.id }) ?? false
        }
    }

    private func friendRow(_ friend: Friend) -> some View {
        HStack(spacing: 14) {
            // Connected friends (their ID matches a real userID, set
            // either by importing a share-link from them or by the
            // phantom-upgrade flow) get colored avatars; manually-typed
            // contacts stay B&W until proven real.
            PixelCatView(id: friend.id, size: 44, blackAndWhite: !friend.isConnected)

            VStack(alignment: .leading, spacing: 3) {
                Text(friend.name)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
                    .lineLimit(1)

                HStack(spacing: AppSpacing.xs) {
                    Text(friend.id)
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundColor(AppColors.textTertiary)
                        .lineLimit(1)

                    Button(action: {
                        UIPasteboard.general.string = friend.id
                    }) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundColor(AppColors.textTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }

            Spacer(minLength: 4)

            if let mode = friend.splitMode {
                HStack(spacing: AppSpacing.xs) {
                    SplitModeIcon(mode: mode, size: 18)
                    Text(mode.displayLabel)
                        .font(.system(size: 11))
                        .foregroundColor(AppColors.textTertiary)
                }
            }
        }
        .padding(.vertical, AppSpacing.xs)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        Section {
            VStack(spacing: AppSpacing.md) {
                Image(systemName: "person.2.slash")
                    .font(AppFonts.iconHero)
                    .foregroundColor(AppColors.textTertiary)
                Text(searchText.isEmpty ? "No friends yet" : "No results")
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textSecondary)
                Button { sheetFriend = .create } label: {
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
        }
    }
}

// MARK: - Friend Card View (full-width avatar + data below)

struct FriendCardView: View {
    let friend: Friend
    var onEdit: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var idCopied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Full-width avatar — colored when the friend is
                    // a real user (share-link round-trip proved their
                    // userID), grayscale for manually-typed contacts.
                    // Mirrors the row treatment in `FriendsView`.
                    PixelCatFillView(id: friend.id, blackAndWhite: !friend.isConnected, cornerRadius: AppRadius.large)
                        .padding(.horizontal, AppSpacing.pageHorizontal)
                        .padding(.top, AppSpacing.sm)

                    // Name
                    Text(friend.name)
                        .font(AppFonts.displayMedium)
                        .foregroundColor(AppColors.textPrimary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, AppSpacing.xxl)
                        .padding(.top, AppSpacing.lg)

                    // ID with copy
                    Button(action: {
                        UIPasteboard.general.string = friend.id
                        idCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                            idCopied = false
                        }
                    }) {
                        HStack(spacing: 6) {
                            Text(friend.id)
                                .font(.system(size: 14, weight: .medium, design: .monospaced))
                                .foregroundColor(AppColors.textSecondary)
                            Image(systemName: idCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 12))
                                .foregroundColor(idCopied ? .green : AppColors.textTertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 6)

                    // Details
                    VStack(spacing: 0) {
                        if !friend.groups.isEmpty {
                            detailRow(
                                icon: "person.2",
                                label: "Groups",
                                value: friend.groups.joined(separator: ", ")
                            )
                        }

                        if let mode = friend.splitMode {
                            if !friend.groups.isEmpty {
                                Divider().padding(.leading, 52)
                            }
                            HStack(spacing: AppSpacing.md) {
                                SplitModeIcon(mode: mode, size: 28)

                                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                                    Text("Split mode")
                                        .font(AppFonts.rowDescription)
                                        .foregroundColor(AppColors.textTertiary)
                                    Text(mode.displayLabel)
                                        .font(AppFonts.labelPrimary)
                                        .foregroundColor(AppColors.textPrimary)
                                }

                                Spacer()
                            }
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.vertical, 14)
                        }
                    }
                    .background(AppColors.backgroundElevated)
                    .cornerRadius(AppRadius.medium)
                    .padding(.horizontal, AppSpacing.pageHorizontal)
                    .padding(.top, AppSpacing.xxl)
                }
            }
            .background(AppColors.backgroundPrimary)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                if onEdit != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Edit") {
                            dismiss()
                            onEdit?()
                        }
                    }
                }
            }
        }
    }

    private func detailRow(icon: String, label: String, value: String) -> some View {
        HStack(spacing: AppSpacing.md) {
            Image(systemName: icon)
                .font(AppFonts.bodyRegular)
                .foregroundColor(AppColors.textSecondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                Text(label)
                    .font(AppFonts.rowDescription)
                    .foregroundColor(AppColors.textTertiary)
                Text(value)
                    .font(AppFonts.labelPrimary)
                    .foregroundColor(AppColors.textPrimary)
            }

            Spacer()
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
        .padding(.vertical, 14)
    }
}

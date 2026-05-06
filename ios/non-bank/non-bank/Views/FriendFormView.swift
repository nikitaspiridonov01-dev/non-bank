import SwiftUI

struct FriendFormView: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFieldFocused: Bool
    

    private let existingFriend: Friend?
    private let existingGroups: [String]
    private let isCompact: Bool
    private let onSave: (Friend) -> Void

    @State private var friendID: String
    @State private var name: String
    @State private var groups: [String]
    @State private var selectedSplitMode: SplitMode?
    @State private var idCopied = false

    // Sheets for option selection
    @State private var showGroupSheet = false
    @State private var showSplitModeSheet = false

    // New group input
    @State private var newGroupText = ""

    // Stable snapshot of groups for sheet ordering
    @State private var sheetGroupSnapshot: [String] = []

    private var isEditing: Bool { existingFriend != nil }

    private static let nameMaxLength = 35

    /// Create new friend
    init(existingGroups: [String] = [], isCompact: Bool = false, onSave: @escaping (Friend) -> Void) {
        self.existingFriend = nil
        self.existingGroups = existingGroups
        self.isCompact = isCompact
        self.onSave = onSave
        _friendID = State(initialValue: FriendIDGenerator.generate())
        _name = State(initialValue: "")
        _groups = State(initialValue: [])
        _selectedSplitMode = State(initialValue: nil)
    }

    /// Edit existing friend
    init(friend: Friend, existingGroups: [String] = [], isCompact: Bool = false, onSave: @escaping (Friend) -> Void) {
        self.existingFriend = friend
        self.existingGroups = existingGroups
        self.isCompact = isCompact
        self.onSave = onSave
        _friendID = State(initialValue: friend.id)
        _name = State(initialValue: friend.name)
        _groups = State(initialValue: friend.groups)
        _selectedSplitMode = State(initialValue: friend.splitMode)
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Whether the new group name already exists in the snapshot or selected groups
    private var isDuplicateGroupName: Bool {
        let trimmed = newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return sheetGroupSnapshot.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
            || groups.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame })
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AppColors.backgroundPrimary.ignoresSafeArea()

                VStack(spacing: 0) {
                    if isEditing {
                        ScrollViewReader { proxy in
                            ScrollView {
                                VStack(spacing: 0) {
                                    avatarHeader
                                    // No explicit gap — `avatarHeader`
                                    // already has bottom padding from
                                    // its outer VStack and `nameInput`
                                    // has its own intrinsic vertical
                                    // padding, so this row only added
                                    // visual slack between the avatar
                                    // and the name on edit-mode hero.
                                    nameInput
                                        .id("nameInput")
                                    if !isCompact {
                                        optionButtons
                                            .padding(.top, AppSpacing.md)
                                    }
                                }
                            }
                            .onChange(of: nameFieldFocused) { focused in
                                if focused {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                                        withAnimation(.easeInOut(duration: 0.4)) {
                                            proxy.scrollTo("nameInput", anchor: .center)
                                        }
                                    }
                                }
                            }
                        }
                    } else {
                        // Creation mode: name centered, options at bottom
                        Spacer()

                        nameInput

                        Spacer()

                        if !isCompact {
                            optionButtons
                                .padding(.bottom, AppSpacing.lg)
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "Edit Friend" : "New Friend")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if !isEditing {
                    nameFieldFocused = true
                }
            }
            .sheet(isPresented: $showGroupSheet, onDismiss: {
                newGroupText = ""
            }) {
                groupSelectionSheet
            }
            .sheet(isPresented: $showSplitModeSheet) {
                splitModeSelectionSheet
            }
        }
    }

    // MARK: - Avatar Header (edit only)

    private var avatarHeader: some View {
        VStack(spacing: AppSpacing.md) {
            // Coloured when editing a connected friend (whose userID
            // came from a real share-link round-trip); grayscale for
            // manual contacts and brand-new friends being created.
            // The avatar header only appears in edit mode (`isEditing`),
            // so `existingFriend` is non-nil here in practice.
            //
            // Same 72pt circular avatar as the friend-detail / debts
            // headers — keeps every "friend hero" in the app on one
            // shared shape and size.
            PixelCatView(
                id: friendID,
                size: 72,
                blackAndWhite: !(existingFriend?.isConnected ?? false)
            )
            .clipShape(Circle())
        }
        .frame(maxWidth: .infinity)
        .padding(.top, AppSpacing.sm)
    }

    // MARK: - Large Name Input

    private var nameInput: some View {
        TextField("", text: $name, prompt: Text("Name")
            .font(AppFonts.displayLarge)
            .foregroundColor(AppColors.textDisabled)
        )
        .font(AppFonts.displayLarge)
        .foregroundColor(AppColors.textPrimary)
        .multilineTextAlignment(.center)
        .minimumScaleFactor(0.5)
        .textContentType(.name)
        .submitLabel(.done)
        .focused($nameFieldFocused)
        .onSubmit {
            if isCompact && canSave {
                save()
            }
        }
        .lineLimit(1)
        .padding(.horizontal, AppSpacing.xxl)
        .frame(height: isEditing ? 60 : 90)
        .onChange(of: name) { newValue in
            if newValue.count > Self.nameMaxLength {
                name = String(newValue.prefix(Self.nameMaxLength))
            }
        }
    }

    // MARK: - Option Buttons

    private var optionButtons: some View {
        VStack(spacing: AppSpacing.md) {
            // Group button
            Button(action: {
                showGroupSheet = true
            }) {
                HStack(spacing: 14) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 20, weight: .medium))
                        .foregroundColor(!groups.isEmpty ? .accentColor : AppColors.textTertiary)
                        .frame(width: 36, height: 36)
                        .background(!groups.isEmpty ? Color.accentColor.opacity(0.12) : AppColors.backgroundChip)
                        .clipShape(RoundedRectangle(cornerRadius: 10))

                    if groups.isEmpty {
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text("Assign to group")
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textPrimary)
                            Text("Organize friends into groups like Family, Work, etc.")
                                .font(AppFonts.rowDescription)
                                .foregroundColor(AppColors.textTertiary)
                                .lineLimit(2)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                            Text("Group")
                                .font(AppFonts.rowDescription)
                                .foregroundColor(AppColors.textTertiary)
                            Text(groups.joined(separator: ", "))
                                .font(AppFonts.labelPrimary)
                                .foregroundColor(AppColors.textPrimary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(AppFonts.footnote)
                        .foregroundColor(AppColors.textTertiary)
                }
                .padding(14)
                .background(AppColors.backgroundElevated)
                .cornerRadius(AppRadius.medium)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Default split mode picker temporarily hidden — feature disabled
            // for users until the surrounding flow is ready. Existing
            // `selectedSplitMode` values on edited friends are preserved
            // through save (they're just not editable from this screen).
        }
        .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    // MARK: - Group Selection Sheet

    private var groupSelectionSheet: some View {
        NavigationStack {
            List {
                // Add new group
                Section {
                    HStack {
                        TextField("New group name", text: $newGroupText)
                            .textInputAutocapitalization(.words)
                            .onSubmit { addNewGroup() }

                        Button(action: { addNewGroup() }) {
                            Image(systemName: "plus.circle.fill")
                                .font(AppFonts.emojiMedium)
                                .foregroundColor(.accentColor)
                        }
                        .buttonStyle(.plain)
                        .opacity(newGroupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0 : 1)
                        .disabled(newGroupText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }

                    if isDuplicateGroupName {
                        Text("This group already exists")
                            .font(AppFonts.metaRegular)
                            .foregroundColor(AppColors.danger)
                    }
                } header: {
                    Text("Create New")
                }

                // All groups — stable order from snapshot, toggle style
                if !sheetGroupSnapshot.isEmpty {
                    Section {
                        ForEach(sheetGroupSnapshot, id: \.self) { group in
                            let isSelected = groups.contains(group)
                            Button(action: {
                                if isSelected {
                                    groups.removeAll { $0 == group }
                                } else {
                                    groups.append(group)
                                }
                            }) {
                                HStack {
                                    Text(group)
                                        .font(AppFonts.labelPrimary)
                                        .foregroundColor(AppColors.textPrimary)
                                    Spacer()
                                    if isSelected {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(AppFonts.iconLarge)
                                            .foregroundColor(.accentColor)
                                    } else {
                                        Image(systemName: "circle")
                                            .font(AppFonts.iconLarge)
                                            .foregroundColor(AppColors.textTertiary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Groups")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AppColors.backgroundPrimary)
            .navigationTitle("Groups")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        // Commit any pending typed text so the user
                        // doesn't lose a group they typed but didn't
                        // explicitly +-confirm. `addNewGroup` already
                        // no-ops on empty/duplicate input.
                        addNewGroup()
                        showGroupSheet = false
                    }
                }
            }
            .onAppear {
                sheetGroupSnapshot = buildStableGroupList()
            }
        }
    }

    /// Build stable group list: all unique groups sorted alphabetically
    private func buildStableGroupList() -> [String] {
        var all = Set(groups)
        for g in existingGroups { all.insert(g) }
        return all.sorted()
    }

    private func addNewGroup() {
        let trimmed = newGroupText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isDuplicateGroupName else { return }
        groups.append(trimmed)
        // Insert at the top of the snapshot so new group appears first
        if !sheetGroupSnapshot.contains(trimmed) {
            sheetGroupSnapshot.insert(trimmed, at: 0)
        }
        newGroupText = ""
        // Dismiss keyboard
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    // MARK: - Split Mode Selection Sheet

    private var splitModeSelectionSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // "None" option
                splitModeButton(
                    icon: {
                        Image(systemName: "minus.circle")
                            .font(AppFonts.emojiMedium)
                            .foregroundColor(AppColors.textTertiary)
                            .frame(width: 36, height: 36)
                    },
                    title: "None",
                    subtitle: "No default split mode",
                    isSelected: selectedSplitMode == nil
                ) {
                    selectedSplitMode = nil
                    showSplitModeSheet = false
                }

                ForEach(SplitMode.allCases) { mode in
                    splitModeButton(
                        icon: { SplitModeIcon(mode: mode, size: 36) },
                        title: mode.displayLabel,
                        subtitle: mode.helpText,
                        isSelected: selectedSplitMode == mode
                    ) {
                        selectedSplitMode = mode
                        showSplitModeSheet = false
                    }
                }

                Spacer()
            }
            .padding(.horizontal, AppSpacing.pageHorizontal)
            .padding(.top, AppSpacing.sm)
            .navigationTitle("Default Split Mode")
            .toolbarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showSplitModeSheet = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func splitModeButton<Icon: View>(
        @ViewBuilder icon: () -> Icon,
        title: String,
        subtitle: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                icon()

                VStack(alignment: .leading, spacing: AppSpacing.xxs) {
                    Text(title)
                        .font(AppFonts.labelPrimary)
                        .foregroundColor(AppColors.textPrimary)
                    Text(subtitle)
                        .font(AppFonts.rowDescription)
                        .foregroundColor(AppColors.textTertiary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(AppFonts.iconLarge)
                        .foregroundColor(.accentColor)
                }
            }
            .padding(.vertical, AppSpacing.rowVertical)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Save

    private func save() {
        let friend = Friend(
            id: friendID,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            groups: groups,
            splitMode: selectedSplitMode,
            lastModified: Date()
        )
        onSave(friend)
        dismiss()
    }
}

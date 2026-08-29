import SwiftUI
import UniformTypeIdentifiers

enum TaskFilter: String, CaseIterable, Identifiable {
    case all, active, done
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all:    return "All"
        case .active: return "Active"
        case .done:   return "Done"
        }
    }
}

/// The to-do list: unlimited tasks in collapsible groups, searchable, reorderable,
/// with a Pomodoro estimate on each one.
struct TasksCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: UIState

    @State private var filter: TaskFilter = .all
    @State private var searching = false
    @State private var draft = ""
    @State private var draftEstimate = 1
    @State private var draftGroupID: UUID?
    @State private var newGroupName = ""
    @State private var addingGroup = false
    @FocusState private var draftFocused: Bool
    @FocusState private var searchFocused: Bool
    @FocusState private var groupFieldFocused: Bool

    private func visible(in group: TaskGroup?) -> [TodoItem] {
        store.tasks(in: group).filter { task in
            switch filter {
            case .all:    return true
            case .active: return !task.isDone
            case .done:   return task.isDone
            }
        }
    }

    private var totalVisible: Int {
        visible(in: nil).count + store.groups.reduce(0) { $0 + visible(in: $1).count }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if addingGroup { groupField }

            if totalVisible == 0 {
                emptyState
            } else {
                list
            }

            addRow
        }
        .padding(12)
        .card()
        .onChange(of: draftFocused) { focused in
            // The panel must not close under the pointer while the user is typing.
            ui.isEditing = focused || searchFocused || groupFieldFocused
        }
        .onChange(of: searchFocused) { focused in
            ui.isEditing = focused || draftFocused || groupFieldFocused
        }
        .onAppear { claimFocusIfWanted() }
        .onChange(of: ui.wantsAddFocus) { _ in claimFocusIfWanted() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
            if searching {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(store.accent)
                TextField("Search tasks", text: $store.search)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.text1)
                    .focused($searchFocused)
                IconButton(symbol: "xmark", size: 20, glyph: 8, help: "Clear search") {
                    store.search = ""
                    searching = false
                }
            } else {
                Image(systemName: "checklist")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(store.accent)
                Text("To Do")
                    .font(Theme.ui(13, .semibold))
                    .foregroundStyle(Theme.text1)
                Text("\(store.doneCount)/\(store.tasks.count)")
                    .font(Theme.mono(10.5, .bold))
                    .foregroundStyle(Theme.text3)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.white.opacity(0.06), in: Capsule())

                Spacer(minLength: 6)

                IconButton(symbol: "magnifyingglass", size: 22, glyph: 9.5,
                           help: "Search tasks") {
                    searching = true
                    searchFocused = true
                }

                SegmentedPills(items: TaskFilter.allCases,
                               selection: $filter,
                               label: { $0.title },
                               accent: store.accent)

                overflowMenu
            }
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button("New group…") {
                addingGroup = true
                groupFieldFocused = true
            }
            Button("System load") {
                withAnimation(Theme.snappy) {
                    ui.tab = .system
                    ui.isPinned = true
                }
            }
            Divider()
            Button("Clear completed") { store.clearCompleted() }
                .disabled(store.doneCount == 0)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.text2)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.06), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
    }

    private var groupField: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Theme.groupColor(store.groups.count))
                .frame(width: 8, height: 8)
            TextField("Group name, press return", text: $newGroupName)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.text1)
                .focused($groupFieldFocused)
                .onSubmit {
                    store.addGroup(newGroupName)
                    newGroupName = ""
                    addingGroup = false
                }
            IconButton(symbol: "xmark", size: 20, glyph: 8) {
                newGroupName = ""
                addingGroup = false
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(store.accent.opacity(0.5), lineWidth: 1)
        )
    }

    // MARK: List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 6) {
                let loose = visible(in: nil)
                if !loose.isEmpty {
                    if !store.groups.isEmpty {
                        GroupHeader(name: "Inbox", color: Theme.text3, count: loose.count,
                                    isCollapsed: false, store: store, group: nil)
                    }
                    ForEach(loose) { task in
                        TaskRow(task: task, store: store)
                    }
                }

                ForEach(store.groups) { group in
                    let items = visible(in: group)
                    GroupHeader(name: group.name,
                                color: Theme.groupColor(group.colorIndex),
                                count: items.count,
                                isCollapsed: group.isCollapsed,
                                store: store,
                                group: group)
                    if !group.isCollapsed {
                        ForEach(items) { task in
                            TaskRow(task: task, store: store)
                        }
                    }
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: .infinity)
        // Soften the cut-off so a long list reads as continuing rather than clipped.
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.9),
                                   .init(color: .black.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        // Dropping past the last row moves a task to the end.
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, before: nil)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: store.search.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(emptyMessage)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.text3)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        if !store.search.isEmpty { return "Nothing matches “\(store.search)”" }
        switch filter {
        case .done:   return "Nothing finished yet"
        case .active: return "No active tasks — add one below"
        case .all:    return "Add your first task below.\nGive it an estimate and press return."
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], before target: UUID?) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { value, _ in
            guard let raw = value as? String, let id = UUID(uuidString: raw) else { return }
            DispatchQueue.main.async {
                withAnimation(Theme.contentSpring) { store.move(id, before: target) }
            }
        }
        return true
    }

    // MARK: Add

    private var addRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(draft.isEmpty ? Theme.text3 : store.accent)

            TextField("Add a task, press return", text: $draft)
                .textFieldStyle(.plain)
                .font(Theme.ui(12.5))
                .foregroundStyle(Theme.text1)
                .focused($draftFocused)
                .onSubmit(commit)

            if !store.groups.isEmpty { groupPicker }

            EstimateStepper(value: $draftEstimate, accent: store.accent)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                .strokeBorder(draftFocused ? store.accent.opacity(0.55) : .clear, lineWidth: 1)
        )
        .animation(Theme.snappy, value: draftFocused)
    }

    private var groupPicker: some View {
        Menu {
            Button("Inbox") { draftGroupID = nil }
            ForEach(store.groups) { group in
                Button(group.name) { draftGroupID = group.id }
            }
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(draftGroupColor)
                    .frame(width: 7, height: 7)
                Text(draftGroupName)
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.text2)
                    .lineLimit(1)
            }
            .frame(maxWidth: 74)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Which group new tasks go into")
    }

    private var draftGroupName: String {
        store.groups.first { $0.id == draftGroupID }?.name ?? "Inbox"
    }

    private var draftGroupColor: Color {
        guard let group = store.groups.first(where: { $0.id == draftGroupID }) else {
            return Theme.text3
        }
        return Theme.groupColor(group.colorIndex)
    }

    /// Take the caret if something asked for it, once the field is actually on screen.
    private func claimFocusIfWanted() {
        guard ui.wantsAddFocus else { return }
        filter = .all
        ui.wantsAddFocus = false
        // The panel is still springing open and only just became key, so the responder
        // chain settles over the next few frames. Ask more than once rather than
        // dropping the first thing the user types.
        // One attempt is enough: the delegate only raises the flag once the panel is
        // actually key, so the responder chain is already settled by the time we get
        // here. Repeated attempts used to restart the field's editing session and eat
        // the next return.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            draftFocused = true
        }
    }

    private func commit() {
        guard store.addTask(draft, estimate: draftEstimate, groupID: draftGroupID) else { return }
        draft = ""
        draftEstimate = 1
        // Adding rebuilds the list, which can pull focus out of the field for a frame.
        // Put it back so a run of quick entries all land.
        DispatchQueue.main.async { draftFocused = true }
    }
}

// MARK: - Group header

private struct GroupHeader: View {
    let name: String
    let color: Color
    let count: Int
    let isCollapsed: Bool
    @ObservedObject var store: AppStore
    let group: TaskGroup?

    @State private var hovering = false
    @State private var isRenaming = false
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

    var body: some View {
        HStack(spacing: 7) {
            if let group {
                Button { withAnimation(Theme.snappy) { store.toggleGroup(group.id) } } label: {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(Theme.text3)
                        .frame(width: 10)
                }
                .buttonStyle(.plain)
            } else {
                Image(systemName: "tray")
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 10)
            }

            Circle().fill(color).frame(width: 7, height: 7)

            if isRenaming, let group {
                TextField("Group", text: $renameText)
                    .textFieldStyle(.plain)
                    .font(Theme.ui(11, .bold))
                    .foregroundStyle(Theme.text1)
                    .focused($renameFocused)
                    .onSubmit {
                        store.renameGroup(group.id, to: renameText)
                        isRenaming = false
                    }
            } else {
                Text(name.uppercased())
                    .font(Theme.ui(9.5, .bold))
                    .kerning(0.7)
                    .foregroundStyle(Theme.text2)
            }

            Text("\(count)")
                .font(Theme.mono(9.5, .bold))
                .foregroundStyle(Theme.text3)

            Spacer(minLength: 4)

            if let group {
                IconButton(symbol: "paintpalette", size: 18, glyph: 8,
                           help: "Change colour") { store.cycleGroupColor(group.id) }
                IconButton(symbol: "pencil", size: 18, glyph: 8,
                           help: "Rename group") {
                    renameText = group.name
                    isRenaming = true
                    renameFocused = true
                }
                IconButton(symbol: "trash", size: 18, glyph: 8,
                           help: "Delete group") {
                    withAnimation(Theme.contentSpring) { store.deleteGroup(group.id) }
                }
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .padding(.bottom, 1)
        .opacity(0.85)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) {
            guard let group else { return }
            renameText = group.name
            isRenaming = true
            renameFocused = true
        }
    }
}

// MARK: - Row

private struct TaskRow: View {
    let task: TodoItem
    @ObservedObject var store: AppStore

    @State private var hovering = false
    @State private var isTarget = false
    @State private var isRenaming = false
    @State private var isEditingNote = false
    @State private var renameText = ""
    @State private var noteText = ""
    @FocusState private var fieldFocused: Bool

    private var isActive: Bool { store.activeTaskID == task.id }
    private var isTicking: Bool { isActive && store.isRunning && store.phase == .focus }

    var body: some View {
        HStack(spacing: 10) {
            checkbox

            VStack(alignment: .leading, spacing: 1) {
                if isRenaming {
                    TextField("Task", text: $renameText)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(12.5, .semibold))
                        .foregroundStyle(Theme.text1)
                        .focused($fieldFocused)
                        .onSubmit {
                            store.rename(task.id, to: renameText)
                            isRenaming = false
                        }
                } else {
                    HStack(spacing: 5) {
                        if task.isPriority {
                            Image(systemName: "star.fill")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Theme.gold)
                        }
                        Text(task.title)
                            .font(Theme.ui(12.5, .semibold))
                            .foregroundStyle(task.isDone ? Theme.text2 : Theme.text1)
                            .strikethrough(task.isDone, color: Theme.text3)
                            .lineLimit(1)
                    }
                }

                if isEditingNote {
                    TextField("Note", text: $noteText)
                        .textFieldStyle(.plain)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.text2)
                        .focused($fieldFocused)
                        .onSubmit {
                            store.setNote(task.id, noteText)
                            isEditingNote = false
                        }
                } else if !task.note.isEmpty {
                    Text(task.note)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            // Only shown once it says something: a plain 0/1 is noise, and the room is
            // better spent on the task's own name.
            if !task.isDone, task.estimate > 1 || task.completed > 0 {
                PomodoroChip(task: task, accent: store.accent) {
                    store.setEstimate(task.id, task.estimate + 1)
                }
            }

            // These stay visible rather than appearing on hover: the island is an
            // overlay in an inactive app, where macOS does not deliver hover at all.
            HStack(spacing: 4) {
                IconButton(symbol: task.isPriority ? "star.fill" : "star",
                           size: 22, glyph: 9,
                           tint: task.isPriority ? Theme.gold : Theme.text3,
                           help: task.isPriority ? "Remove priority" : "Mark as priority") {
                    withAnimation(Theme.contentSpring) { store.togglePriority(task.id) }
                }
                rowMenu
                IconButton(symbol: "xmark", size: 22, glyph: 9,
                           tint: Theme.text3, help: "Delete task") {
                    withAnimation(Theme.contentSpring) { store.delete(task.id) }
                }
            }
            .opacity(isActive ? 1 : 0.62)

            Button { store.toggle(task: task.id) } label: {
                ZStack {
                    Circle()
                        .fill(isTicking ? Theme.danger : store.accent)
                        .frame(width: 27, height: 27)
                        .shadow(color: (isTicking ? Theme.danger : store.accent).opacity(0.5),
                                radius: isTicking ? 8 : 0)
                    Image(systemName: isTicking ? "pause.fill" : "play.fill")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(.white)
                        .offset(x: isTicking ? 0 : 1)
                }
            }
            .buttonStyle(.plain)
            .disabled(task.isDone)
            .opacity(task.isDone ? 0.3 : 1)
            .help(isTicking ? "Pause" : "Focus on this task")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(background)
        .overlay(alignment: .leading) {
            // Active task carries a coloured spine.
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(store.accent)
                .frame(width: 3, height: 22)
                .padding(.leading, 2)
                .opacity(isActive && !task.isDone ? 1 : 0)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(store.accent)
                .frame(height: 2)
                .opacity(isTarget ? 1 : 0)
        }
        .contentShape(Rectangle())
        .onHover { value in withAnimation(Theme.snappy) { hovering = value } }
        .onTapGesture(count: 2) {
            renameText = task.title
            isRenaming = true
            fieldFocused = true
        }
        .onTapGesture { store.select(task.id) }
        .onDrag { NSItemProvider(object: task.id.uuidString as NSString) }
        .onDrop(of: [.text], isTargeted: $isTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let raw = value as? String, let id = UUID(uuidString: raw) else { return }
                DispatchQueue.main.async {
                    withAnimation(Theme.contentSpring) {
                        store.move(id, before: task.id)
                        store.assign(id, to: task.groupID)
                    }
                }
            }
            return true
        }
        .contextMenu {
            Button(task.isDone ? "Mark as not done" : "Mark as done") { store.toggleDone(task.id) }
            Button(task.isPriority ? "Remove priority" : "Mark as priority") {
                store.togglePriority(task.id)
            }
            Button("Edit note…") {
                noteText = task.note
                isEditingNote = true
                fieldFocused = true
            }
            if !store.groups.isEmpty {
                Menu("Move to") {
                    Button("Inbox") { store.assign(task.id, to: nil) }
                    ForEach(store.groups) { group in
                        Button(group.name) { store.assign(task.id, to: group.id) }
                    }
                }
            }
            Divider()
            Button("Focus on this") { store.toggle(task: task.id) }
            Button("Delete", role: .destructive) { store.delete(task.id) }
        }
    }

    /// Right-click menus do not open over a non-activating panel, so every action in
    /// the context menu is also reachable from this button.
    private var rowMenu: some View {
        Menu {
            Button(task.isDone ? "Mark as not done" : "Mark as done") { store.toggleDone(task.id) }
            Button("Edit note…") {
                noteText = task.note
                isEditingNote = true
                fieldFocused = true
            }
            Button("Rename…") {
                renameText = task.title
                isRenaming = true
                fieldFocused = true
            }
            Divider()
            Menu("Move to") {
                Button("Inbox") { store.assign(task.id, to: nil) }
                ForEach(store.groups) { group in
                    Button(group.name) { store.assign(task.id, to: group.id) }
                }
            }
            Divider()
            Button("Delete", role: .destructive) {
                withAnimation(Theme.contentSpring) { store.delete(task.id) }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.text3)
                .frame(width: 22, height: 22)
                .background(Color.white.opacity(0.06), in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
        .help("More actions")
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
            .fill(isActive && !task.isDone
                  ? store.accent.opacity(0.14)
                  : (hovering ? Theme.rowHover : Theme.row))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.rowRadius, style: .continuous)
                    .strokeBorder(isActive && !task.isDone
                                  ? store.accent.opacity(0.35) : .clear, lineWidth: 1)
            )
    }

    private var checkbox: some View {
        Button { withAnimation(Theme.snappy) { store.toggleDone(task.id) } } label: {
            ZStack {
                Circle()
                    .strokeBorder(task.isDone ? store.accent : Theme.text2, lineWidth: 1.6)
                    .frame(width: 19, height: 19)
                if task.isDone {
                    Circle().fill(store.accent).frame(width: 19, height: 19)
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .black))
                        .foregroundStyle(.white)
                }
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Estimate

/// `done/estimate` pomodoros for a task. Click to add one to the estimate.
private struct PomodoroChip: View {
    let task: TodoItem
    let accent: Color
    let bump: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "timer")
                .font(.system(size: 8.5, weight: .bold))
            Text("\(task.completed)/\(task.estimate)")
                .font(Theme.mono(10, .bold))
        }
        .foregroundStyle(task.completed >= task.estimate ? accent : Theme.text3)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            Capsule().fill(hovering ? Color.white.opacity(0.12) : Color.white.opacity(0.06))
        )
        .onHover { hovering = $0 }
        .onTapGesture(perform: bump)
        .help("Estimated pomodoros — click to add one")
    }
}

/// Estimate picker shown in the add-task row.
private struct EstimateStepper: View {
    @Binding var value: Int
    let accent: Color

    var body: some View {
        HStack(spacing: 5) {
            IconButton(symbol: "minus", size: 17, glyph: 7) { value = max(1, value - 1) }
            HStack(spacing: 3) {
                Image(systemName: "timer")
                    .font(.system(size: 8.5, weight: .bold))
                Text("\(value)")
                    .font(Theme.mono(10, .bold))
            }
            .foregroundStyle(accent)
            .frame(width: 26)
            IconButton(symbol: "plus", size: 17, glyph: 7) { value = min(12, value + 1) }
        }
        .help("Pomodoros you expect this to take")
    }
}

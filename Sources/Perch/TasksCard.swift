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

/// The to-do list: unlimited tasks, scrollable, reorderable by drag, with a Pomodoro
/// estimate per task.
struct TasksCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: UIState

    @State private var filter: TaskFilter = .all
    @State private var draft = ""
    @State private var draftEstimate = 1
    @FocusState private var draftFocused: Bool

    private var visible: [TodoItem] {
        switch filter {
        case .all:    return store.tasks
        case .active: return store.tasks.filter { !$0.isDone }
        case .done:   return store.tasks.filter(\.isDone)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header

            if visible.isEmpty {
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
            ui.isEditing = focused
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 7) {
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

            if store.doneCount > 0 {
                IconButton(symbol: "trash", size: 22, glyph: 9.5,
                           help: "Clear completed") { store.clearCompleted() }
            }

            SegmentedPills(items: TaskFilter.allCases,
                           selection: $filter,
                           label: { $0.title },
                           accent: store.accent)
        }
    }

    // MARK: List

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 6) {
                ForEach(visible) { task in
                    TaskRow(task: task, store: store)
                }
            }
            .padding(.bottom, 2)
        }
        .frame(maxHeight: .infinity)
        // Soften the cut-off so a long list reads as continuing rather than clipped.
        .mask(
            LinearGradient(stops: [.init(color: .black, location: 0),
                                   .init(color: .black, location: 0.88),
                                   .init(color: .black.opacity(0), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        )
        // Dropping past the last row moves a task to the end.
        .onDrop(of: [.text], isTargeted: nil) { providers in
            handleDrop(providers, before: nil)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: filter == .done ? "tray" : "checkmark.circle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.text3)
            Text(filter == .done ? "Nothing finished yet" : "All clear — add something below")
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private func commit() {
        if store.addTask(draft, estimate: draftEstimate) {
            draft = ""
            draftEstimate = 1
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
    @State private var renameText = ""
    @FocusState private var renameFocused: Bool

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
                        .focused($renameFocused)
                        .onSubmit {
                            store.rename(task.id, to: renameText)
                            isRenaming = false
                        }
                } else {
                    Text(task.title)
                        .font(Theme.ui(12.5, .semibold))
                        .foregroundStyle(task.isDone ? Theme.text2 : Theme.text1)
                        .strikethrough(task.isDone, color: Theme.text3)
                        .lineLimit(1)
                }
                if !task.note.isEmpty {
                    Text(task.note)
                        .font(Theme.ui(10.5))
                        .foregroundStyle(Theme.text3)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 6)

            if !task.isDone {
                PomodoroChip(task: task, accent: store.accent) {
                    store.setEstimate(task.id, task.estimate + 1)
                }
            }

            if hovering {
                IconButton(symbol: "xmark", size: 22, glyph: 9,
                           tint: Theme.text3, help: "Delete task") {
                    withAnimation(Theme.contentSpring) { store.delete(task.id) }
                }
                .transition(.opacity.combined(with: .scale))
            }

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
            renameFocused = true
        }
        .onTapGesture { store.select(task.id) }
        .onDrag { NSItemProvider(object: task.id.uuidString as NSString) }
        .onDrop(of: [.text], isTargeted: $isTarget) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { value, _ in
                guard let raw = value as? String, let id = UUID(uuidString: raw) else { return }
                DispatchQueue.main.async {
                    withAnimation(Theme.contentSpring) { store.move(id, before: task.id) }
                }
            }
            return true
        }
        .contextMenu {
            Button(task.isDone ? "Mark as not done" : "Mark as done") { store.toggleDone(task.id) }
            Button("Focus on this") { store.toggle(task: task.id) }
            Divider()
            Button("Delete", role: .destructive) { store.delete(task.id) }
        }
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

/// `done/estimate` pomodoros for a task. Click to add one to the estimate; right-click
/// to take one away.
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

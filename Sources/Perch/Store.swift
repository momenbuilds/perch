import AppKit
import Combine
import SwiftUI
import Foundation
import UserNotifications

/// The whole app state: the Pomodoro engine, the task list, the daily history and the
/// user's settings. Persisted to Application Support and restored on launch.
@MainActor
final class AppStore: ObservableObject {

    // MARK: Published state

    @Published var settings: Settings { didSet { settingsChanged(from: oldValue) } }
    @Published var tasks: [TodoItem] = []
    @Published var groups: [TaskGroup] = []
    @Published var activeTaskID: UUID?
    /// Live text filter over the task list.
    @Published var search = ""

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published var remaining: TimeInterval = 25 * 60
    /// Focus sessions finished since the last long break.
    @Published private(set) var cyclePosition = 0

    @Published private(set) var days: [String: DayStat] = [:]
    /// Recently finished focus sessions, newest last.
    @Published private(set) var log: [SessionRecord] = []
    /// Bumped every time a focus session lands, so the UI can throw confetti.
    @Published private(set) var celebration = 0
    /// Transient banner shown inside the island ("Break time", "Nice work" …).
    @Published var toast: String?

    private var ticker: AnyCancellable?
    private var saveBag: AnyCancellable?
    private var toastWork: DispatchWorkItem?

    // MARK: Derived

    /// Focus uses the user's chosen accent; breaks keep their own fixed colours so a
    /// glance at the island tells you which kind of phase is running.
    var accent: Color {
        switch phase {
        case .focus:      return Theme.accent(settings.accentIndex)
        case .shortBreak: return Theme.shortAccent
        case .longBreak:  return Theme.longAccent
        }
    }

    /// Phase length, with a development override so the UI can be exercised without
    /// waiting 25 minutes: PB_SESSION_SECONDS=60 swift run
    var phaseLength: TimeInterval {
        if let raw = ProcessInfo.processInfo.environment["PB_SESSION_SECONDS"],
           let seconds = Double(raw), seconds > 0 {
            return seconds
        }
        return settings.length(for: phase)
    }

    /// 0…1 through the current phase — what the hairline traces.
    var progress: Double {
        guard phaseLength > 0 else { return 0 }
        return min(max(1 - remaining / phaseLength, 0), 1)
    }

    var clockText: String {
        let total = max(0, Int(remaining.rounded()))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    var openTasks: [TodoItem] { tasks.filter { !$0.isDone } }
    var doneCount: Int { tasks.filter(\.isDone).count }

    var activeTask: TodoItem? {
        if let id = activeTaskID, let hit = tasks.first(where: { $0.id == id }), !hit.isDone {
            return hit
        }
        return openTasks.first
    }

    /// What the collapsed pill says on its right-hand side.
    var subtitle: String {
        if phase.isBreak { return isRunning ? "Take a breather" : phase.title }
        return activeTask?.title ?? "No task yet"
    }

    // MARK: Stats

    var today: DayStat { days[Self.key(Date())] ?? DayStat() }

    var totalSessions: Int { days.values.reduce(0) { $0 + $1.sessions } }

    /// Today's finished sessions, newest first.
    var todaysLog: [SessionRecord] {
        log.filter { Calendar.current.isDateInToday($0.finishedAt) }.reversed()
    }

    /// How many logged sessions finished in each hour of the day.
    var hourHistogram: [Int] {
        var counts = [Int](repeating: 0, count: 24)
        let calendar = Calendar.current
        for record in log {
            let hour = calendar.component(.hour, from: record.finishedAt)
            if hour >= 0, hour < 24 { counts[hour] += 1 }
        }
        return counts
    }

    /// Progress toward today's session goal, 0…1.
    var goalProgress: Double {
        guard settings.dailyGoal > 0 else { return 0 }
        return min(Double(today.sessions) / Double(settings.dailyGoal), 1)
    }
    var totalFocusMinutes: Int { days.values.reduce(0) { $0 + $1.focusSeconds } / 60 }

    /// Consecutive days ending today (or yesterday, if today is still empty).
    var currentStreak: Int {
        let cal = Calendar.current
        var day = cal.startOfDay(for: Date())
        if (days[Self.key(day)]?.sessions ?? 0) == 0 {
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = prev
        }
        var n = 0
        while (days[Self.key(day)]?.sessions ?? 0) > 0 {
            n += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    var bestStreak: Int {
        let cal = Calendar.current
        let active = days.filter { $0.value.sessions > 0 }.keys.compactMap(Self.date(from:)).sorted()
        var best = 0, run = 0
        var previous: Date?
        for day in active {
            if let p = previous, let next = cal.date(byAdding: .day, value: 1, to: p),
               cal.isDate(next, inSameDayAs: day) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
            previous = day
        }
        return best
    }

    /// Session counts for the last `count` days, oldest first.
    func recent(days count: Int) -> [(date: Date, stat: DayStat)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        return (0..<count).reversed().compactMap { offset in
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return (day, days[Self.key(day)] ?? DayStat())
        }
    }

    // MARK: Lifecycle

    /// When false the store neither reads nor writes the on-disk state. The render and
    /// self-test harnesses use this so they can never touch real data.
    let persists: Bool

    init(persists: Bool = true) {
        self.persists = persists
        let saved = persists ? Persistence.load() : nil
        settings = saved?.settings ?? Settings()
        tasks = saved?.tasks ?? []
        groups = saved?.groups ?? []
        days = saved?.days ?? [:]
        log = saved?.log ?? []
        phase = saved?.phase ?? .focus
        cyclePosition = saved?.cyclePosition ?? 0
        activeTaskID = saved?.activeTaskID ?? tasks.first?.id
        // A settings change between launches must not leave a stale remainder that
        // would read as negative progress.
        remaining = min(saved?.remaining ?? settings.length(for: phase), settings.length(for: phase))
        if let raw = ProcessInfo.processInfo.environment["PB_SESSION_SECONDS"],
           let seconds = Double(raw), seconds > 0 {
            remaining = seconds
        }

        if persists {
            saveBag = objectWillChange
                .debounce(for: .seconds(1), scheduler: RunLoop.main)
                .sink { [weak self] _ in self?.save() }
        }
    }

    // MARK: Engine

    func start() {
        if remaining <= 0 { remaining = phaseLength }
        if phase == .focus, activeTaskID == nil { activeTaskID = openTasks.first?.id }
        isRunning = true
        ticker = Timer.publish(every: 1, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in self?.tick() }
    }

    func pause() {
        isRunning = false
        ticker?.cancel()
        ticker = nil
        save()
    }

    func toggle() { isRunning ? pause() : start() }

    /// Play/pause from a task row: tapping a different task switches to it and restarts.
    func toggle(task id: UUID) {
        if phase != .focus {
            switchTo(.focus, autoStart: true)
            activeTaskID = id
            return
        }
        if id != activeTaskID {
            activeTaskID = id
            remaining = phaseLength
            if !isRunning { start() }
            return
        }
        toggle()
    }

    func reset() {
        pause()
        remaining = phaseLength
    }

    /// Jump to the next phase without banking the current one.
    func skip() {
        advance(counting: false)
    }

    func switchTo(_ next: Phase, autoStart: Bool = false) {
        pause()
        phase = next
        remaining = phaseLength
        if autoStart { start() }
    }

    private func tick() {
        guard isRunning else { return }
        remaining = max(0, remaining - 1)
        if phase == .focus { bankFocusSecond() }
        if remaining == 0 { advance(counting: true) }
    }

    /// Focus time is credited as it is earned, so a partially finished session still
    /// shows up in today's minutes.
    private func bankFocusSecond() {
        let k = Self.key(Date())
        var stat = days[k] ?? DayStat()
        stat.focusSeconds += 1
        days[k] = stat
    }

    /// Internal rather than private so the self-test can drive whole cycles instantly.
    func advance(counting: Bool) {
        let finished = phase
        pause()

        if finished == .focus, counting {
            let k = Self.key(Date())
            var stat = days[k] ?? DayStat()
            stat.sessions += 1
            days[k] = stat

            let title = activeTask?.title ?? "Focus"
            if let id = activeTaskID, let idx = tasks.firstIndex(where: { $0.id == id }) {
                tasks[idx].completed += 1
            }
            log.append(SessionRecord(finishedAt: Date(), taskTitle: title,
                                     minutes: settings.focusMinutes))
            if log.count > 300 { log.removeFirst(log.count - 300) }
            cyclePosition += 1
            celebration += 1
            notify(title: "Focus session complete",
                   body: "\(cyclePosition % max(settings.sessionsPerCycle, 1) == 0 ? "Long break" : "Break") time — you've earned it.")
            flash("Nice work · session \(today.sessions) today")
        } else if finished.isBreak, counting {
            notify(title: "Break over", body: "Back to it.")
            flash("Break's over")
        }

        let next: Phase
        if finished == .focus {
            next = cyclePosition % max(settings.sessionsPerCycle, 1) == 0 ? .longBreak : .shortBreak
        } else {
            next = .focus
        }

        phase = next
        remaining = phaseLength
        save()

        let shouldAutoStart = next.isBreak ? settings.autoStartBreaks : settings.autoStartFocus
        if counting, shouldAutoStart { start() }
    }

    // MARK: Tasks

    @discardableResult
    func addTask(_ title: String, note: String = "", estimate: Int = 1,
                 groupID: UUID? = nil) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        tasks.append(TodoItem(title: trimmed, note: note, estimate: max(1, estimate),
                              groupID: groupID))
        if activeTaskID == nil { activeTaskID = tasks.last?.id }
        save()
        return true
    }

    func toggleDone(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isDone.toggle()
        tasks[idx].completedAt = tasks[idx].isDone ? Date() : nil
        if tasks[idx].isDone {
            if activeTaskID == id {
                if isRunning, phase == .focus { pause() }
                activeTaskID = openTasks.first?.id
            }
            flash("\(tasks[idx].title) — done")
        }
        save()
    }

    func delete(_ id: UUID) {
        guard let hit = tasks.first(where: { $0.id == id }) else { return }
        tasks.removeAll { $0.id == id }
        if activeTaskID == id {
            if isRunning, phase == .focus { pause() }
            activeTaskID = openTasks.first?.id
        }
        flash("Deleted “\(hit.title)”")
        save()
    }

    func clearCompleted() {
        let n = doneCount
        guard n > 0 else { return }
        tasks.removeAll { $0.isDone }
        flash("Cleared \(n) completed task\(n == 1 ? "" : "s")")
        save()
    }

    func togglePriority(_ id: UUID) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].isPriority.toggle()
        save()
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        save()
    }

    func assign(_ id: UUID, to groupID: UUID?) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].groupID = groupID
        save()
    }

    // MARK: Groups

    @discardableResult
    func addGroup(_ name: String) -> TaskGroup? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let group = TaskGroup(name: trimmed, colorIndex: groups.count % Theme.groupPalette.count)
        groups.append(group)
        flash("Added group “\(trimmed)”")
        save()
        return group
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].name = trimmed
        save()
    }

    func toggleGroup(_ id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].isCollapsed.toggle()
        save()
    }

    func cycleGroupColor(_ id: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == id }) else { return }
        groups[idx].colorIndex = (groups[idx].colorIndex + 1) % Theme.groupPalette.count
        save()
    }

    /// Deleting a group keeps its tasks — they fall back to the ungrouped list.
    func deleteGroup(_ id: UUID) {
        guard let group = groups.first(where: { $0.id == id }) else { return }
        for index in tasks.indices where tasks[index].groupID == id {
            tasks[index].groupID = nil
        }
        groups.removeAll { $0.id == id }
        flash("Deleted group “\(group.name)” — its tasks moved to Inbox")
        save()
    }

    func tasks(in group: TaskGroup?) -> [TodoItem] {
        let matching = tasks.filter { $0.groupID == group?.id }
        return sorted(matching)
    }

    /// Priority first, then unfinished, then original order.
    func sorted(_ items: [TodoItem]) -> [TodoItem] {
        items.filter { matchesSearch($0) }
            .enumerated()
            .sorted { lhs, rhs in
                if lhs.element.isDone != rhs.element.isDone { return !lhs.element.isDone }
                if lhs.element.isPriority != rhs.element.isPriority { return lhs.element.isPriority }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func matchesSearch(_ item: TodoItem) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return true }
        return item.title.lowercased().contains(query) || item.note.lowercased().contains(query)
    }

    func setEstimate(_ id: UUID, _ value: Int) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].estimate = max(1, min(value, 12))
        save()
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].title = trimmed
        save()
    }

    func select(_ id: UUID) {
        activeTaskID = id
        if phase == .focus, !isRunning { remaining = phaseLength }
    }

    /// Drag-and-drop reorder.
    func move(_ id: UUID, before target: UUID?) {
        guard let from = tasks.firstIndex(where: { $0.id == id }) else { return }
        let item = tasks.remove(at: from)
        if let target, let to = tasks.firstIndex(where: { $0.id == target }) {
            tasks.insert(item, at: to)
        } else {
            tasks.append(item)
        }
        save()
    }

    // MARK: Feedback

    private func flash(_ message: String) {
        toastWork?.cancel()
        withAnimation(Theme.contentSpring) { toast = message }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(Theme.contentSpring) { self?.toast = nil }
        }
        toastWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.6, execute: work)
    }

    private func notify(title: String, body: String) {
        if let sound = settings.chime.systemName { NSSound(named: sound)?.play() }
        guard settings.showNotifications, Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: Settings side effects

    private func settingsChanged(from old: Settings) {
        if old.length(for: phase) != settings.length(for: phase), !isRunning {
            remaining = phaseLength
        }
        remaining = min(remaining, phaseLength)
        if old.launchAtLogin != settings.launchAtLogin {
            LoginItem.set(enabled: settings.launchAtLogin)
        }
        save()
    }

    func clearAllData() {
        pause()
        tasks = []
        groups = []
        days = [:]
        log = []
        cyclePosition = 0
        phase = .focus
        activeTaskID = tasks.first?.id
        remaining = phaseLength
        flash("Everything reset")
        save()
    }

    /// Fills an in-memory store with a believable working set, for `--demo` and the
    /// offscreen renderer. Never called by the shipping app path.
    func seedDemoContent() {
        let client = addGroup("Client work")
        let study = addGroup("Study")
        addTask("Draft the Q3 proposal", note: "Two pages, no fluff", estimate: 4, groupID: client?.id)
        addTask("Invoice the client", note: "Net 14", estimate: 1, groupID: client?.id)
        addTask("Client call prep", estimate: 2, groupID: client?.id)
        addTask("Study SwiftUI layout", note: "Chapter 4", estimate: 3, groupID: study?.id)
        addTask("Read the concurrency guide", estimate: 2, groupID: study?.id)
        addTask("Review pull requests", note: "Three open", estimate: 2)
        addTask("Write release notes", estimate: 1)
        addTask("Plan next sprint", estimate: 2)
        addTask("Fix the hover flicker", note: "Only on external displays", estimate: 1)
        addTask("Update the README", estimate: 1)
        togglePriority(tasks[0].id)
        toggleDone(tasks[6].id)
        tasks[0].completed = 2
        select(tasks[0].id)

        let calendar = Calendar.current
        for offset in [0, 1, 2, 4, 5, 9, 12, 13, 14, 20, 27] {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { continue }
            seedForPreview(day: day, sessions: (offset % 3) + 1,
                           title: tasks[offset % tasks.count].title)
        }
        remaining = phaseLength * 0.4
    }

    /// Used only by the offscreen preview renderer to fabricate a believable history.
    /// It is never reachable from the running app.
    func seedForPreview(day: Date, sessions: Int, title: String) {
        let key = Self.key(day)
        var stat = days[key] ?? DayStat()
        stat.sessions += sessions
        stat.focusSeconds += sessions * settings.focusMinutes * 60
        days[key] = stat
        for index in 0..<sessions {
            let finished = Calendar.current.date(bySettingHour: 9 + index * 2, minute: 15,
                                                 second: 0, of: day) ?? day
            log.append(SessionRecord(finishedAt: finished, taskTitle: title,
                                     minutes: settings.focusMinutes))
        }
    }

    // MARK: Persistence

    static func key(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    static func date(from key: String) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        var c = DateComponents()
        c.year = parts[0]; c.month = parts[1]; c.day = parts[2]
        return Calendar.current.date(from: c)
    }

    func save() {
        guard persists else { return }
        Persistence.save(PersistedState(settings: settings,
                                        tasks: tasks,
                                        groups: groups,
                                        days: days,
                                        log: log,
                                        phase: phase,
                                        cyclePosition: cyclePosition,
                                        remaining: remaining,
                                        activeTaskID: activeTaskID))
    }
}

// MARK: - Disk

struct PersistedState: Codable {
    var settings: Settings
    var tasks: [TodoItem]
    var groups: [TaskGroup]?
    var days: [String: DayStat]
    var log: [SessionRecord]?
    var phase: Phase
    var cyclePosition: Int
    var remaining: TimeInterval
    var activeTaskID: UUID?
}

enum Persistence {
    /// Where the JSON lives, exposed so the app can reveal or export it.
    static var fileURL: URL { url }

    private static var url: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("state.json")
    }

    static func load() -> PersistedState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PersistedState.self, from: data)
    }

    static func save(_ state: PersistedState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

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
    @Published var activeTaskID: UUID?

    @Published private(set) var phase: Phase = .focus
    @Published private(set) var isRunning = false
    @Published var remaining: TimeInterval = 25 * 60
    /// Focus sessions finished since the last long break.
    @Published private(set) var cyclePosition = 0

    @Published private(set) var days: [String: DayStat] = [:]
    /// Bumped every time a focus session lands, so the UI can throw confetti.
    @Published private(set) var celebration = 0
    /// Transient banner shown inside the island ("Break time", "Nice work" …).
    @Published var toast: String?

    private var ticker: AnyCancellable?
    private var saveBag: AnyCancellable?
    private var toastWork: DispatchWorkItem?

    // MARK: Derived

    var accent: Color { phase.accent }

    var phaseLength: TimeInterval { settings.length(for: phase) }

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

    init() {
        let saved = Persistence.load()
        settings = saved?.settings ?? Settings()
        tasks = saved?.tasks ?? AppStore.starterTasks
        days = saved?.days ?? AppStore.sampleHistory()
        phase = saved?.phase ?? .focus
        cyclePosition = saved?.cyclePosition ?? 0
        activeTaskID = saved?.activeTaskID ?? tasks.first?.id
        // A settings change between launches must not leave a stale remainder that
        // would read as negative progress.
        remaining = min(saved?.remaining ?? settings.length(for: phase), settings.length(for: phase))

        saveBag = objectWillChange
            .debounce(for: .seconds(1), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.save() }
    }

    private static var starterTasks: [TodoItem] {
        [
            TodoItem(title: "Do client works", note: "Create 10 Logos for Marc's company", estimate: 4),
            TodoItem(title: "Ship the island", note: "Polish the expanded panel", estimate: 2),
            TodoItem(title: "Inbox zero", note: "Reply to everything from Monday", estimate: 1)
        ]
    }

    /// Plausible activity for the last 30 days so a fresh install has a grid to show.
    /// "Clear All Data" wipes it.
    static func sampleHistory() -> [String: DayStat] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var out: [String: DayStat] = [:]
        for offset in 0..<30 {
            guard let day = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let roll = offset == 0 ? 8 : Int.random(in: 0...9)
            guard roll > 2 else { continue }
            let sessions = roll > 7 ? 4 : (roll > 5 ? 3 : (roll > 4 ? 2 : 1))
            out[key(day)] = DayStat(sessions: sessions, focusSeconds: sessions * 25 * 60)
        }
        return out
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
        remaining = settings.length(for: next)
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

    private func advance(counting: Bool) {
        let finished = phase
        pause()

        if finished == .focus, counting {
            let k = Self.key(Date())
            var stat = days[k] ?? DayStat()
            stat.sessions += 1
            days[k] = stat

            if let id = activeTaskID, let idx = tasks.firstIndex(where: { $0.id == id }) {
                tasks[idx].completed += 1
            }
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
        remaining = settings.length(for: next)
        save()

        let shouldAutoStart = next.isBreak ? settings.autoStartBreaks : settings.autoStartFocus
        if counting, shouldAutoStart { start() }
    }

    // MARK: Tasks

    @discardableResult
    func addTask(_ title: String, note: String = "", estimate: Int = 1) -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        tasks.append(TodoItem(title: trimmed, note: note, estimate: max(1, estimate)))
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
        if settings.playSound { NSSound(named: "Glass")?.play() }
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
        tasks = AppStore.starterTasks
        days = [:]
        cyclePosition = 0
        phase = .focus
        activeTaskID = tasks.first?.id
        remaining = phaseLength
        flash("Everything reset")
        save()
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
        Persistence.save(PersistedState(settings: settings,
                                        tasks: tasks,
                                        days: days,
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
    var days: [String: DayStat]
    var phase: Phase
    var cyclePosition: Int
    var remaining: TimeInterval
    var activeTaskID: UUID?
}

enum Persistence {
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

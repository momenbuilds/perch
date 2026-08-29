import Foundation

/// Headless checks for the engine, run with `Perch --selftest`.
///
/// Everything here uses an in-memory store, so running it never touches the JSON on
/// disk. It exists because the interesting behaviour — cycle transitions, group
/// bookkeeping, sorting — is tedious and unreliable to verify by clicking.
@MainActor
enum SelfTest {

    private static var passed = 0
    private static var failed: [String] = []

    private static func check(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed.append(name)
            print("  ✗ \(name)")
        }
    }

    private static func section(_ title: String) {
        print("\n\(title)")
    }

    static func run() -> Int32 {
        setvbuf(stdout, nil, _IONBF, 0)
        tasks()
        groups()
        sortingAndSearch()
        pomodoroCycle()
        statistics()
        persistence()
        formatting()
        systemMetrics()

        print("\n\(passed) passed, \(failed.count) failed")
        for name in failed { print("  failed: \(name)") }
        return failed.isEmpty ? 0 : 1
    }

    // MARK: Tasks

    private static func tasks() {
        section("Tasks")
        let store = AppStore(persists: false)

        for index in 1...10 {
            store.addTask("Task \(index)", estimate: index % 4 + 1)
        }
        check("ten tasks added", store.tasks.count == 10)
        check("empty titles rejected", store.addTask("   ") == false)
        check("estimate stored", store.tasks[0].estimate == 2)

        let first = store.tasks[0].id
        store.rename(first, to: "Renamed")
        check("rename", store.tasks[0].title == "Renamed")

        store.setNote(first, "  a note  ")
        check("note trimmed", store.tasks[0].note == "a note")

        store.setEstimate(first, 99)
        check("estimate clamped to 12", store.tasks[0].estimate == 12)
        store.setEstimate(first, -3)
        check("estimate floors at 1", store.tasks[0].estimate == 1)

        store.toggleDone(first)
        check("marked done", store.tasks[0].isDone)
        check("done count", store.doneCount == 1)
        store.toggleDone(first)
        check("unmarked", store.tasks[0].isDone == false)

        store.delete(first)
        check("deleted", store.tasks.count == 9)

        store.toggleDone(store.tasks[0].id)
        store.toggleDone(store.tasks[1].id)
        store.clearCompleted()
        check("clear completed", store.tasks.count == 7)

        let moving = store.tasks[6].id
        store.move(moving, before: store.tasks[0].id)
        check("reorder to front", store.tasks[0].id == moving)
    }

    // MARK: Groups

    private static func groups() {
        section("Groups")
        let store = AppStore(persists: false)

        let work = store.addGroup("Work")
        let study = store.addGroup("Study")
        check("two groups", store.groups.count == 2)
        check("blank group rejected", store.addGroup("  ") == nil)
        check("distinct colours", store.groups[0].colorIndex != store.groups[1].colorIndex)

        store.addTask("Client deck")
        store.addTask("Read chapter 4")
        store.addTask("Loose end")
        let deck = store.tasks[0].id
        let chapter = store.tasks[1].id

        store.assign(deck, to: work?.id)
        store.assign(chapter, to: study?.id)
        check("assigned to Work", store.tasks(in: work).count == 1)
        check("assigned to Study", store.tasks(in: study).count == 1)
        check("one left in Inbox", store.tasks(in: nil).count == 1)

        store.renameGroup(work!.id, to: "Client work")
        check("group renamed", store.groups[0].name == "Client work")

        let before = store.groups[0].colorIndex
        store.cycleGroupColor(work!.id)
        check("colour cycles", store.groups[0].colorIndex != before)

        store.toggleGroup(work!.id)
        check("group collapses", store.groups[0].isCollapsed)
        store.toggleGroup(work!.id)
        check("group expands", store.groups[0].isCollapsed == false)

        store.deleteGroup(work!.id)
        check("group deleted", store.groups.count == 1)
        check("its tasks fell back to Inbox", store.tasks(in: nil).count == 2)
        check("no task points at a dead group",
              store.tasks.allSatisfy { $0.groupID == nil || $0.groupID == study?.id })
    }

    // MARK: Sorting and search

    private static func sortingAndSearch() {
        section("Sorting and search")
        let store = AppStore(persists: false)
        store.addTask("Alpha")
        store.addTask("Beta")
        store.addTask("Gamma")

        let gamma = store.tasks[2].id
        store.togglePriority(gamma)
        check("priority floats to the top", store.tasks(in: nil).first?.id == gamma)

        store.toggleDone(store.tasks[0].id)
        check("done sinks to the bottom", store.tasks(in: nil).last?.title == "Alpha")

        store.search = "bet"
        check("search matches title", store.tasks(in: nil).count == 1)
        store.search = "nothing here"
        check("search can match nothing", store.tasks(in: nil).isEmpty)
        store.search = ""
        check("clearing search restores", store.tasks(in: nil).count == 3)

        store.setNote(store.tasks[1].id, "invoice attached")
        store.search = "invoice"
        check("search matches notes", store.tasks(in: nil).count == 1)
    }

    // MARK: Pomodoro

    private static func pomodoroCycle() {
        section("Pomodoro cycle")
        let store = AppStore(persists: false)
        store.settings.sessionsPerCycle = 4
        store.addTask("Deep work", estimate: 4)
        let task = store.tasks[0].id
        store.select(task)

        check("starts on focus", store.phase == .focus)
        check("full length remaining", store.remaining == store.phaseLength)

        store.start()
        check("running", store.isRunning)
        store.pause()
        check("paused", store.isRunning == false)

        store.remaining = 10
        store.reset()
        check("reset restores the phase length", store.remaining == store.phaseLength)

        // Three focus sessions should each land a short break.
        for index in 1...3 {
            store.advance(counting: true)
            check("focus \(index) → short break", store.phase == .shortBreak)
            check("session \(index) banked", store.today.sessions == index)
            store.advance(counting: true)
            check("break \(index) → focus", store.phase == .focus)
        }

        check("task credited three pomodoros", store.tasks[0].completed == 3)

        // The fourth completes the cycle, so the long break is due.
        store.advance(counting: true)
        check("fourth focus → long break", store.phase == .longBreak)
        check("long break length",
              store.remaining == TimeInterval(store.settings.longBreakMinutes * 60))
        check("cycle position wrapped", store.cyclePosition % 4 == 0)

        store.advance(counting: true)
        check("long break → focus", store.phase == .focus)
        check("four sessions logged", store.log.count == 4)

        store.switchTo(.longBreak)
        check("manual switch to long break", store.phase == .longBreak)
        check("manual switch is paused", store.isRunning == false)

        store.switchTo(.focus)
        store.skip()
        check("skip leaves focus", store.phase != .focus)
        check("skip does not bank a session", store.today.sessions == 4)

        // A running session should survive being pointed at a different task.
        store.switchTo(.focus)
        store.addTask("Other")
        let other = store.tasks[1].id
        store.toggle(task: other)
        check("switching task starts it", store.isRunning)
        check("active task followed", store.activeTaskID == other)
        store.toggle(task: other)
        check("second tap pauses", store.isRunning == false)

        // Completing the active task must not leave the timer running on nothing.
        store.start()
        store.toggleDone(other)
        check("finishing the active task pauses", store.isRunning == false)
    }

    // MARK: Statistics

    private static func statistics() {
        section("Statistics")
        let store = AppStore(persists: false)
        store.settings.dailyGoal = 4
        store.addTask("Thing")

        check("no streak on a blank install", store.currentStreak == 0)
        check("no sessions", store.totalSessions == 0)
        check("goal starts empty", store.goalProgress == 0)

        for _ in 1...2 {
            store.advance(counting: true)   // focus → break
            store.advance(counting: true)   // break → focus
        }
        check("two sessions today", store.today.sessions == 2)
        check("goal half met", abs(store.goalProgress - 0.5) < 0.001)
        check("streak counts today", store.currentStreak == 1)
        check("best streak at least current", store.bestStreak >= store.currentStreak)
        check("log lists today", store.todaysLog.count == 2)
        check("hour histogram has 24 buckets", store.hourHistogram.count == 24)
        check("histogram totals the log",
              store.hourHistogram.reduce(0, +) == store.log.count)
        check("last 30 days", store.recent(days: 30).count == 30)
        check("goal cannot exceed 1", store.goalProgress <= 1)

        store.settings.dailyGoal = 1
        check("goal clamps at 1", store.goalProgress == 1)

        store.clearAllData()
        check("clear wipes tasks", store.tasks.isEmpty)
        check("clear wipes history", store.totalSessions == 0)
        check("clear wipes the log", store.log.isEmpty)
        check("clear wipes groups", store.groups.isEmpty)
    }

    // MARK: Persistence

    private static func persistence() {
        section("Persistence")
        let store = AppStore(persists: false)
        let group = store.addGroup("Roundtrip")
        store.addTask("Encoded", note: "with a note", estimate: 3, groupID: group?.id)
        store.togglePriority(store.tasks[0].id)
        store.advance(counting: true)

        let state = PersistedState(settings: store.settings,
                                   tasks: store.tasks,
                                   groups: store.groups,
                                   days: store.days,
                                   log: store.log,
                                   phase: store.phase,
                                   cyclePosition: store.cyclePosition,
                                   remaining: store.remaining,
                                   activeTaskID: store.activeTaskID)

        guard let data = try? JSONEncoder().encode(state) else {
            check("state encodes", false)
            return
        }
        check("state encodes", true)

        guard let decoded = try? JSONDecoder().decode(PersistedState.self, from: data) else {
            check("state decodes", false)
            return
        }
        check("state decodes", true)
        check("tasks survive", decoded.tasks.count == 1)
        check("note survives", decoded.tasks[0].note == "with a note")
        check("priority survives", decoded.tasks[0].isPriority)
        check("group link survives", decoded.tasks[0].groupID == group?.id)
        check("groups survive", decoded.groups?.count == 1)
        check("history survives", decoded.days.isEmpty == false)
        check("log survives", decoded.log?.count == 1)
        check("settings survive", decoded.settings == store.settings)

        // A file written by an older build has no groups or log at all.
        var legacy = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        legacy.removeValue(forKey: "groups")
        legacy.removeValue(forKey: "log")
        let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
        let migrated = try? JSONDecoder().decode(PersistedState.self, from: legacyData)
        check("older files still load", migrated != nil)
        check("missing groups become nil", migrated?.groups == nil)
    }

    // MARK: Formatting

    private static func formatting() {
        section("Formatting")
        check("bytes in B", SystemMonitor.bytes(512) == "512 B")
        check("bytes in KB", SystemMonitor.bytes(2048) == "2.0 KB")
        check("bytes in GB", SystemMonitor.bytes(3 * 1_073_741_824) == "3.0 GB")
        check("rate suffix", SystemMonitor.rate(1024).hasSuffix("/s"))
        check("minutes", SystemMonitor.duration(90 * 60) == "1h 30m")
        check("days", SystemMonitor.duration(3 * 86_400 + 3600) == "3d 1h")

        let store = AppStore(persists: false)
        store.remaining = 125
        check("clock formatting", store.clockText == "02:05")
        store.remaining = 0
        check("clock at zero", store.clockText == "00:00")

        check("phase titles", Phase.allCases.map(\.title).count == 3)
        check("chime maps to a system sound", ChimeSound.glass.systemName == "Glass")
        check("chime off is silent", ChimeSound.none.systemName == nil)
        check("accent index clamps", Theme.accent(99) == Theme.accents.last)
        check("group colour clamps", Theme.groupColor(-5) == Theme.groupPalette.first)
    }

    // MARK: System metrics

    private static func systemMetrics() {
        section("System metrics")
        let monitor = SystemMonitor()
        monitor.sample()
        Thread.sleep(forTimeInterval: 0.4)
        monitor.sample()

        check("cpu in range", monitor.cpu.value >= 0 && monitor.cpu.value <= 1)
        check("memory in range", monitor.memory.value > 0 && monitor.memory.value <= 1)
        check("memory total read", monitor.memoryTotalBytes > 0)
        check("memory used below total", monitor.memoryUsedBytes < monitor.memoryTotalBytes)
        check("disk read", monitor.diskTotalBytes > 0)
        check("disk used below total", monitor.diskUsedBytes <= monitor.diskTotalBytes)
        check("uptime positive", monitor.uptime > 0)
        check("load average non-negative", monitor.loadAverage >= 0)
        check("history recorded", monitor.cpu.history.count >= 1)

        monitor.subscribeProcesses()
        Thread.sleep(forTimeInterval: 0.5)
        monitor.sample()
        check("processes sampled", monitor.processes.isEmpty == false)
        check("process names present", monitor.processes.allSatisfy { !$0.name.isEmpty })
        check("top by cpu is sorted",
              zip(monitor.topProcesses(by: .cpu), monitor.topProcesses(by: .cpu).dropFirst())
                  .allSatisfy { $0.cpu >= $1.cpu })
        check("top by memory is sorted",
              zip(monitor.topProcesses(by: .memory), monitor.topProcesses(by: .memory).dropFirst())
                  .allSatisfy { $0.memory >= $1.memory })
        check("limit respected", monitor.topProcesses(by: .cpu, limit: 3).count <= 3)
        monitor.unsubscribeProcesses()
        check("unsubscribing clears the list", monitor.processes.isEmpty)
    }
}

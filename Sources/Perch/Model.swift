import SwiftUI

// MARK: - Pomodoro phases

enum Phase: String, Codable, CaseIterable, Identifiable {
    case focus, shortBreak, longBreak

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus:      return "Focus"
        case .shortBreak: return "Short Break"
        case .longBreak:  return "Long Break"
        }
    }

    var shortTitle: String {
        switch self {
        case .focus:      return "Focus"
        case .shortBreak: return "Break"
        case .longBreak:  return "Long"
        }
    }

    var symbol: String {
        switch self {
        case .focus:      return "timer"
        case .shortBreak: return "cup.and.saucer.fill"
        case .longBreak:  return "moon.stars.fill"
        }
    }

    var isBreak: Bool { self != .focus }
}

// MARK: - Tasks

/// A named bucket of tasks — "Client work", "Study", whatever the user needs. Groups can
/// be collapsed so the list stays short while you are heads-down on one of them.
struct TaskGroup: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var name: String
    var colorIndex: Int = 0
    var isCollapsed: Bool = false
    var createdAt: Date = Date()
}

struct TodoItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var note: String = ""
    var isDone: Bool = false
    /// Pomodoros the user expects this to take.
    var estimate: Int = 1
    /// Pomodoros actually completed against it.
    var completed: Int = 0
    /// nil means the task sits outside any group.
    var groupID: UUID?
    var isPriority: Bool = false
    var createdAt: Date = Date()
    var completedAt: Date?

    var progress: Double {
        guard estimate > 0 else { return 0 }
        return min(Double(completed) / Double(estimate), 1)
    }
}

// MARK: - Daily rollup

struct DayStat: Codable, Equatable {
    var sessions: Int = 0
    var focusSeconds: Int = 0

    var minutes: Int { focusSeconds / 60 }
}

/// One finished focus session, kept so the day can be replayed in Statistics.
struct SessionRecord: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var finishedAt: Date
    var taskTitle: String
    var minutes: Int
}

// MARK: - Chime

enum ChimeSound: String, Codable, CaseIterable, Identifiable {
    case glass, ping, submarine, none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .glass:     return "Glass"
        case .ping:      return "Ping"
        case .submarine: return "Sub"
        case .none:      return "Off"
        }
    }

    /// Name of the system sound to play, or nil for silence.
    var systemName: String? {
        switch self {
        case .glass:     return "Glass"
        case .ping:      return "Ping"
        case .submarine: return "Submarine"
        case .none:      return nil
        }
    }
}

// MARK: - Placement

/// Where along the top edge the island hangs.
enum IslandAlignment: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leading:  return "Left"
        case .center:   return "Centre"
        case .trailing: return "Right"
        }
    }
}

// MARK: - Settings

struct Settings: Codable, Equatable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    /// Focus sessions between long breaks.
    var sessionsPerCycle: Int = 4
    /// Focus sessions you are aiming for each day.
    var dailyGoal: Int = 8

    var autoStartBreaks: Bool = true
    var autoStartFocus: Bool = false
    var chime: ChimeSound = .glass
    var showNotifications: Bool = true
    var launchAtLogin: Bool = false
    /// Collapse the island back to the pill when a session starts.
    var collapseOnStart: Bool = true
    /// Show live CPU load in the menu bar when no session is running.
    var showLoadInMenuBar: Bool = false
    /// The island is tucked away; the menu-bar item brings it back.
    var isIslandHidden: Bool = false

    /// Index into `Theme.accents` — the colour used for focus sessions.
    var accentIndex: Int = 0
    var alignment: IslandAlignment = .center

    func length(for phase: Phase) -> TimeInterval {
        switch phase {
        case .focus:      return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak:  return TimeInterval(longBreakMinutes * 60)
        }
    }
}

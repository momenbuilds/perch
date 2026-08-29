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

    var accent: Color {
        switch self {
        case .focus:      return Theme.focusAccent
        case .shortBreak: return Theme.shortAccent
        case .longBreak:  return Theme.longAccent
        }
    }

    var isBreak: Bool { self != .focus }
}

// MARK: - Tasks

struct TodoItem: Identifiable, Codable, Equatable {
    var id: UUID = UUID()
    var title: String
    var note: String = ""
    var isDone: Bool = false
    /// Pomodoros the user expects this to take.
    var estimate: Int = 1
    /// Pomodoros actually completed against it.
    var completed: Int = 0
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

// MARK: - Settings

struct Settings: Codable, Equatable {
    var focusMinutes: Int = 25
    var shortBreakMinutes: Int = 5
    var longBreakMinutes: Int = 15
    /// Focus sessions between long breaks.
    var sessionsPerCycle: Int = 4

    var autoStartBreaks: Bool = true
    var autoStartFocus: Bool = false
    var playSound: Bool = true
    var showNotifications: Bool = true
    var launchAtLogin: Bool = false
    /// Collapse the island back to the pill when a session starts.
    var collapseOnStart: Bool = true

    func length(for phase: Phase) -> TimeInterval {
        switch phase {
        case .focus:      return TimeInterval(focusMinutes * 60)
        case .shortBreak: return TimeInterval(shortBreakMinutes * 60)
        case .longBreak:  return TimeInterval(longBreakMinutes * 60)
        }
    }
}

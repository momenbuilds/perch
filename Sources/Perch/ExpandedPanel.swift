import SwiftUI

/// The open panel: tasks on the left, the Pomodoro transport and a switchable card
/// (streak / stats / settings) on the right.
struct ExpandedPanel: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: UIState
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            TasksCard(store: store, ui: ui)
                .frame(width: 444)

            VStack(spacing: 12) {
                TimerCard(store: store, ui: ui)
                    .frame(height: 132)

                PanelCard(store: store, ui: ui, monitor: monitor)
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                Text(toast)
                    .font(Theme.ui(11.5, .semibold))
                    .foregroundStyle(Theme.text1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.85), in: Capsule())
                    .overlay(Capsule().strokeBorder(store.accent.opacity(0.5), lineWidth: 1))
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 2)
            }
        }
    }
}

/// The lower right card. Its header carries the tab strip, so the three panes below
/// stay pure content.
private struct PanelCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: UIState
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: ui.tab.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(headerTint)
                Text(ui.tab.title)
                    .font(Theme.ui(13, .semibold))
                    .foregroundStyle(Theme.text1)
                Spacer(minLength: 6)
                accessory
                TabStrip(selection: $ui.tab, accent: store.accent)
            }

            switch ui.tab {
            case .streak:   StreakCard(store: store)
            case .stats:    StatsCard(store: store)
            case .system:   SystemCard(monitor: monitor)
            case .settings: SettingsCard(store: store)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(12)
        .card()
    }

    private var headerTint: Color {
        switch ui.tab {
        case .streak:   return Theme.gold
        case .stats:    return Theme.focusAccent
        case .system:   return Theme.shortAccent
        case .settings: return Theme.text2
        }
    }

    @ViewBuilder
    private var accessory: some View {
        switch ui.tab {
        case .streak:
            HStack(spacing: 4) {
                Text("\(store.currentStreak)d")
                    .font(Theme.mono(12.5, .bold))
                    .foregroundStyle(Theme.gold)
                Text("streak")
                    .font(Theme.ui(10.5))
                    .foregroundStyle(Theme.text3)
            }
        case .stats:
            Text("\(store.totalFocusMinutes / 60)h total")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.text3)
        case .system:
            Text("live")
                .font(Theme.ui(10.5))
                .foregroundStyle(Theme.text3)
        case .settings:
            Button("Reset all") { store.clearAllData() }
                .buttonStyle(.plain)
                .font(Theme.ui(10.5, .semibold))
                .foregroundStyle(Theme.danger)
        }
    }
}

// MARK: - Timer

private struct TimerCard: View {
    @ObservedObject var store: AppStore
    @ObservedObject var ui: UIState

    private var phaseBinding: Binding<Phase> {
        Binding(get: { store.phase },
                set: { store.switchTo($0, autoStart: false) })
    }

    private var sessionLabel: String {
        let per = max(store.settings.sessionsPerCycle, 1)
        return "Session \(store.cyclePosition % per + 1) of \(per)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                SegmentedPills(items: Phase.allCases,
                               selection: phaseBinding,
                               label: { $0.shortTitle },
                               accent: store.accent)
                Spacer(minLength: 4)
                IconButton(symbol: ui.isPinned
                           ? "arrow.down.right.and.arrow.up.left"
                           : "arrow.up.left.and.arrow.down.right",
                           size: 22, glyph: 9.5,
                           help: ui.isPinned ? "Unpin" : "Keep open") {
                    withAnimation(Theme.openSpring) { ui.togglePin() }
                }
            }

            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(store.clockText)
                        .font(Theme.mono(40, .bold))
                        .foregroundStyle(Theme.text1)
                        .contentTransition(.identity)
                    Text("\(store.phase.title) · \(sessionLabel)")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text2)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                HStack(spacing: 9) {
                    IconButton(symbol: "arrow.counterclockwise", size: 30, glyph: 12,
                               help: "Reset this phase") { store.reset() }
                    PlayButton(isRunning: store.isRunning, accent: store.accent) {
                        store.toggle()
                    }
                    IconButton(symbol: "forward.end.fill", size: 30, glyph: 11,
                               help: "Skip to next phase") { store.skip() }
                }
            }
        }
        .padding(14)
        .card()
        .animation(Theme.contentSpring, value: store.phase)
    }
}

// MARK: - Streak

private struct StreakCard: View {
    @ObservedObject var store: AppStore

    private let columns = 10
    private let rows = 3
    private let cell: CGFloat = 30
    private let gap: CGFloat = 7

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            grid

            if store.totalSessions == 0 {
                Text("Finish a focus session and today lights up.")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.text3)
            }

            MeterRow(symbol: "target",
                     label: "Goal",
                     detail: "\(store.today.sessions) / \(store.settings.dailyGoal) today",
                     fraction: store.goalProgress,
                     tint: store.goalProgress >= 1 ? Theme.shortAccent : Theme.focusAccent)

            MeterRow(symbol: "moon.stars.fill",
                     label: "Cycle",
                     detail: "\(store.cyclePosition % max(store.settings.sessionsPerCycle, 1)) / \(store.settings.sessionsPerCycle) to long break",
                     fraction: Double(store.cyclePosition % max(store.settings.sessionsPerCycle, 1))
                        / Double(max(store.settings.sessionsPerCycle, 1)),
                     tint: Theme.longAccent)

            MeterRow(symbol: "flame.fill",
                     label: "Streak",
                     detail: "\(store.currentStreak)d now · best \(store.bestStreak)d",
                     fraction: store.bestStreak > 0
                        ? Double(store.currentStreak) / Double(store.bestStreak) : 0,
                     tint: Theme.gold)

            Spacer(minLength: 0)

            HStack(spacing: 6) {
                Text("Today")
                    .font(Theme.ui(10, .semibold))
                    .foregroundStyle(Theme.text3)
                Text("\(store.today.sessions) session\(store.today.sessions == 1 ? "" : "s")")
                    .font(Theme.mono(10.5, .bold))
                    .foregroundStyle(Theme.focusAccent)
                Text("·")
                    .foregroundStyle(Theme.text3)
                Text("\(store.today.minutes)m focused")
                    .font(Theme.mono(10.5, .bold))
                    .foregroundStyle(Theme.shortAccent)
                Spacer()
                Text("Best \(store.bestStreak)d")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.text3)
            }

            HStack {
                Text("Last 30 days")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.text3)
                Spacer()
                Text("Less")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.text3)
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Theme.heat(level, accent: store.accent))
                        .frame(width: 9, height: 9)
                }
                Text("More")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.text3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var grid: some View {
        let history = store.recent(days: rows * columns)
        return VStack(spacing: gap) {
            ForEach(0..<rows, id: \.self) { row in
                HStack(spacing: gap) {
                    ForEach(0..<columns, id: \.self) { col in
                        let entry = history[row * columns + col]
                        StreakCell(date: entry.date, stat: entry.stat,
                                   isToday: Calendar.current.isDateInToday(entry.date),
                                   size: cell, accent: store.accent)
                    }
                }
            }
        }
    }
}

private struct StreakCell: View {
    let date: Date
    let stat: DayStat
    let isToday: Bool
    let size: CGFloat
    let accent: Color

    @State private var hovering = false

    private var label: String {
        let f = DateFormatter()
        f.dateFormat = "EEE d MMM"
        let n = stat.sessions
        return "\(f.string(from: date)) · \(n) session\(n == 1 ? "" : "s")"
    }

    var body: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(Theme.heat(stat.sessions, accent: accent))
            .frame(width: size, height: size)
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(isToday ? Color.white.opacity(0.55) : .clear, lineWidth: 1.5)
            )
            .scaleEffect(hovering ? 1.14 : 1)
            .animation(Theme.snappy, value: hovering)
            .onHover { hovering = $0 }
            .help(label)
    }
}

// MARK: - Stats

struct StatsCard: View {
    @ObservedObject var store: AppStore

    private func hm(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes)m"
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                StatTile(value: "\(store.today.sessions)", caption: "Today",
                         symbol: "target", tint: Theme.focusAccent)
                StatTile(value: hm(store.today.minutes), caption: "Focused",
                         symbol: "hourglass", tint: Theme.shortAccent)
            }
            HStack(spacing: 8) {
                StatTile(value: "\(store.currentStreak)d", caption: "Streak",
                         symbol: "flame.fill", tint: Theme.gold)
                StatTile(value: "\(store.totalSessions)", caption: "Sessions",
                         symbol: "checkmark.seal.fill", tint: Theme.longAccent)
            }

            Text("LAST 7 DAYS")
                .font(Theme.ui(9, .bold))
                .kerning(0.7)
                .foregroundStyle(Theme.text3)
            WeekChart(store: store)

            if store.hourHistogram.contains(where: { $0 > 0 }) {
                Text("WHEN YOU FOCUS")
                    .font(Theme.ui(9, .bold))
                    .kerning(0.7)
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 2)
                HourChart(store: store)
            }

            if !store.todaysLog.isEmpty {
                Text("TODAY'S SESSIONS")
                    .font(Theme.ui(9, .bold))
                    .kerning(0.7)
                    .foregroundStyle(Theme.text3)
                    .padding(.top, 2)

                VStack(spacing: 4) {
                    ForEach(store.todaysLog) { record in
                            HStack(spacing: 8) {
                                Text(Self.clock(record.finishedAt))
                                    .font(Theme.mono(10, .semibold))
                                    .foregroundStyle(Theme.focusAccent)
                                Text(record.taskTitle)
                                    .font(Theme.ui(11))
                                    .foregroundStyle(Theme.text2)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text("\(record.minutes)m")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.text3)
                            }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.row,
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
    }
}

extension StatsCard {
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}

/// Sessions by hour of day, across everything logged so far.
private struct HourChart: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let counts = store.hourHistogram
        let peak = max(counts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(0..<24, id: \.self) { hour in
                VStack(spacing: 3) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(counts[hour] > 0
                              ? store.accent.opacity(0.4 + 0.6 * Double(counts[hour]) / Double(peak))
                              : Theme.emptyCell)
                        .frame(height: max(3, 26 * CGFloat(counts[hour]) / CGFloat(peak)))
                    if hour % 6 == 0 {
                        Text("\(hour)")
                            .font(Theme.ui(7.5, .semibold))
                            .foregroundStyle(Theme.text3)
                    } else {
                        Spacer().frame(height: 9)
                    }
                }
                .frame(maxWidth: .infinity)
                .help("\(counts[hour]) session\(counts[hour] == 1 ? "" : "s") at \(hour):00")
            }
        }
        .frame(height: 40, alignment: .bottom)
    }
}

private struct WeekChart: View {
    @ObservedObject var store: AppStore

    var body: some View {
        let week = store.recent(days: 7)
        let peak = max(week.map(\.stat.sessions).max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 6) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(entry.stat.sessions > 0
                              ? store.accent.opacity(0.35 + 0.65 * Double(entry.stat.sessions) / Double(peak))
                              : Theme.emptyCell)
                        .frame(height: max(4, 30 * CGFloat(entry.stat.sessions) / CGFloat(peak)))
                    Text(Self.letter(entry.date))
                        .font(Theme.ui(8.5, .semibold))
                        .foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity)
                .help("\(entry.stat.sessions) session\(entry.stat.sessions == 1 ? "" : "s")")
            }
        }
        .frame(height: 44, alignment: .bottom)
    }

    private static func letter(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEEE"
        return f.string(from: date)
    }
}

// MARK: - Settings

private struct SettingsCard: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    StepperRow(label: "Focus", value: $store.settings.focusMinutes,
                               range: 5...90, step: 5, unit: "min", accent: Theme.focusAccent)
                    StepperRow(label: "Short break", value: $store.settings.shortBreakMinutes,
                               range: 1...30, step: 1, unit: "min", accent: Theme.shortAccent)
                    StepperRow(label: "Long break", value: $store.settings.longBreakMinutes,
                               range: 5...60, step: 5, unit: "min", accent: Theme.longAccent)
                    StepperRow(label: "Sessions per cycle", value: $store.settings.sessionsPerCycle,
                               range: 2...8, step: 1, unit: "", accent: Theme.gold)
                    StepperRow(label: "Daily goal", value: $store.settings.dailyGoal,
                               range: 1...24, step: 1, unit: "", accent: Theme.shortAccent)

                    HStack(spacing: 8) {
                        Text("Chime")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.text2)
                        Spacer(minLength: 6)
                        SegmentedPills(items: ChimeSound.allCases,
                                       selection: $store.settings.chime,
                                       label: { $0.title },
                                       accent: store.accent)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    ToggleRow(label: "Auto-start breaks", isOn: $store.settings.autoStartBreaks)
                    ToggleRow(label: "Auto-start next focus", isOn: $store.settings.autoStartFocus)
                    ToggleRow(label: "Collapse when a session starts", isOn: $store.settings.collapseOnStart)
                    ToggleRow(label: "Notifications", isOn: $store.settings.showNotifications)
                    ToggleRow(label: "CPU load in the menu bar", isOn: $store.settings.showLoadInMenuBar)
                    ToggleRow(label: "Hide the island (menu bar only)",
                              isOn: $store.settings.isIslandHidden)
                    ToggleRow(label: "Open at login", isOn: $store.settings.launchAtLogin)

                    HStack(spacing: 8) {
                        Text("Accent")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.text2)
                        Spacer(minLength: 6)
                        HStack(spacing: 6) {
                            ForEach(Array(Theme.accents.enumerated()), id: \.offset) { index, colour in
                                Button {
                                    withAnimation(Theme.snappy) { store.settings.accentIndex = index }
                                } label: {
                                    Circle()
                                        .fill(colour)
                                        .frame(width: 14, height: 14)
                                        .overlay(
                                            Circle()
                                                .strokeBorder(.white.opacity(
                                                    store.settings.accentIndex == index ? 0.9 : 0),
                                                              lineWidth: 2)
                                                .padding(-3)
                                        )
                                }
                                .buttonStyle(.plain)
                                .help(Theme.accentNames[index])
                            }
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))

                    HStack(spacing: 8) {
                        Text("Position")
                            .font(Theme.ui(11.5))
                            .foregroundStyle(Theme.text2)
                        Spacer(minLength: 6)
                        SegmentedPills(items: IslandAlignment.allCases,
                                       selection: $store.settings.alignment,
                                       label: { $0.title },
                                       accent: store.accent)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Theme.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
                .padding(.bottom, 2)
            }
            .mask(
                LinearGradient(stops: [.init(color: .black, location: 0),
                                       .init(color: .black, location: 0.86),
                                       .init(color: .black.opacity(0), location: 1)],
                               startPoint: .top, endPoint: .bottom)
            )
        }
    }
}

private struct StepperRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let unit: String
    let accent: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 6)
            HStack(spacing: 6) {
                IconButton(symbol: "minus", size: 19, glyph: 8) {
                    value = max(range.lowerBound, value - step)
                }
                Text(unit.isEmpty ? "\(value)" : "\(value)\(unit)")
                    .font(Theme.mono(11.5, .bold))
                    .foregroundStyle(accent)
                    .frame(width: 42)
                IconButton(symbol: "plus", size: 19, glyph: 8) {
                    value = min(range.upperBound, value + step)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

private struct ToggleRow: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.ui(11.5))
                .foregroundStyle(Theme.text2)
            Spacer(minLength: 6)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}

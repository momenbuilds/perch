import SwiftUI

/// Live machine load. The gauges are buttons: tapping one drills into the processes
/// responsible for it, which is the question you actually have when a number is high.
struct SystemCard: View {
    @ObservedObject var monitor: SystemMonitor

    @State private var drilldown: ProcessSort?

    var body: some View {
        Group {
            if let sort = drilldown {
                explorer(sort)
            } else {
                overview
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { monitor.subscribe() }
        .onDisappear {
            monitor.unsubscribe()
            if drilldown != nil { monitor.unsubscribeProcesses() }
        }
    }

    // MARK: Overview

    private var overview: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                gaugeColumn(value: monitor.cpu.value,
                            history: monitor.cpu.history,
                            caption: "CPU",
                            detail: String(format: "load %.2f", monitor.loadAverage),
                            tint: Theme.focusAccent,
                            sort: .cpu)

                gaugeColumn(value: monitor.memory.value,
                            history: monitor.memory.history,
                            caption: "Memory",
                            detail: "\(SystemMonitor.bytes(Double(monitor.memoryUsedBytes))) / \(SystemMonitor.bytes(Double(monitor.memoryTotalBytes)))",
                            tint: Theme.longAccent,
                            sort: .memory)

                gaugeColumn(value: monitor.gpu.value,
                            history: monitor.gpu.history,
                            caption: "GPU",
                            detail: monitor.gpuAvailable ? "accelerator" : "unavailable",
                            tint: Theme.shortAccent,
                            sort: nil)
            }

            Divider().overlay(Theme.cardStroke)

            VStack(spacing: 6) {
                Button { open(.disk) } label: {
                    MeterRow(symbol: "internaldrive.fill",
                             label: "Disk",
                             detail: "\(SystemMonitor.bytes(Double(monitor.diskTotalBytes - monitor.diskUsedBytes))) free",
                             fraction: monitor.disk.value,
                             tint: Theme.gold)
                }
                .buttonStyle(.plain)
                .help("Show what is reading and writing")

                MeterRow(symbol: "arrow.down.arrow.up",
                         label: "Network",
                         detail: "↓\(SystemMonitor.rate(monitor.networkDown))  ↑\(SystemMonitor.rate(monitor.networkUp))",
                         fraction: nil,
                         tint: Theme.focusAccent)

                if let level = monitor.batteryLevel {
                    MeterRow(symbol: monitor.batteryCharging ? "battery.100.bolt" : "battery.50",
                             label: "Battery",
                             detail: batteryDetail(level),
                             fraction: level,
                             tint: level < 0.2 ? Theme.danger : Theme.shortAccent)
                } else {
                    MeterRow(symbol: "powerplug.fill",
                             label: "Power",
                             detail: "AC power",
                             fraction: nil,
                             tint: Theme.shortAccent)
                }

                MeterRow(symbol: "clock.arrow.circlepath",
                         label: "Uptime",
                         detail: SystemMonitor.duration(monitor.uptime),
                         fraction: nil,
                         tint: Theme.text2)
            }
        }
    }

    // MARK: Process explorer

    private func explorer(_ sort: ProcessSort) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                IconButton(symbol: "chevron.left", size: 22, glyph: 9.5,
                           help: "Back to overview") { close() }

                Text("Top by")
                    .font(Theme.ui(11))
                    .foregroundStyle(Theme.text3)

                SegmentedPills(items: ProcessSort.allCases,
                               selection: Binding(get: { sort },
                                                  set: { drilldown = $0 }),
                               label: { $0.title },
                               accent: tint(for: sort))

                Spacer(minLength: 0)

                Text("\(monitor.processes.count) running")
                    .font(Theme.ui(10))
                    .foregroundStyle(Theme.text3)
            }

            let rows = monitor.topProcesses(by: sort)
            if rows.isEmpty {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Measuring…")
                        .font(Theme.ui(11))
                        .foregroundStyle(Theme.text3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Bars are scaled against the busiest row so the list is readable; the
                // number beside each one is still the absolute truth.
                let peak = rows.map { value(of: $0, by: sort) }.max() ?? 1
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(rows) { row in
                            ProcessRow(sample: row, sort: sort, tint: tint(for: sort),
                                       peak: peak)
                        }
                    }
                }
            }
        }
    }

    private func value(of sample: ProcessSample, by sort: ProcessSort) -> Double {
        switch sort {
        case .cpu:    return sample.cpu
        case .memory: return Double(sample.memory)
        case .disk:   return sample.diskRate
        }
    }

    private func tint(for sort: ProcessSort) -> Color {
        switch sort {
        case .cpu:    return Theme.focusAccent
        case .memory: return Theme.longAccent
        case .disk:   return Theme.gold
        }
    }

    private func open(_ sort: ProcessSort) {
        guard drilldown == nil else { drilldown = sort; return }
        monitor.subscribeProcesses()
        withAnimation(Theme.contentSpring) { drilldown = sort }
    }

    private func close() {
        monitor.unsubscribeProcesses()
        withAnimation(Theme.contentSpring) { drilldown = nil }
    }

    private func batteryDetail(_ level: Double) -> String {
        let percent = "\(Int((level * 100).rounded()))%"
        if monitor.batteryCharging { return percent + " charging" }
        if let minutes = monitor.batteryMinutesLeft {
            return percent + " · \(minutes / 60)h \(minutes % 60)m"
        }
        return percent
    }

    private func gaugeColumn(value: Double, history: [Double], caption: String,
                             detail: String, tint: Color, sort: ProcessSort?) -> some View {
        VStack(spacing: 6) {
            Button { if let sort { open(sort) } } label: {
                Gauge(value: value, caption: caption, tint: tint)
            }
            .buttonStyle(.plain)
            .disabled(sort == nil)
            .help(sort == nil ? "" : "Show the processes using it")

            Sparkline(samples: history, tint: tint)
                .frame(height: 24)
            Text(detail)
                .font(Theme.ui(9.5))
                .foregroundStyle(Theme.text3)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Row

private struct ProcessRow: View {
    let sample: ProcessSample
    let sort: ProcessSort
    let tint: Color
    let peak: Double

    private var fraction: Double {
        guard peak > 0 else { return 0 }
        let value: Double
        switch sort {
        case .cpu:    value = sample.cpu
        case .memory: value = Double(sample.memory)
        case .disk:   value = sample.diskRate
        }
        return min(value / peak, 1)
    }

    private var value: String {
        switch sort {
        case .cpu:    return String(format: "%.1f%%", sample.cpu)
        case .memory: return SystemMonitor.bytes(Double(sample.memory))
        case .disk:   return SystemMonitor.rate(sample.diskRate)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(sample.name)
                .font(Theme.ui(11))
                .foregroundStyle(Theme.text1)
                .lineLimit(1)
                .frame(width: 130, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.06))
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(3, geo.size.width * CGFloat(fraction)))
                }
            }
            .frame(height: 5)

            Text(value)
                .font(Theme.mono(10.5, .semibold))
                .foregroundStyle(Theme.text1)
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Theme.row, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .help("pid \(sample.pid)")
    }
}

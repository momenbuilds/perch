import Combine
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// A single running process as the explorer sees it.
struct ProcessSample: Identifiable, Equatable {
    let pid: pid_t
    let name: String
    /// Share of the whole machine's CPU capacity, 0…100.
    let cpu: Double
    let memory: UInt64
    /// Disk bytes per second, read plus written.
    let diskRate: Double

    var id: pid_t { pid }
}

enum ProcessSort: String, CaseIterable, Identifiable {
    case cpu, memory, disk

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu:    return "CPU"
        case .memory: return "Memory"
        case .disk:   return "Disk"
        }
    }
}

/// One sampled value plus the recent history behind it, for a readout with a sparkline.
struct Metric {
    var value: Double = 0          // 0…1
    var history: [Double] = []

    mutating func push(_ next: Double) {
        value = min(max(next, 0), 1)
        history.append(value)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}

/// Live system load: CPU, memory, GPU, disk, network, battery.
///
/// Sampling is reference-counted — nothing is read while no view is showing the
/// numbers, so an idle island costs nothing.
@MainActor
final class SystemMonitor: ObservableObject {

    @Published private(set) var cpu = Metric()
    @Published private(set) var memory = Metric()
    @Published private(set) var gpu = Metric()
    @Published private(set) var disk = Metric()

    @Published private(set) var memoryUsedBytes: UInt64 = 0
    @Published private(set) var memoryTotalBytes: UInt64 = 0
    @Published private(set) var diskUsedBytes: Int64 = 0
    @Published private(set) var diskTotalBytes: Int64 = 0

    @Published private(set) var networkDown: Double = 0   // bytes/sec
    @Published private(set) var networkUp: Double = 0

    @Published private(set) var batteryLevel: Double?     // 0…1, nil on desktops
    @Published private(set) var batteryCharging = false
    @Published private(set) var batteryMinutesLeft: Int?

    @Published private(set) var loadAverage: Double = 0
    @Published private(set) var uptime: TimeInterval = 0
    @Published private(set) var gpuAvailable = false

    /// Top processes, refreshed only while the explorer is open.
    @Published private(set) var processes: [ProcessSample] = []

    private var timer: Timer?
    private var subscribers = 0
    private var processSubscribers = 0
    private var lastProcessCounters: [pid_t: (cpuNanos: UInt64, disk: UInt64)] = [:]
    private var lastProcessSampleAt: DispatchTime?
    private let coreCount = ProcessInfo.processInfo.activeProcessorCount

    private var lastCPUTicks: (busy: Double, total: Double)?
    private var lastNetwork: (down: UInt64, up: UInt64, at: Date)?

    let interval: TimeInterval = 1.5

    // MARK: Lifecycle

    /// Views call this while they are on screen; sampling stops when the last one leaves.
    func subscribe() {
        subscribers += 1
        guard timer == nil else { return }
        sample()
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func unsubscribe() {
        subscribers = max(0, subscribers - 1)
        guard subscribers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    /// Walking every process is far more work than the aggregate counters, so it only
    /// happens while the explorer is actually on screen.
    func subscribeProcesses() {
        processSubscribers += 1
        sampleProcesses()
    }

    func unsubscribeProcesses() {
        processSubscribers = max(0, processSubscribers - 1)
        if processSubscribers == 0 {
            processes = []
            lastProcessCounters = [:]
            lastProcessSampleAt = nil
        }
    }

    // MARK: Sampling

    func sample() {
        sampleCPU()
        sampleMemory()
        sampleGPU()
        sampleDisk()
        sampleNetwork()
        sampleBattery()
        if processSubscribers > 0 { sampleProcesses() }

        var loads = [Double](repeating: 0, count: 3)
        getloadavg(&loads, 3)
        loadAverage = loads[0]
        uptime = Self.systemUptime()
    }

    private func sampleCPU() {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return }

        let user = Double(info.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle

        // Ticks are cumulative since boot, so usage is the delta between samples.
        if let last = lastCPUTicks {
            let dBusy = busy - last.busy
            let dTotal = total - last.total
            if dTotal > 0 { cpu.push(dBusy / dTotal) }
        }
        lastCPUTicks = (busy, total)
    }

    private func sampleMemory() {
        var total = UInt64(0)
        var size = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &total, &size, nil, 0)
        memoryTotalBytes = total

        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size
                                           / MemoryLayout<integer_t>.size)
        var vm = vm_statistics64_data_t()
        let result = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS, total > 0 else { return }

        // Matches Activity Monitor's "memory used": resident + wired + compressed.
        let page = Double(vm_kernel_page_size)
        let used = (Double(vm.active_count) + Double(vm.wire_count)
                    + Double(vm.compressor_page_count)) * page
        memoryUsedBytes = UInt64(used)
        memory.push(used / Double(total))
    }

    /// GPU load comes from the accelerator's own performance counters. Machines expose
    /// more than one accelerator service (integrated plus discrete); the busiest one
    /// that publishes the key is the honest answer.
    private func sampleGPU() {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOAccelerator"),
                                           &iterator) == kIOReturnSuccess else { return }
        defer { IOObjectRelease(iterator) }

        var best: Double?
        while case let service = IOIteratorNext(iterator), service != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &properties,
                                                 kCFAllocatorDefault, 0) == kIOReturnSuccess,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any] {
                let candidates = ["Device Utilization %", "GPU Activity(%)",
                                  "Renderer Utilization %", "Device Unit 0 Utilization %"]
                for key in candidates {
                    if let n = stats[key] as? NSNumber {
                        best = max(best ?? 0, n.doubleValue)
                        break
                    }
                }
            }
            IOObjectRelease(service)
        }

        if let best {
            gpuAvailable = true
            gpu.push(best / 100)
        }
    }

    private func sampleDisk() {
        let url = URL(fileURLWithPath: "/")
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey,
                                                             .volumeTotalCapacityKey]),
              let free = values.volumeAvailableCapacity,
              let total = values.volumeTotalCapacity, total > 0 else { return }
        diskTotalBytes = Int64(total)
        diskUsedBytes = Int64(total - free)
        disk.push(Double(total - free) / Double(total))
    }

    private func sampleNetwork() {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return }
        defer { freeifaddrs(pointer) }

        var down: UInt64 = 0
        var up: UInt64 = 0
        var cursor = pointer
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let name = current.pointee.ifa_name.flatMap({ String(cString: $0) }),
                  name.hasPrefix("en") || name.hasPrefix("bridge") || name.hasPrefix("utun"),
                  current.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK),
                  let data = current.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
            else { continue }
            down += UInt64(data.pointee.ifi_ibytes)
            up += UInt64(data.pointee.ifi_obytes)
        }

        let now = Date()
        if let last = lastNetwork {
            let seconds = now.timeIntervalSince(last.at)
            if seconds > 0 {
                // Counters are monotonic but can wrap or reset when an interface drops.
                networkDown = down >= last.down ? Double(down - last.down) / seconds : 0
                networkUp = up >= last.up ? Double(up - last.up) / seconds : 0
            }
        }
        lastNetwork = (down, up, now)
    }

    private func sampleBattery() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue() as? [String: Any] else { continue }
            if let current = description[kIOPSCurrentCapacityKey] as? Int,
               let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 {
                batteryLevel = Double(current) / Double(max)
            }
            batteryCharging = (description[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if let minutes = description[kIOPSTimeToEmptyKey] as? Int, minutes > 0 {
                batteryMinutesLeft = minutes
            } else {
                batteryMinutesLeft = nil
            }
            return
        }
    }

    /// CPU time and disk I/O are cumulative per process, so both are turned into rates
    /// by differencing against the previous walk.
    private func sampleProcesses() {
        let capacity = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard capacity > 0 else { return }

        var pids = [pid_t](repeating: 0, count: Int(capacity) / MemoryLayout<pid_t>.size)
        let written = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, capacity)
        guard written > 0 else { return }

        let now = DispatchTime.now()
        let elapsed = lastProcessSampleAt.map {
            Double(now.uptimeNanoseconds &- $0.uptimeNanoseconds)
        } ?? 0

        var counters: [pid_t: (cpuNanos: UInt64, disk: UInt64)] = [:]
        var samples: [ProcessSample] = []
        counters.reserveCapacity(pids.count)

        for pid in pids where pid > 0 {
            var usage = rusage_info_v4()
            let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
                }
            }
            guard result == 0 else { continue }

            let cpuNanos = usage.ri_user_time &+ usage.ri_system_time
            let disk = usage.ri_diskio_bytesread &+ usage.ri_diskio_byteswritten
            counters[pid] = (cpuNanos, disk)

            guard elapsed > 0, let previous = lastProcessCounters[pid] else { continue }

            let cpuDelta = cpuNanos >= previous.cpuNanos ? Double(cpuNanos - previous.cpuNanos) : 0
            let diskDelta = disk >= previous.disk ? Double(disk - previous.disk) : 0
            let cpuPercent = cpuDelta / elapsed / Double(coreCount) * 100
            let diskRate = diskDelta / (elapsed / 1_000_000_000)

            // Skip the long tail of idle daemons: they only add noise to the list.
            guard cpuPercent > 0.05 || usage.ri_resident_size > 40 * 1_048_576 || diskRate > 1024
            else { continue }

            var buffer = [CChar](repeating: 0, count: 256)
            proc_name(pid, &buffer, UInt32(buffer.count))
            let name = String(cString: buffer)

            samples.append(ProcessSample(pid: pid,
                                         name: name.isEmpty ? "pid \(pid)" : name,
                                         cpu: cpuPercent,
                                         memory: usage.ri_resident_size,
                                         diskRate: diskRate))
        }

        lastProcessCounters = counters
        lastProcessSampleAt = now
        if !samples.isEmpty || elapsed > 0 { processes = samples }
    }

    func topProcesses(by sort: ProcessSort, limit: Int = 7) -> [ProcessSample] {
        let ordered: [ProcessSample]
        switch sort {
        case .cpu:    ordered = processes.sorted { $0.cpu > $1.cpu }
        case .memory: ordered = processes.sorted { $0.memory > $1.memory }
        case .disk:   ordered = processes.sorted { $0.diskRate > $1.diskRate }
        }
        return Array(ordered.prefix(limit))
    }

    private static func systemUptime() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        var mib = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &boot, &size, nil, 0) == 0, boot.tv_sec != 0 else { return 0 }
        return Date().timeIntervalSince(Date(timeIntervalSince1970: TimeInterval(boot.tv_sec)))
    }

    // MARK: Formatting

    static func bytes(_ value: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = value
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return value >= 100 || index == 0
            ? String(format: "%.0f %@", value, units[index])
            : String(format: "%.1f %@", value, units[index])
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        bytes(bytesPerSecond) + "/s"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let days = total / 86_400
        let hours = (total % 86_400) / 3600
        let minutes = (total % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}

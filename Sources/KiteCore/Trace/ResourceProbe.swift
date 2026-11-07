import Foundation
#if os(macOS)
import Darwin
import IOKit.ps
#endif

/// Resource numbers for the trace's samples: each process's memory, CPU, wakeups and energy, and the Mac's power,
/// heat and memory pressure. Reading is a handful of system calls per process, off the main thread (`ResourceSampler`).
public enum ResourceProbe {
    /// One process's counters, read now. CPU, wakeups and energy are totals since the process started; rates come
    /// from two readings (`ResourceSampler.rates`).
    public struct Counters: Equatable, Sendable {
        public var residentBytes: UInt64
        /// Physical footprint: what Activity Monitor's Memory column shows.
        public var footprintBytes: UInt64
        public var cpuNanoseconds: UInt64
        /// Interrupt wakeups (Chromium's Mac task manager's idle wakeups).
        public var interruptWakeups: UInt64
        /// Package idle exits (Activity Monitor's Idle Wake Ups).
        public var idleWakeups: UInt64
        /// Energy billed to the process, in nanojoules.
        public var energyNanojoules: UInt64

        public init(residentBytes: UInt64, footprintBytes: UInt64, cpuNanoseconds: UInt64, interruptWakeups: UInt64,
                    idleWakeups: UInt64, energyNanojoules: UInt64) {
            self.residentBytes = residentBytes
            self.footprintBytes = footprintBytes
            self.cpuNanoseconds = cpuNanoseconds
            self.interruptWakeups = interruptWakeups
            self.idleWakeups = idleWakeups
            self.energyNanojoules = energyNanojoules
        }
    }

    /// The Mac right now.
    public struct System: Equatable, Sendable {
        /// nil on a Mac with no battery.
        public var onBattery: Bool?
        public var batteryPercent: Double?
        /// Minutes to empty as macOS estimates it, when on battery and known.
        public var minutesToEmpty: Double?
        /// nominal, fair, serious, critical.
        public var thermal: String
        public var lowPowerMode: Bool
        /// normal, warning or critical (the kernel's memory pressure level).
        public var memoryPressure: String

        public init(onBattery: Bool?, batteryPercent: Double?, minutesToEmpty: Double?, thermal: String, lowPowerMode: Bool,
                    memoryPressure: String) {
            self.onBattery = onBattery
            self.batteryPercent = batteryPercent
            self.minutesToEmpty = minutesToEmpty
            self.thermal = thermal
            self.lowPowerMode = lowPowerMode
            self.memoryPressure = memoryPressure
        }
    }

    #if canImport(Darwin)
    public static func thermalName(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
    #endif

    #if os(macOS)
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// The counters of `pid` (any process of this user), or nil once it's gone.
    public static func counters(_ pid: Int32) -> Counters? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard result == 0 else { return nil }
        // CPU times are in Mach absolute time units.
        let ticks = info.ri_user_time + info.ri_system_time
        let nanoseconds = ticks.multipliedReportingOverflow(by: UInt64(timebase.numer)).partialValue / UInt64(max(timebase.denom, 1))
        return Counters(residentBytes: info.ri_resident_size, footprintBytes: info.ri_phys_footprint, cpuNanoseconds: nanoseconds,
                        interruptWakeups: info.ri_interrupt_wkups, idleWakeups: info.ri_pkg_idle_wkups,
                        energyNanojoules: info.ri_billed_energy)
    }

    /// The Mac's power, heat and memory pressure.
    public static func system() -> System {
        var onBattery: Bool?
        var percent: Double?
        var minutes: Double?
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                onBattery = info[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
                if let current = info[kIOPSCurrentCapacityKey] as? Double, let max = info[kIOPSMaxCapacityKey] as? Double, max > 0 {
                    percent = (current / max * 1000).rounded() / 10
                }
                if onBattery == true, let empty = info[kIOPSTimeToEmptyKey] as? Double, empty > 0 { minutes = empty }
            }
        }
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let pressure: String
        if sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 {
            pressure = level >= 4 ? "critical" : level >= 2 ? "warning" : "normal"
        } else {
            pressure = "unknown"
        }
        return System(onBattery: onBattery, batteryPercent: percent, minutesToEmpty: minutes,
                      thermal: thermalName(ProcessInfo.processInfo.thermalState),
                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled, memoryPressure: pressure)
    }

    /// This process's children (Chromium's helpers).
    public static func childPIDs(of parent: Int32 = getpid()) -> [Int32] {
        let count = proc_listchildpids(parent, nil, 0)
        guard count > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(count) * 2)
        let filled = proc_listchildpids(parent, &pids, Int32(pids.count * MemoryLayout<Int32>.size))
        guard filled > 0 else { return [] }
        return Array(pids.prefix(Int(filled))).filter { $0 > 0 }
    }

    /// A process's argv (KERN_PROCARGS2), to tell Chromium's helpers apart.
    public static func arguments(of pid: Int32) -> [String] {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        let argc = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
    #else
    public static func counters(_ pid: Int32) -> Counters? { nil }
    public static func system() -> System {
        System(onBattery: nil, batteryPercent: nil, minutesToEmpty: nil, thermal: "unknown", lowPowerMode: false, memoryPressure: "unknown")
    }
    public static func childPIDs(of parent: Int32 = 0) -> [Int32] { [] }
    public static func arguments(of pid: Int32) -> [String] { [] }
    #endif

    /// What a Chromium helper is, from its `--type` argument: gpu, renderer, utility (with its service), or other.
    public static func helperKind(_ arguments: [String]) -> (kind: String, service: String?) {
        func value(_ flag: String) -> String? {
            arguments.first { $0.hasPrefix("--\(flag)=") }.map { String($0.dropFirst(flag.count + 3)) }
        }
        switch value("type") {
        case "gpu-process": return ("gpu", nil)
        case "renderer": return (arguments.contains("--extension-process") ? "extension" : "renderer", nil)
        case "utility": return ("utility", value("utility-sub-type").map { TaskManager.utilityName(subType: $0) })
        case nil: return ("other", nil)
        case let other?: return (TraceRedaction.word(other), nil)
        }
    }
}

/// Samples Kite's processes and the Mac for the trace, keeping the last reading of each process so each sample has
/// rates over the interval (CPU %, wakeups a second, energy in millijoules and milliwatts) and the battery's drain.
/// Not thread-safe: call from one queue.
public final class ResourceSampler: @unchecked Sendable {
    /// A process Kite knows: the browser, a helper, or a tab's renderer, with what the tabs it renders are about.
    public struct Process: Equatable, Sendable {
        public var pid: Int32
        /// browser, gpu, renderer, extension, utility, other.
        public var kind: String
        public var service: String?
        /// Tabs whose pages this process renders (several when Chromium shares one).
        public var tabs: [UUID]
        public var hosts: [String]
        /// Claude sessions those tabs belong to.
        public var sessions: [String]

        public init(pid: Int32, kind: String, service: String? = nil, tabs: [UUID] = [], hosts: [String] = [], sessions: [String] = []) {
            self.pid = pid
            self.kind = kind
            self.service = service
            self.tabs = tabs
            self.hosts = hosts
            self.sessions = sessions
        }
    }

    private var previous: [Int32: (counters: ResourceProbe.Counters, m: Double)] = [:]
    private var lastBattery: (percent: Double, m: Double)?
    private var lastSystem: ResourceProbe.System?
    private var kinds: [Int32: (kind: String, service: String?)] = [:]
    /// Read counters with this (tests swap it).
    var read: (Int32) -> ResourceProbe.Counters? = ResourceProbe.counters
    var readSystem: () -> ResourceProbe.System = ResourceProbe.system

    public init() {}

    /// Kite's processes: the browser, then its children, with renderers mapped to the tabs `pages` gives (pid → tabs).
    public func processes(pages: [Int32: [(tab: UUID, host: String?, session: String?)]], browser: Int32) -> [Process] {
        var list = [Process(pid: browser, kind: "browser")]
        let children = ResourceProbe.childPIDs(of: browser)
        var seen: Set<Int32> = [browser]
        for pid in children {
            seen.insert(pid)
            let kind = kinds[pid] ?? ResourceProbe.helperKind(ResourceProbe.arguments(of: pid))
            kinds[pid] = kind
            var process = Process(pid: pid, kind: kind.kind, service: kind.service)
            if let tabs = pages[pid] { fill(&process, tabs) }
            list.append(process)
        }
        // WebKit's web processes aren't Kite's children: the pages name them.
        for (pid, tabs) in pages where !seen.contains(pid) {
            var process = Process(pid: pid, kind: "renderer")
            fill(&process, tabs)
            list.append(process)
        }
        kinds = kinds.filter { seen.contains($0.key) }
        return list
    }

    private func fill(_ process: inout Process, _ tabs: [(tab: UUID, host: String?, session: String?)]) {
        process.tabs = tabs.map(\.tab)
        process.hosts = Array(Set(tabs.compactMap(\.host))).sorted()
        process.sessions = Array(Set(tabs.compactMap(\.session))).sorted()
    }

    /// One sample: a `proc` record per process, a `totals` record, and a `system` record, all stamped `clock`.
    /// Processes seen for the first time give memory only (rates need a second reading).
    public func sample(_ processes: [Process], clock: (t: Double, m: Double) = TraceClock.now(), reason: String = "interval") -> [TraceRecord] {
        var records: [TraceRecord] = []
        var totals = (resident: UInt64(0), footprint: UInt64(0), cpu: 0.0, wakeups: 0.0, energy: 0.0, mw: 0.0, count: 0)
        var live: [Int32: (counters: ResourceProbe.Counters, m: Double)] = [:]
        for process in processes {
            guard let counters = read(process.pid) else { continue }
            live[process.pid] = (counters, clock.m)
            var attrs: [String: JSONValue] = [
                "pid": .number(Double(process.pid)), "proc": .string(process.kind),
                "resident_mb": .number(Self.mb(counters.residentBytes)), "footprint_mb": .number(Self.mb(counters.footprintBytes)),
            ]
            if let service = process.service { attrs["service"] = .string(service) }
            if !process.tabs.isEmpty { attrs["tabs"] = .array(process.tabs.map { .string($0.uuidString) }) }
            if !process.hosts.isEmpty { attrs["hosts"] = .array(process.hosts.map { .string($0) }) }
            if !process.sessions.isEmpty { attrs["sessions"] = .array(process.sessions.map { .string($0) }) }
            totals.resident += counters.residentBytes
            totals.footprint += counters.footprintBytes
            totals.count += 1
            var dur: Double?
            if let before = previous[process.pid], let rates = Self.rates(from: before.counters, to: counters, ms: clock.m - before.m) {
                dur = clock.m - before.m
                attrs["cpu_pct"] = .number(rates.cpuPercent)
                attrs["wakeups_s"] = .number(rates.wakeupsPerSecond)
                attrs["idle_wakeups_s"] = .number(rates.idleWakeupsPerSecond)
                attrs["energy_mj"] = .number(rates.energyMillijoules)
                attrs["power_mw"] = .number(rates.milliwatts)
                totals.cpu += rates.cpuPercent
                totals.wakeups += rates.wakeupsPerSecond
                totals.energy += rates.energyMillijoules
                totals.mw += rates.milliwatts
            }
            var record = TraceRecord(kind: .sample, name: "proc", t: clock.t, m: clock.m, dur: dur, actor: "kite", attrs: attrs)
            if process.tabs.count == 1 { record.tab = process.tabs[0].uuidString }
            if process.hosts.count == 1 { record.host = process.hosts[0] }
            if process.sessions.count == 1 { record.session = process.sessions[0] }
            records.append(record)
        }
        previous = live
        records.append(TraceRecord(kind: .sample, name: "totals", t: clock.t, m: clock.m, actor: "kite", attrs: [
            "processes": .number(Double(totals.count)), "resident_mb": .number(Self.mb(totals.resident)),
            "footprint_mb": .number(Self.mb(totals.footprint)), "cpu_pct": .number(Self.round(totals.cpu)),
            "wakeups_s": .number(Self.round(totals.wakeups)), "energy_mj": .number(Self.round(totals.energy)),
            "power_mw": .number(Self.round(totals.mw)), "reason": .string(reason),
        ]))
        let system = readSystem()
        lastSystem = system
        var attrs: [String: JSONValue] = [
            "thermal": .string(system.thermal), "low_power": .bool(system.lowPowerMode), "memory_pressure": .string(system.memoryPressure),
        ]
        if let onBattery = system.onBattery { attrs["on_battery"] = .bool(onBattery) }
        if let percent = system.batteryPercent {
            attrs["battery_pct"] = .number(percent)
            if system.onBattery == true, let last = lastBattery, clock.m > last.m {
                attrs["drain_pct_h"] = .number(Self.round((last.percent - percent) / ((clock.m - last.m) / 3_600_000)))
            }
            lastBattery = system.onBattery == true ? (percent, clock.m) : nil
        }
        if let minutes = system.minutesToEmpty { attrs["minutes_to_empty"] = .number(minutes) }
        records.append(TraceRecord(kind: .sample, name: "system", t: clock.t, m: clock.m, actor: "kite", attrs: attrs))
        return records
    }

    /// The Mac's state as of the last sample, to tell a notable change.
    public var lastSystemState: ResourceProbe.System? { lastSystem }

    public struct Rates: Equatable, Sendable {
        public var cpuPercent: Double
        public var wakeupsPerSecond: Double
        public var idleWakeupsPerSecond: Double
        public var energyMillijoules: Double
        public var milliwatts: Double
    }

    /// Rates between two readings `ms` apart; nil when the process restarted (a counter went down) or no time passed.
    public static func rates(from a: ResourceProbe.Counters, to b: ResourceProbe.Counters, ms: Double) -> Rates? {
        guard ms > 0, b.cpuNanoseconds >= a.cpuNanoseconds, b.interruptWakeups >= a.interruptWakeups,
              b.idleWakeups >= a.idleWakeups, b.energyNanojoules >= a.energyNanojoules else { return nil }
        let seconds = ms / 1000
        let energy = Double(b.energyNanojoules - a.energyNanojoules) / 1_000_000
        return Rates(cpuPercent: round(Double(b.cpuNanoseconds - a.cpuNanoseconds) / 1_000_000 / ms * 100),
                     wakeupsPerSecond: round(Double(b.interruptWakeups - a.interruptWakeups) / seconds),
                     idleWakeupsPerSecond: round(Double(b.idleWakeups - a.idleWakeups) / seconds),
                     energyMillijoules: round(energy), milliwatts: round(energy / seconds))
    }

    static func mb(_ bytes: UInt64) -> Double { round(Double(bytes) / 1_048_576) }
    static func round(_ value: Double) -> Double { (value * 10).rounded() / 10 }
}

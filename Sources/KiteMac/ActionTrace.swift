import AppKit
import IOKit.ps
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

/// The app's half of the action trace (`Trace`, docs/action-trace.md): where it's written, the setting that turns
/// it off, and the events no single feature owns: launch and its phases, quit, sleep and wake, the app coming
/// forward, menu commands and shortcuts, hangs, downloads, and resource samples (each process's memory, CPU,
/// wakeups and energy, and the Mac's power, heat and memory pressure).
///
/// Everything here is cheap on the main thread: observers emit one record each, and sampling reads the processes on
/// a background queue (the main thread only lists which pages run in which process). Nothing samples while the Mac
/// sleeps, and samples come every 30 s instead of 10 s on battery.
@MainActor
final class ActionTrace {
    static let shared = ActionTrace()

    static let sampleInterval: TimeInterval = 10
    static let batterySampleInterval: TimeInterval = 30
    /// The main thread answering a ping later than this is a hang.
    static let hangThreshold: Double = 250

    private var controllers: () -> [BrowserWindowController] = { [] }
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let queue = DispatchQueue(label: "dev.gabek.Kite.trace-sampler", qos: .utility)
    /// Only used on `queue`.
    private let sampler = ResourceSampler()
    private var sampleGeneration = 0
    private var onBattery = false
    private var asleep: (t: Double, m: Double)?
    private var hangTimer: DispatchSourceTimer?
    private var memoryPressure: DispatchSourceMemoryPressure?
    private var powerSource: CFRunLoopSource?
    private var downloads: [String: (start: (t: Double, m: Double), received: Int64)] = [:]
    private var started = false
    private var launched: (t: Double, m: Double) = TraceClock.now()

    // MARK: Launch phases

    nonisolated(unsafe) private static var marks: [(String, Double)] = []
    private static let marksLock = NSLock()

    /// A point in launch (`main`, `did_finish_launching`, `window_shown`), for `app.launch`'s phases.
    nonisolated static func mark(_ name: String) {
        let now = TraceClock.monotonic()
        marksLock.withLock { marks.append((name, now)) }
    }

    // MARK: Starting and stopping

    /// Turns tracing on (unless Settings › Advanced says not), and records the launch that just finished.
    func start(supportDirectory: URL, controllers: @escaping () -> [BrowserWindowController]) {
        guard !started else { return }
        started = true
        self.controllers = controllers
        let store = TraceStore(directory: TraceStore.directory(supportDirectory: supportDirectory))
        Trace.configure(store, enabled: Self.settingEnabled)
        store.prune()
        observe()
        recordLaunch()
        if Trace.isEnabled { startSampling() }
    }

    static var settingEnabled: Bool { !UserDefaults.standard.bool(forKey: Trace.disabledKey) }

    /// The app is quitting: say so, and write what's queued.
    func quit() {
        Trace.event("app.quit", actor: .user, duration: TraceClock.monotonic() - launched.m, start: TraceClock.now())
        Trace.flush()
    }

    private func recordLaunch() {
        let now = TraceClock.now()
        let marks = Self.marksLock.withLock { Self.marks }
        var attrs: [String: JSONValue] = [:]
        var origin = marks.first?.1 ?? now.m
        // The process's own start, from the kernel, on the monotonic clock.
        if let started = Self.processStart() {
            origin = now.m - (now.t - started)
            if let main = marks.first(where: { $0.0 == "main" })?.1 { attrs["process_to_main_ms"] = .number(Self.round(main - origin)) }
        }
        var previous: (String, Double)?
        for mark in marks {
            if let previous { attrs["\(previous.0)_to_\(mark.0)_ms"] = .number(Self.round(mark.1 - previous.1)) }
            previous = mark
        }
        if let previous { attrs["\(previous.0)_to_ready_ms"] = .number(Self.round(now.m - previous.1)) }
        attrs["engine"] = .string(AppDelegate.engineFellBack ? "WebKit" : controllers().first?.pool.engine.name ?? "unknown")
        launched = (now.t - (now.m - origin), origin)
        Trace.event("app.launch", actor: .user, duration: Self.round(now.m - origin), start: launched, attrs)
    }

    /// When this process started, Unix milliseconds.
    private static func processStart() -> Double? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return nil }
        let start = info.kp_proc.p_un.__p_starttime
        return Double(start.tv_sec) * 1000 + Double(start.tv_usec) / 1000
    }

    static func round(_ ms: Double) -> Double { (ms * 10).rounded() / 10 }

    // MARK: Observers

    private func observe() {
        let center = NotificationCenter.default
        func on(_ name: Notification.Name, _ center: NotificationCenter = .default, object: Any? = nil,
                _ handle: @escaping @MainActor (Notification) -> Void) -> NSObjectProtocol {
            center.addObserver(forName: name, object: object, queue: .main) { note in MainActor.assumeIsolated { handle(note) } }
        }
        observers.append(on(UserDefaults.didChangeNotification) { [weak self] _ in self?.settingChanged() })
        observers.append(on(NSApplication.didBecomeActiveNotification) { [weak self] _ in
            Trace.event("app.active", actor: .user)
            self?.startHangWatch()
        })
        observers.append(on(NSApplication.didResignActiveNotification) { [weak self] _ in
            Trace.event("app.inactive", actor: .user)
            self?.stopHangWatch()
        })
        // Menu commands, from the menu bar or their shortcuts: by name, never what they acted on.
        observers.append(on(NSMenu.didSendActionNotification) { note in
            guard let item = note.userInfo?["MenuItem"] as? NSMenuItem else { return }
            let command = item.identifier?.rawValue ?? item.action.map(NSStringFromSelector) ?? "unknown"
            let byKey = NSApp.currentEvent?.type == .keyDown
            Trace.event(byKey ? "ui.shortcut" : "ui.menu", ["command": .string(TraceRedaction.word(command))])
        })
        observers.append(on(ProcessInfo.thermalStateDidChangeNotification) { [weak self] _ in
            Trace.event("system.thermal", actor: .kite, ["state": .string(ResourceProbe.thermalName(ProcessInfo.processInfo.thermalState))])
            self?.sampleNow(reason: "thermal")
        })
        observers.append(on(.NSProcessInfoPowerStateDidChange) { [weak self] _ in
            Trace.event("system.low_power", actor: .kite, ["on": .bool(ProcessInfo.processInfo.isLowPowerModeEnabled)])
            self?.sampleNow(reason: "low_power")
        })
        #if canImport(CEFBridge)
        observers.append(on(.KCDownloadDidUpdate) { [weak self] note in self?.downloadUpdated(note) })
        #endif
        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(on(NSWorkspace.willSleepNotification, workspace) { [weak self] _ in self?.willSleep() })
        workspaceObservers.append(on(NSWorkspace.didWakeNotification, workspace) { [weak self] _ in self?.didWake() })
        _ = center
        if NSApp.isActive { startHangWatch() }

        let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        pressure.setEventHandler { [weak self, weak pressure] in
            MainActor.assumeIsolated {
                let level = pressure?.data.contains(.critical) == true ? "critical" : "warning"
                Trace.event("system.memory_pressure", actor: .kite, ["level": .string(level)])
                self?.sampleNow(reason: "memory_pressure")
            }
        }
        pressure.resume()
        memoryPressure = pressure

        // Plugging in or unplugging: sample at once, and sample at the new cadence.
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let trace = Unmanaged<ActionTrace>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { trace.powerSourceChanged() }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
            powerSource = source
        }
    }

    private func settingChanged() {
        let enabled = Self.settingEnabled
        guard enabled != Trace.isEnabled else { return }
        if enabled {
            Trace.setEnabled(true)
            Trace.event("trace.on", actor: .user)
            startSampling()
        } else {
            Trace.event("trace.off", actor: .user)
            Trace.flush()
            Trace.setEnabled(false)
            sampleGeneration += 1
        }
    }

    private func willSleep() {
        let now = TraceClock.now()
        Trace.event("app.sleep", actor: .kite, start: now)
        asleep = now
        sampleGeneration += 1
        stopHangWatch()
        Trace.flush()
    }

    private func didWake() {
        let slept = asleep
        asleep = nil
        let now = TraceClock.monotonic()
        Trace.event("app.wake", actor: .kite, duration: slept.map { now - $0.m })
        if Trace.isEnabled { startSampling() }
        if NSApp.isActive { startHangWatch() }
    }

    private func powerSourceChanged() {
        let system = ResourceProbe.system()
        let battery = system.onBattery == true
        guard battery != onBattery else { return }
        onBattery = battery
        Trace.event("system.power", actor: .kite, ["on_battery": .bool(battery)])
        sampleNow(reason: "power")
    }

    // MARK: Hangs

    /// Once a second while Kite is in front, a background timer asks the main thread to answer; an answer later than
    /// `hangThreshold` is a hang, as long as the answer took. Nothing runs while Kite is in the background.
    private func startHangWatch() {
        guard hangTimer == nil, Trace.isEnabled else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(250))
        timer.setEventHandler {
            let sent = TraceClock.now()
            DispatchQueue.main.async {
                let lag = TraceClock.monotonic() - sent.m
                if lag >= Self.hangThreshold { Trace.event("app.hang", actor: .kite, duration: Self.round(lag), start: sent) }
            }
        }
        timer.resume()
        hangTimer = timer
    }

    private func stopHangWatch() {
        hangTimer?.cancel()
        hangTimer = nil
    }

    // MARK: Downloads

    #if canImport(CEFBridge)
    private func downloadUpdated(_ note: Notification) {
        // Incognito downloads aren't traced.
        guard Trace.isEnabled, let info = note.userInfo, let update = DownloadUpdate(notificationInfo: info), !update.isIncognito else { return }
        let key = "\(update.engineContext)#\(update.engineID)"
        let url = URL(string: update.url)
        if downloads[key] == nil, update.state == .inProgress {
            let start = TraceClock.now()
            downloads[key] = (start, update.receivedBytes)
            Trace.event("download.started", url: url, actor: .user, start: start,
                        ["total_bytes": .number(Double(max(update.totalBytes, 0)))])
        }
        guard update.state != .inProgress, let started = downloads.removeValue(forKey: key) else { return }
        Trace.event("download.finished", url: url, actor: .user, duration: TraceClock.monotonic() - started.start.m, start: started.start,
                    ["state": .string(update.state.rawValue), "bytes": .number(Double(update.receivedBytes))])
    }
    #endif

    // MARK: Resource samples

    private func startSampling() {
        sampleGeneration += 1
        onBattery = ResourceProbe.system().onBattery == true
        sampleNow(reason: "start")
    }

    /// Samples now (a notable change) and then at the usual cadence.
    func sampleNow(reason: String) {
        guard Trace.isEnabled, asleep == nil else { return }
        sampleGeneration += 1
        let generation = sampleGeneration
        let pages = pageMap()
        let sampler = sampler
        queue.async { [weak self] in
            let processes = sampler.processes(pages: pages, browser: getpid())
            for record in sampler.sample(processes, reason: reason) { Trace.emit(record) }
            let battery = sampler.lastSystemState?.onBattery == true
            DispatchQueue.main.async {
                guard let self, generation == self.sampleGeneration else { return }
                self.onBattery = battery
                let interval = battery ? Self.batterySampleInterval : Self.sampleInterval
                DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                    guard let self, generation == self.sampleGeneration else { return }
                    self.sampleNow(reason: "interval")
                }
            }
        }
    }

    /// Which tabs each renderer process draws, with their hosts and Claude sessions. Private windows are left out.
    private func pageMap() -> [Int32: [(tab: UUID, host: String?, session: String?)]] {
        var map: [Int32: [(tab: UUID, host: String?, session: String?)]] = [:]
        var seen = Set<ObjectIdentifier>()
        for controller in controllers() where !controller.isIncognito {
            let state = controller.store.state
            let layout = controller.store.traceLayout
            for (id, page) in controller.pool.livePages {
                guard let pid = page.processIdentifier, seen.insert(ObjectIdentifier(page)).inserted else { continue }
                map[pid, default: []].append((id, TraceRedaction.place(state.tab(id)?.url).host, layout?.tabs[id]?.session))
            }
        }
        return map
    }

    // MARK: Who's acting on a tab

    /// Tabs an agent's call is acting on right now (and for a moment after, while the page answers), so the page's
    /// own events (a click it saw, a load it started) are the agent's, not the user's.
    private static var agentTabs: [UUID: (actor: TraceActor, depth: Int, until: Double)] = [:]
    static let agentGrace: Double = 250

    static func agentActing(on tab: UUID, actor: TraceActor) {
        let entry = agentTabs[tab]
        agentTabs[tab] = (actor, (entry?.depth ?? 0) + 1, .infinity)
    }

    static func agentDone(on tab: UUID) {
        guard var entry = agentTabs[tab] else { return }
        entry.depth -= 1
        if entry.depth <= 0 { entry.until = TraceClock.monotonic() + agentGrace }
        agentTabs[tab] = entry
        if agentTabs.count > 64 {
            let now = TraceClock.monotonic()
            agentTabs = agentTabs.filter { $0.value.until > now }
        }
    }

    /// Who an event on `tab` belongs to: the agent acting there, or the task's actor, or the user. `grace` counts the
    /// moment after a call too (a load or dialog its action started); input the page saw counts only while a call
    /// is acting there, so a person's click right after an agent's call stays theirs.
    static func actor(forTab tab: UUID?, grace: Bool = true) -> TraceActor {
        if let tab, let entry = agentTabs[tab] {
            if entry.depth > 0 || (grace && entry.until > TraceClock.monotonic()) { return entry.actor }
        }
        return Trace.actor ?? .user
    }
}

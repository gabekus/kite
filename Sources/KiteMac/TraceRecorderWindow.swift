import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

/// Help › Troubleshooting › Record Trace (Arc's TracingFeature; docs/arc-visual-spec.md, "Record
/// Trace"). Arc's "Record Trace" window asks what's wrong and for how long, records a Chromium
/// trace and samples the app, then uploads the bundle to its team. Kite records the same, keeps
/// the bundle in its data folder (Traces/) and never sends it anywhere. Chromium only: WebKit
/// has no tracing API, so the menu item is disabled there.
@MainActor
final class TraceRecorderWindow: NSObject, NSWindowDelegate {
    private static var shared: TraceRecorderWindow?

    static var isAvailable: Bool {
        #if canImport(CEFBridge)
        return KCRuntime.isInitialized
        #else
        return false
        #endif
    }

    static func show() {
        let recorder = shared ?? TraceRecorderWindow()
        shared = recorder
        if UIDiagnostics.enabledByEnvironment {
            // Test runs stay behind the user's windows.
            recorder.window.orderBack(nil)
        } else {
            recorder.window.makeKeyAndOrderFront(nil)
        }
    }

    static var tracesDirectory: URL { AppDelegate.supportDirectory.appendingPathComponent("Traces", isDirectory: true) }

    private enum Phase: Equatable {
        case ready
        case recording(ends: Date)
        case saving
        case saved(URL)
        case failed(String)
    }

    private let window: NSWindow
    private let issueField = NSTextField()
    private let durationPopUp = TracePopUpButton()
    private let startButton = TraceButton(title: TraceRecording.startTitle, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private let cancelButton = TraceButton(title: "Cancel", target: nil, action: nil)
    private let revealButton = TraceButton(title: "Show in Finder", target: nil, action: nil)
    private let againButton = TraceButton(title: "Record Another Trace", target: nil, action: nil)
    private var formViews: [NSView] = []
    private var phase = Phase.ready { didSet { update() } }
    private var timer: Timer?
    private var bundle: URL?
    private var sampler: Process?
    private var startDate = Date()

    private override init() {
        // Arc: a 360 × 400 titled, closable, miniaturizable, resizable window with a full-size
        // content view, centred, its frame saved.
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: TraceRecording.windowSize.width, height: TraceRecording.windowSize.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = TraceRecording.windowTitle
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.minSize = NSSize(width: 320, height: 300)
        window.center()
        // A test profile mustn't move the user's saved frame (it lives in the app's defaults).
        if ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] == nil { window.setFrameAutosaveName("RecordTrace") }
        buildContent()
        update()
    }

    private func buildContent() {
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            return label
        }
        issueField.placeholderString = "Describe it in a few words"
        issueField.setAccessibilityLabel(TraceRecording.descriptionPrompt)
        for duration in TraceRecording.Duration.allCases { durationPopUp.addItem(withTitle: duration.title) }
        durationPopUp.selectItem(at: TraceRecording.Duration.fifteenSeconds.rawValue)
        durationPopUp.setAccessibilityLabel(TraceRecording.durationPrompt)

        let note = NSTextField(wrappingLabelWithString: TraceRecording.privacyNote)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor

        startButton.target = self
        startButton.action = #selector(start(_:))
        startButton.bezelStyle = .push
        startButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        revealButton.target = self
        revealButton.action = #selector(reveal(_:))
        againButton.target = self
        againButton.action = #selector(again(_:))

        statusLabel.alignment = .center
        statusLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        statusLabel.lineBreakMode = .byTruncatingMiddle
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 1
        progress.style = .bar

        let issueLabel = label(TraceRecording.descriptionPrompt)
        let durationLabel = label(TraceRecording.durationPrompt)
        formViews = [issueLabel, issueField, durationLabel, durationPopUp, note, startButton]

        let stack = NSStackView(views: formViews + [statusLabel, progress, cancelButton, revealButton, againButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(18, after: issueField)
        stack.setCustomSpacing(18, after: durationPopUp)
        stack.setCustomSpacing(18, after: note)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        // Below the transparent title bar.
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
            issueField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            note.widthAnchor.constraint(equalTo: stack.widthAnchor),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.contentView = content
    }

    private func update() {
        let ready = phase == .ready
        for view in formViews { view.isHidden = !ready }
        var recording = false
        var finished = false
        switch phase {
        case .ready:
            statusLabel.stringValue = ""
        case .recording(let ends):
            recording = true
            let total = Double(selectedDuration.seconds)
            let left = max(0, ends.timeIntervalSinceNow)
            statusLabel.stringValue = TraceRecording.remainingLabel(seconds: left)
            progress.doubleValue = total > 0 ? 1 - left / total : 1
        case .saving:
            statusLabel.stringValue = "Saving the trace…"
            progress.doubleValue = 1
        case .saved(let url):
            finished = true
            statusLabel.stringValue = "Saved to \(url.lastPathComponent)"
        case .failed(let message):
            finished = true
            statusLabel.stringValue = message
        }
        statusLabel.isHidden = ready
        progress.isHidden = !(recording || phase == .saving)
        cancelButton.isHidden = !recording
        if case .saved = phase { revealButton.isHidden = false } else { revealButton.isHidden = true }
        againButton.isHidden = !finished
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
    }

    private var selectedDuration: TraceRecording.Duration {
        TraceRecording.Duration(rawValue: durationPopUp.indexOfSelectedItem) ?? .fifteenSeconds
    }

    // MARK: Recording

    @objc private func start(_ sender: Any?) {
        guard phase == .ready else { return }
        #if canImport(CEFBridge)
        let duration = selectedDuration
        let date = Date()
        let folder = Self.tracesDirectory.appendingPathComponent(TraceRecording.bundleName(date: date), isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let info = Bundle.main.infoDictionary
            let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
            let engine = (NSApp.delegate as? AppDelegate)?.browserControllers.first?.pool.engine.name ?? "Chromium"
            let text = TraceRecording.descriptionText(issue: issueField.stringValue, duration: duration, kiteVersion: version,
                                                      engine: engine,
                                                      macOS: ProcessInfo.processInfo.operatingSystemVersionString, date: date)
            try text.write(to: folder.appendingPathComponent(TraceRecording.descriptionFilename), atomically: true, encoding: .utf8)
        } catch {
            phase = .failed("Couldn't create the trace folder.")
            return
        }
        // Empty categories: Chromium's default set.
        guard KCRuntime.beginTracing(withCategories: "", completion: nil) else {
            try? FileManager.default.removeItem(at: folder)
            phase = .failed("Chromium couldn't start tracing.")
            return
        }
        bundle = folder
        startDate = date
        startSampler(seconds: duration.seconds, to: folder.appendingPathComponent(TraceRecording.sampleFilename))
        phase = .recording(ends: date.addingTimeInterval(TimeInterval(duration.seconds)))
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        #else
        phase = .failed("Tracing needs the Chromium engine.")
        #endif
    }

    private func tick() {
        guard case .recording(let ends) = phase else { return }
        if ends.timeIntervalSinceNow <= 0 { finish(discard: false) } else { update() }
    }

    /// Arc samples the app with /usr/bin/sample while it traces; Kite samples its own process.
    private func startSampler(seconds: Int, to file: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = [String(ProcessInfo.processInfo.processIdentifier), String(seconds), "-mayDie", "-file", file.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            sampler = process
        } catch {
            sampler = nil
        }
    }

    private func finish(discard: Bool) {
        timer?.invalidate()
        timer = nil
        guard let folder = bundle else { phase = .ready; return }
        if sampler?.isRunning == true { sampler?.interrupt() }
        sampler = nil
        phase = discard ? .ready : .saving
        #if canImport(CEFBridge)
        let file = folder.appendingPathComponent(TraceRecording.traceFilename)
        let ended = KCRuntime.endTracing(toPath: file.path, discard: discard) { [weak self] path in
            MainActor.assumeIsolated { self?.ended(folder: folder, path: path, discarded: discard) }
        }
        if !ended { self.ended(folder: folder, path: nil, discarded: discard) }
        #else
        ended(folder: folder, path: nil, discarded: discard)
        #endif
    }

    private func ended(folder: URL, path: String?, discarded: Bool) {
        bundle = nil
        if discarded {
            try? FileManager.default.removeItem(at: folder)
            phase = .ready
            return
        }
        phase = path == nil ? .failed("Chromium didn't write the trace.") : .saved(folder)
    }

    @objc private func cancel(_ sender: Any?) {
        guard case .recording = phase else { return }
        finish(discard: true)
    }

    @objc private func reveal(_ sender: Any?) {
        guard case .saved(let folder) = phase else { return }
        NSWorkspace.shared.activateFileViewerSelecting([folder])
    }

    @objc private func again(_ sender: Any?) {
        phase = .ready
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window mid-trace cancels it, like Arc's "We've cancelled your trace."
        if case .recording = phase { finish(discard: true) }
    }
}

/// A diagnostics run stays in the background, where `ui input` drops clicks on views that
/// don't take the first mouse; these take it there. Unchanged otherwise.
private final class TraceButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}

private final class TracePopUpButton: NSPopUpButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}

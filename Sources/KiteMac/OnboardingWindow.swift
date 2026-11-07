import AppKit
import KiteCore
import SwiftUI

/// Kite's first-launch onboarding, and Help › Getting Started.
///
/// Arc's shape, from its binary and its AuthFeature bundle (docs/arc-visual-spec.md, "Onboarding"): a
/// window of its own (`_closeOnboardingWindow`) over a saturated, grainy backdrop (`static-bg.png`,
/// `WindowBackground`), one step per screen with a large title, a line or two of text, one primary
/// button and a Back button, ending on a welcome step. Kite's steps are its own: Welcome, Access
/// (every macOS permission Kite uses, `SystemAccess`, asked up front rather than one at a time later),
/// Set Up Claude (Copy Prompt for Claude), and a last step that hands off to Import from Arc or
/// Import from Another Browser.
/// Arc's onboarding itself can't be watched headlessly (it needs an Arc account and a fresh Arc
/// profile), so its sizes and timings here are Kite's, not measured.
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    private static var shown: OnboardingWindow?

    /// onboarding.json, beside session.json.
    static var stateURL: URL { AppDelegate.supportDirectory.appendingPathComponent("onboarding.json") }

    /// Reads whether to show it before session.json is first written, so a new profile is told apart
    /// from an existing install, and records a new profile's onboarding as started.
    static func shouldShowAtLaunch() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        // session.json, or what an install keeps beside it if that was moved aside as unreadable.
        let profileExisted = [AppDelegate.sessionURL, AppDelegate.supportDirectory.appendingPathComponent("history.json"),
                              AppDelegate.supportDirectory.appendingPathComponent("windows.json")]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
        let state = Onboarding.load(from: stateURL)
        let show = Onboarding.shouldShow(environment: environment, sessionExisted: profileExisted, state: state)
        if show, state == nil {
            try? FileManager.default.createDirectory(at: AppDelegate.supportDirectory, withIntermediateDirectories: true)
            Onboarding.save(.init(completed: false), to: stateURL)
        }
        return show
    }

    /// `browser` gives a browser window to land in (opening one if the user closed them all), where
    /// Import from Arc… runs the importer once onboarding has closed, so the two never show at once.
    /// `resume` (onboarding at launch) opens on the step an unfinished onboarding was left at, so
    /// quitting halfway picks up there; Help › Getting Started starts from Welcome.
    static func show(resume: Bool = false, browser: @escaping () -> BrowserWindowController?) {
        let onboarding = shown ?? OnboardingWindow(browser: browser)
        shown = onboarding
        let start = resume ? Onboarding.resumeStep(Onboarding.load(from: stateURL), stepCount: Step.allCases.count) : 0
        onboarding.go(to: start, animated: false)
        // A test-safe run keeps it behind the user's windows.
        WindowPresenter.show(onboarding.window)
    }

    enum Metrics {
        static let size = NSSize(width: 720, height: 620)
        static let columnWidth: CGFloat = 440
        static let titleSize: CGFloat = 34
        static let bodySize: CGFloat = 15
        static let iconSide: CGFloat = 72
        static let buttonHeight: CGFloat = 40
        static let stepFade: TimeInterval = 0.2
        static let previewLines = 4
    }

    private enum Step: Int, CaseIterable { case welcome, access, claude, done }

    private let window: NSWindow
    private let browser: () -> BrowserWindowController?
    /// Bumped by every `go`, so a fade that finishes after another `go` doesn't swap in its old step.
    private var generation = 0
    private var menuObserver: NSObjectProtocol?
    /// Back from System Settings: the access step shows what changed there.
    private var activeObserver: NSObjectProtocol?
    private let content = NSView()
    private let backButton = OnboardingTextButton(title: "‹ Back")
    private let dots = NSStackView()
    private var step = Step.welcome
    /// A step fading out: its buttons are still on screen but no longer count.
    private var transitioning = false
    private var copyButton: OnboardingButton?
    /// Whether the access step has re-read what macOS only answers asynchronously (notifications).
    private var accessRefreshed = false
    private var copiedReset: DispatchWorkItem?

    private init(browser: @escaping () -> BrowserWindowController?) {
        self.browser = browser
        window = NSWindow(contentRect: NSRect(origin: .zero, size: Metrics.size),
                          styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        window.title = "Welcome to Kite"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.identifier = NSUserInterfaceItemIdentifier("onboardingWindow")
        window.delegate = self
        window.center()
        // File › Import from Arc… (or its shortcut) closes onboarding before the importer starts, so
        // onboarding never sits over the importer. Other sheets (Ask Before Claude Acts) leave it be.
        menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.willSendActionNotification, object: nil,
                                                              queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                let id = (note.userInfo?["MenuItem"] as? NSMenuItem)?.identifier?.rawValue
                guard id == "importFromArc" || id == "importFromAnotherBrowser" else { return }
                self?.complete()
                self?.window.close()
            }
        }
        activeObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                                                queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccess() }
        }

        let backdrop = OnboardingBackdrop()
        window.contentView = backdrop
        content.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(content)

        backButton.target = self
        backButton.action = #selector(back)
        backButton.setAccessibilityLabel("Back")
        backButton.setAccessibilityIdentifier("onboardingBack")
        backButton.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(backButton)

        dots.orientation = .horizontal
        dots.spacing = 8
        dots.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(dots)
        for _ in Step.allCases {
            let dot = NSView()
            dot.wantsLayer = true
            dot.layer?.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([dot.widthAnchor.constraint(equalToConstant: 6),
                                         dot.heightAnchor.constraint(equalToConstant: 6)])
            dots.addArrangedSubview(dot)
        }

        NSLayoutConstraint.activate([
            content.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            content.centerYAnchor.constraint(equalTo: backdrop.centerYAnchor, constant: -6),
            content.widthAnchor.constraint(equalToConstant: Metrics.columnWidth),
            backButton.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 20),
            backButton.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 40),
            dots.centerXAnchor.constraint(equalTo: backdrop.centerXAnchor),
            dots.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -26),
        ])
    }

    // MARK: Steps

    private func go(to index: Int, animated: Bool) {
        guard let next = Step(rawValue: index), !transitioning || !animated else { return }
        step = next
        // An unfinished onboarding remembers its step, so quitting here resumes here.
        if var state = Onboarding.load(from: Self.stateURL), !state.completed, state.step != next.rawValue {
            state.step = next.rawValue
            Onboarding.save(state, to: Self.stateURL)
        }
        generation += 1
        let generation = generation
        copiedReset?.cancel()
        let column = makeColumn(for: next)
        let swap = {
            self.content.subviews.forEach { $0.removeFromSuperview() }
            column.translatesAutoresizingMaskIntoConstraints = false
            self.content.addSubview(column)
            NSLayoutConstraint.activate([
                column.leadingAnchor.constraint(equalTo: self.content.leadingAnchor),
                column.trailingAnchor.constraint(equalTo: self.content.trailingAnchor),
                column.topAnchor.constraint(equalTo: self.content.topAnchor),
                column.bottomAnchor.constraint(equalTo: self.content.bottomAnchor),
            ])
        }
        backButton.isHidden = next == .welcome
        for (i, dot) in dots.arrangedSubviews.enumerated() {
            dot.layer?.backgroundColor = NSColor.white.withAlphaComponent(i == next.rawValue ? 0.9 : 0.3).cgColor
        }
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            transitioning = false
            content.alphaValue = 1
            swap()
            return
        }
        transitioning = true
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Metrics.stepFade / 2
            content.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                guard generation == self.generation else { return }
                swap()
                self.transitioning = false
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = Metrics.stepFade / 2
                    self.content.animator().alphaValue = 1
                }
            }
        })
    }

    private func makeColumn(for step: Step) -> NSView {
        switch step {
        case .welcome:
            return column(icon: kiteIcon(), title: "Welcome to Kite.",
                          body: "Spaces, pinned tabs, the command bar and split view, the way Arc had them. With Claude built in.",
                          buttons: [primary("Get Started", #selector(next), id: "onboardingGetStarted")])
        case .access:
            if !accessRefreshed {
                accessRefreshed = true
                Task { @MainActor [weak self] in
                    await SystemAccess.refresh()
                    self?.refreshAccess()
                }
            }
            let statuses = SystemAccess.statuses()
            let buttons: [NSButton]
            if statuses.contains(where: { $0.0.canAsk && $0.1 == .notAsked }) {
                buttons = [primary("Allow All", #selector(requestAccess), id: "onboardingAllowAccess"),
                           secondary("Not Now", #selector(next), id: "onboardingNotNow")]
            } else if statuses.contains(where: { $0.1 == .off }) {
                buttons = [primary("Open System Settings", #selector(openAccessSettings), id: "onboardingOpenSettings"),
                           secondary("Continue", #selector(next), id: "onboardingContinue")]
            } else {
                buttons = [primary("Continue", #selector(next), id: "onboardingContinue")]
            }
            return column(icon: symbolIcon(size: 26, "lock.shield.fill"), title: "Allow Kite once.",
                          body: "macOS asks about each of these one time, so nothing interrupts you later. Sites still ask you before they use any of it.",
                          extra: accessRows(statuses), buttons: buttons)
        case .claude:
            let copy = primary("Copy Prompt for Claude", #selector(copyPrompt), id: "onboardingCopyPrompt")
            copyButton = copy
            return column(icon: ClaudeMarkIcon(), title: "Set Kite up with Claude.",
                          body: "Paste this prompt into Claude Code or the Claude app. Claude connects itself to Kite and walks you through the rest, asking before it changes anything.",
                          extra: promptPreview(),
                          buttons: [copy, secondary("Continue", #selector(next), id: "onboardingContinue")])
        case .done:
            let arc = Self.arcDataExists
            let others = Self.otherBrowsers
            // The first import offered is the primary button; Start Browsing is when there's none.
            var imports = [(title: String, action: Selector, id: String)]()
            if arc { imports.append(("Import from Arc…", #selector(importArc), "onboardingImportFromArc")) }
            if !others.isEmpty {
                let title = others.count == 1 ? "Import from \(others[0].title)…" : "Import from Another Browser…"
                imports.append((title, #selector(importOtherBrowser), "onboardingImportFromBrowser"))
            }
            var buttons = imports.enumerated().map { index, item in
                index == 0 ? primary(item.title, item.action, id: item.id) : secondary(item.title, item.action, id: item.id)
            }
            buttons.append(imports.isEmpty ? primary("Start Browsing", #selector(finish), id: "onboardingStartBrowsing")
                                           : secondary("Start Browsing", #selector(finish), id: "onboardingStartBrowsing"))
            let body: String
            if arc {
                body = others.isEmpty
                    ? "Bring your spaces, pinned tabs, favorites and history over from Arc."
                    : "Bring your spaces, pinned tabs, favorites and history over from Arc, or bookmarks and history from \(Self.list(others.map(\.title)))."
            } else if !others.isEmpty {
                body = "Bring your bookmarks and history over from \(Self.list(others.map(\.title))). They become pinned tabs in a space of their own."
            } else {
                body = "Press ⌘T to open your first tab. Getting Started is in the Help menu if you want this again."
            }
            return column(icon: kiteIcon(), title: imports.isEmpty ? "You're all set." : "Bring your browser with you.",
                          body: imports.isEmpty ? body : body + " You can also do it later from the menu bar.",
                          buttons: buttons)
        }
    }

    /// "Chrome", "Chrome and Safari", "Chrome, Firefox and Safari".
    private static func list(_ names: [String]) -> String {
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
    }

    /// Every permission, each with what macOS says about Kite and what Kite uses it for (its tooltip).
    private func accessRows(_ statuses: [(SystemAccess.Permission, SystemAccess.Status)]) -> NSView {
        let rows = NSStackView()
        rows.orientation = .vertical
        rows.spacing = 0
        rows.wantsLayer = true
        rows.layer?.cornerRadius = 10
        rows.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        rows.layer?.borderWidth = 1
        rows.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        rows.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
        for (permission, status) in statuses {
            let symbol = NSImageView(image: NSImage(systemSymbolName: permission.symbol, accessibilityDescription: nil) ?? NSImage())
            symbol.contentTintColor = NSColor.white.withAlphaComponent(0.8)
            symbol.widthAnchor.constraint(equalToConstant: 20).isActive = true
            let name = NSTextField(labelWithString: permission.title)
            name.font = .systemFont(ofSize: 13, weight: .medium)
            name.textColor = .white
            let state = NSTextField(labelWithString: {
                switch status {
                case .allowed: "Allowed ✓"
                case .notAsked: "Not asked yet"
                case .off: permission == .fullDiskAccess ? "Turn on in System Settings" : "Off in System Settings"
                }
            }())
            state.font = .systemFont(ofSize: 13)
            state.textColor = status == .allowed ? NSColor.systemGreen : NSColor.white.withAlphaComponent(status == .off ? 0.9 : 0.55)
            state.setAccessibilityIdentifier("onboarding\(permission.title.replacingOccurrences(of: " ", with: ""))Status")
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let row = NSStackView(views: [symbol, name, spacer, state])
            row.orientation = .horizontal
            row.spacing = 10
            row.toolTip = permission.purpose
            row.heightAnchor.constraint(equalToConstant: 30).isActive = true
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor, constant: -28).isActive = true
        }
        return rows
    }

    /// SF Symbols side by side, in white, where the other steps have an icon.
    private func symbolIcon(size: CGFloat = 34, _ names: String...) -> NSView {
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        let views = names.map { name -> NSView in
            let view = NSImageView(image: NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) ?? NSImage())
            view.contentTintColor = .white
            return view
        }
        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.spacing = 18
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.image)
        row.setAccessibilityLabel(names.joined(separator: ", "))
        row.heightAnchor.constraint(equalToConstant: size == 34 ? Metrics.iconSide + 16 : size * 1.6).isActive = true
        return row
    }

    private func column(icon: NSView, title: String, body: String, extra: NSView? = nil, buttons: [NSButton]) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: Metrics.titleSize, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.alignment = .center
        titleLabel.setAccessibilityIdentifier("onboardingTitle")

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = .systemFont(ofSize: Metrics.bodySize)
        bodyLabel.textColor = NSColor.white.withAlphaComponent(0.72)
        bodyLabel.alignment = .center
        bodyLabel.preferredMaxLayoutWidth = Metrics.columnWidth

        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .vertical
        buttonRow.spacing = 10

        var views: [NSView] = [icon, titleLabel, bodyLabel]
        if let extra { views.append(extra) }
        views.append(buttonRow)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.setCustomSpacing(22, after: icon)
        stack.setCustomSpacing(26, after: extra ?? bodyLabel)
        bodyLabel.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        extra?.widthAnchor.constraint(equalToConstant: Metrics.columnWidth).isActive = true
        return stack
    }

    private func kiteIcon() -> NSView {
        let view = NSImageView(image: Self.icon)
        view.imageScaling = .scaleProportionallyUpOrDown
        view.setAccessibilityLabel("Kite")
        NSLayoutConstraint.activate([view.widthAnchor.constraint(equalToConstant: Metrics.iconSide + 16),
                                     view.heightAnchor.constraint(equalToConstant: Metrics.iconSide + 16)])
        return view
    }

    /// Kite's icon; a dev build has no bundle icon, so it reads the repo's.
    private static let icon: NSImage = (Bundle.main.bundleURL.pathExtension == "app" ? NSApp.applicationIconImage : nil)
        ?? resource("AppIcon", "icns").flatMap(NSImage.init(contentsOf:)) ?? NSImage()

    /// The step's main button, which Return presses.
    private func primary(_ title: String, _ action: Selector, id: String) -> OnboardingButton {
        let button = OnboardingButton(title: title, primary: true)
        button.target = self
        button.action = action
        button.keyEquivalent = "\r"
        button.setAccessibilityIdentifier(id)
        return button
    }

    private func secondary(_ title: String, _ action: Selector, id: String) -> OnboardingButton {
        let button = OnboardingButton(title: title, primary: false)
        button.target = self
        button.action = action
        button.setAccessibilityIdentifier(id)
        return button
    }

    /// The prompt's first lines, so it's clear what gets copied.
    private func promptPreview() -> NSView {
        let box = NSView()
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.22).cgColor
        box.layer?.borderWidth = 1
        box.layer?.borderColor = NSColor.white.withAlphaComponent(0.12).cgColor
        // Its opening request; the guide follows it on the clipboard.
        let request = Self.prompt.components(separatedBy: "\n\n").first ?? ""
        let text = NSTextField(wrappingLabelWithString: request)
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        text.font = font
        text.textColor = NSColor.white.withAlphaComponent(0.8)
        text.maximumNumberOfLines = Metrics.previewLines
        text.lineBreakMode = .byWordWrapping
        text.cell?.truncatesLastVisibleLine = true
        text.setAccessibilityIdentifier("onboardingPromptPreview")
        text.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(text)
        NSLayoutConstraint.activate([
            text.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            text.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            text.topAnchor.constraint(equalTo: box.topAnchor, constant: 11),
            text.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -11),
            text.heightAnchor.constraint(equalToConstant: ceil(NSLayoutManager().defaultLineHeight(for: font)) * CGFloat(Metrics.previewLines)),
        ])
        return box
    }

    // MARK: The prompt

    /// The setup prompt with SETUP.md inside it, and the path of this Kite's kite tool. Read once.
    static let prompt: String = {
        let kite = AutomationController.cliPath
        var prompt = guideURL().flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .map { ClaudeSetupPrompt.withGuide($0, kite: kite) }
            ?? ClaudeSetupPrompt.pointingAt(guidePath: ClaudeSetupPrompt.guideOnGitHub, kite: kite)
        // A test build: Claude's kite commands need the same profile to find this Kite.
        if let profile = ProcessInfo.processInfo.environment["KITE_SUPPORT_PATH"] {
            prompt += "\n\n(This Kite runs on a test profile: run kite commands with KITE_SUPPORT_PATH=\(profile).)"
        }
        return prompt
    }()

    private static func guideURL() -> URL? { resource("SETUP", "md") }

    /// A file in Kite.app's Contents/Resources; a dev build (.build/debug/Kite) finds the repo's Resources.
    private static func resource(_ name: String, _ type: String) -> URL? {
        if let url = Bundle.main.url(forResource: name, withExtension: type) { return url }
        var dir = Bundle.main.executableURL?.deletingLastPathComponent()
        for _ in 0..<5 {
            guard let current = dir else { break }
            let candidate = current.appendingPathComponent("Resources/\(name).\(type)")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            dir = current.deletingLastPathComponent()
        }
        return nil
    }

    /// Arc's sidebar file is where the importer looks for it (checked, never read, here). A test profile
    /// offers the import only from KITE_ARC_DATA_PATH's hand-made files, never the user's Arc.
    private static var arcDataExists: Bool {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, environment["KITE_ARC_DATA_PATH"] == nil { return false }
        return FileManager.default.fileExists(atPath: ArcImportController.arcDirectory.appendingPathComponent("StorableSidebar.json").path)
    }

    /// The other browsers Import from Another Browser… finds on this Mac. A test profile only sees
    /// KITE_BROWSER_DATA_PATH's hand-made ones, never the user's.
    private static var otherBrowsers: [ImportBrowser] {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, environment["KITE_BROWSER_DATA_PATH"] == nil { return [] }
        return BrowserImportController.installed().map(\.browser)
    }

    // MARK: Actions

    @objc private func next() { go(to: step.rawValue + 1, animated: true) }

    @objc private func back() { go(to: step.rawValue - 1, animated: true) }

    /// macOS's prompt for each permission it hasn't been asked about, one after the other; the step
    /// then shows the answers.
    @objc private func requestAccess() {
        guard !transitioning else { return }
        // A test run never puts a system prompt on the user's screen.
        if UIDiagnostics.enabledByEnvironment {
            let asked = SystemAccess.statuses().filter { $0.0.canAsk && $0.1 == .notAsked }.map(\.0.title)
            NSLog("Kite: diagnostics: would ask macOS for %@", asked.joined(separator: ", "))
            return
        }
        Task { @MainActor in
            await SystemAccess.requestAll()
            refreshAccess()
        }
    }

    /// System Settings at the first permission that's off.
    @objc private func openAccessSettings() {
        guard !transitioning, let permission = SystemAccess.Permission.allCases.first(where: { SystemAccess.status($0) == .off })
        else { return }
        if UIDiagnostics.enabledByEnvironment {
            NSLog("Kite: diagnostics: would open System Settings at %@", permission.title)
            return
        }
        SystemAccess.openSettings(permission)
    }

    /// Re-reads macOS's answers and redraws the access step in place, if it's the one showing.
    private func refreshAccess() {
        guard step == .access, !transitioning else { return }
        Task { @MainActor [weak self] in
            await SystemAccess.refresh()
            guard let self, step == .access, !transitioning else { return }
            go(to: Step.access.rawValue, animated: false)
        }
    }

    @objc private func copyPrompt() {
        guard !transitioning else { return }
        // The general pasteboard, or KITE_TEST_PASTEBOARD's on a test profile. A diagnostics run never
        // writes the user's clipboard, named pasteboard or not.
        var pasteboard = BrowserWindowController.capturePasteboard
        if UIDiagnostics.enabledByEnvironment, pasteboard == .general {
            pasteboard = NSPasteboard(name: NSPasteboard.Name("dev.gabek.Kite.onboarding-test"))
        }
        pasteboard.clearContents()
        pasteboard.setString(Self.prompt, forType: .string)
        copyButton?.title = "Copied ✓"
        if let copyButton {
            NSAccessibility.post(element: copyButton, notification: .announcementRequested,
                                 userInfo: [.announcement: "Prompt copied", .priority: NSAccessibilityPriorityLevel.high.rawValue])
        }
        copiedReset?.cancel()
        let reset = DispatchWorkItem { [weak self] in self?.copyButton?.title = "Copy Prompt for Claude" }
        copiedReset = reset
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: reset)
    }

    @objc private func finish() {
        guard !transitioning else { return }
        // Onboarding is never the last window: closing it would quit Kite.
        _ = browser()
        complete()
        window.close()
    }

    @objc private func importArc() {
        guard !transitioning, let controller = browser(), let browserWindow = controller.window else { return }
        complete()
        window.close()
        // An importer already up (from the File menu) isn't started twice.
        guard browserWindow.attachedSheet == nil else { return }
        // The next turn, once onboarding is gone, so the importer's sheet is the only thing up.
        DispatchQueue.main.async {
            WindowPresenter.show(browserWindow)
            controller.importFromArc(nil)
        }
    }

    @objc private func importOtherBrowser() {
        guard !transitioning, let controller = browser(), let browserWindow = controller.window else { return }
        complete()
        window.close()
        guard browserWindow.attachedSheet == nil else { return }
        DispatchQueue.main.async {
            WindowPresenter.show(browserWindow)
            controller.importFromAnotherBrowser(nil)
        }
    }

    /// Done with onboarding: it doesn't come back at launch.
    private func complete() {
        Onboarding.save(.init(completed: true), to: Self.stateURL)
    }

    /// The close button or ⌘W: the user closed onboarding, which counts as done. Quitting Kite
    /// closes the window without asking here, so it leaves onboarding unfinished and it resumes.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        complete()
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if let menuObserver { NotificationCenter.default.removeObserver(menuObserver) }
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        copiedReset?.cancel()
        Self.shown = nil
    }
}

/// Saturated, grainy backdrop in Kite's own colours (the icon's navy and blue), in the place of Arc's
/// blue `static-bg.png`.
private final class OnboardingBackdrop: NSView {
    private let gradient = CAGradientLayer()
    private let glow = CAGradientLayer()
    private let grain = CALayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor(srgbRed: 0x0B / 255, green: 0x18 / 255, blue: 0x30 / 255, alpha: 1).cgColor
        gradient.colors = [NSColor(srgbRed: 0x1A / 255, green: 0x3A / 255, blue: 0x8C / 255, alpha: 1).cgColor,
                           NSColor(srgbRed: 0x0B / 255, green: 0x18 / 255, blue: 0x30 / 255, alpha: 1).cgColor]
        gradient.startPoint = CGPoint(x: 0, y: 1)
        gradient.endPoint = CGPoint(x: 1, y: 0)
        glow.type = .radial
        glow.colors = [NSColor(srgbRed: 0x42 / 255, green: 0x8B / 255, blue: 0xFF / 255, alpha: 0.55).cgColor,
                       NSColor(srgbRed: 0x42 / 255, green: 0x8B / 255, blue: 0xFF / 255, alpha: 0).cgColor]
        glow.startPoint = CGPoint(x: 0.7, y: 0.25)
        glow.endPoint = CGPoint(x: 1.25, y: 0.95)
        // Tiled at one image pixel per screen pixel, so the grain stays even at any window size.
        if let image = Self.grainImage {
            grain.backgroundColor = NSColor(patternImage: NSImage(cgImage: image, size: NSSize(width: 128, height: 128))).cgColor
        }
        grain.opacity = 0.05
        layer?.addSublayer(gradient)
        layer?.addSublayer(glow)
        layer?.addSublayer(grain)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for sublayer in [gradient, glow, grain] { sublayer.frame = bounds }
        CATransaction.commit()
    }

    /// Fixed-seed noise, made once.
    private static let grainImage: CGImage? = {
        let side = 256
        var state: UInt32 = 0x2545F491
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5
            pixels[i] = UInt8(truncatingIfNeeded: state)
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: side,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }()
}

/// A white pill (primary) or a translucent one (secondary).
private final class OnboardingButton: NSButton {
    private let primary: Bool

    init(title: String, primary: Bool) {
        self.primary = primary
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.cornerRadius = OnboardingWindow.Metrics.buttonHeight / 2
        layer?.backgroundColor = primary ? NSColor.white.cgColor : NSColor.white.withAlphaComponent(0.12).cgColor
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([heightAnchor.constraint(equalToConstant: OnboardingWindow.Metrics.buttonHeight),
                                     widthAnchor.constraint(equalToConstant: 260)])
        applyTitle()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var title: String { didSet { applyTitle() } }

    private func applyTitle() {
        let color = primary ? NSColor(srgbRed: 0x0B / 255, green: 0x18 / 255, blue: 0x30 / 255, alpha: 1) : NSColor.white
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold), .foregroundColor: color, .paragraphStyle: style,
        ])
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class OnboardingTextButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        isBordered = false
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white.withAlphaComponent(0.7),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        UIDiagnostics.enabledByEnvironment || super.acceptsFirstMouse(for: event)
    }
}

/// Claude's real mark (`ClaudeMark`, the logo's own path) in Claude's orange, never a drawn stand-in.
private final class ClaudeMarkIcon: NSView {
    private let mark = CAShapeLayer()
    private static let side = OnboardingWindow.Metrics.iconSide

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        mark.fillColor = NSColor.claude.cgColor
        layer?.addSublayer(mark)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Claude")
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([widthAnchor.constraint(equalToConstant: Self.side + 16),
                                     heightAnchor.constraint(equalToConstant: Self.side + 16)])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = Self.side
        mark.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        mark.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // The shape's own y runs down; the layer's runs up.
        var flip = CGAffineTransform(translationX: 0, y: side).scaledBy(x: 1, y: -1)
        mark.path = ClaudeMark().path(in: CGRect(x: 0, y: 0, width: side, height: side)).cgPath.copy(using: &flip)
        CATransaction.commit()
    }
}

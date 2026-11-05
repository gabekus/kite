import Foundation
import Testing
@testable import KiteCore

/// SidebarTestHook: the icon picker, Create a Space and its theme editor for headless reference captures.
struct SidebarTestHookTests {
    private let picker = ["KITE_TEST_ICON_PICKER": "Personal"]
    private let page = ["KITE_TEST_NEW_SPACE": "1"]

    @Test func aRealProfileIgnoresEveryHook() {
        // No KITE_SUPPORT_PATH, or no KITE_DIAGNOSTICS: not test-safe, so nothing opens.
        for environment in [["KITE_DIAGNOSTICS": "1"], ["KITE_SUPPORT_PATH": "/tmp/k.abcd"], [:]] {
            let safe = WindowPresentation.isTestSafe(environment: environment)
            #expect(!safe)
            for hook in [picker, page, page.merging(["KITE_TEST_NEW_SPACE_NAME": "Reading", "KITE_TEST_NEW_SPACE_THEME": "4"]) { $1 }] {
                #expect(SidebarTestHook.from(environment: environment.merging(hook) { $1 }, testSafe: safe) == nil)
            }
        }
    }

    @Test func aTestSafeRunTakesExactValues() {
        let safe = WindowPresentation.isTestSafe(environment: ["KITE_DIAGNOSTICS": "1", "KITE_SUPPORT_PATH": "/tmp/k.abcd"])
        #expect(safe)
        #expect(SidebarTestHook.from(environment: picker, testSafe: safe) == .iconPicker(space: "Personal"))
        #expect(SidebarTestHook.from(environment: page, testSafe: safe) == .newSpace(name: nil, preset: nil))
        let filled = page.merging(["KITE_TEST_NEW_SPACE_NAME": "Reading list", "KITE_TEST_NEW_SPACE_THEME": "4"]) { $1 }
        #expect(SidebarTestHook.from(environment: filled, testSafe: safe) == .newSpace(name: "Reading list", preset: 3))
    }

    @Test func theFlagIsExactlyOneAndThePresetOneOfSeven() {
        for value in ["", "0", "true", " 1", "1 ", "11"] {
            #expect(SidebarTestHook.from(environment: ["KITE_TEST_NEW_SPACE": value], testSafe: true) == nil, "\(value)")
        }
        #expect(Theme.presets.count == 7)
        for value in ["1", "2", "3", "4", "5", "6", "7"] {
            #expect(SidebarTestHook.presetIndex(value) == Int(value)! - 1, "\(value)")
        }
        for value in ["", "0", "8", "01", " 4", "4 ", "+4", "4.0", "four"] {
            #expect(SidebarTestHook.presetIndex(value) == nil, "\(value)")
            #expect(SidebarTestHook.from(environment: page.merging(["KITE_TEST_NEW_SPACE_THEME": value]) { $1 }, testSafe: true) == nil, "\(value)")
        }
    }

    @Test func aNameOrTextIsOneShortLine() {
        for bad in ["", "a\nb", "a\tb", "\u{1B}", "a\u{2028}b", "\u{F700}", String(repeating: "x", count: 101)] {
            #expect(SidebarTestHook.refusal(bad) != nil, "\(bad.debugDescription)")
            #expect(SidebarTestHook.from(environment: ["KITE_TEST_ICON_PICKER": bad], testSafe: true) == nil, "\(bad.debugDescription)")
            #expect(SidebarTestHook.from(environment: page.merging(["KITE_TEST_NEW_SPACE_NAME": bad]) { $1 }, testSafe: true) == nil,
                    "\(bad.debugDescription)")
        }
    }

    @Test func oneStateARunAndNoValuesWithoutThePage() {
        // The picker beside the page, or the page's values without the page: no hook at all.
        #expect(SidebarTestHook.from(environment: picker.merging(page) { $1 }, testSafe: true) == nil)
        #expect(SidebarTestHook.from(environment: picker.merging(["KITE_TEST_NEW_SPACE_NAME": "x"]) { $1 }, testSafe: true) == nil)
        #expect(SidebarTestHook.from(environment: ["KITE_TEST_NEW_SPACE_NAME": "Reading"], testSafe: true) == nil)
        #expect(SidebarTestHook.from(environment: ["KITE_TEST_NEW_SPACE_THEME": "4"], testSafe: true) == nil)
        #expect(SidebarTestHook.refusedLine(["KITE_TEST_NEW_SPACE_THEME": "4"])?.hasPrefix("KITE_TEST_SIDEBAR: refused") == true)
        #expect(SidebarTestHook.refusedLine([:]) == nil)
    }

    @Test func thePickersSpaceIsTheOneWithThatName() {
        var state = BrowserState(spaces: [Space(name: "Personal", icon: "🏠", theme: Theme.presets[0]),
                                          Space(name: "Work", icon: "symbol:briefcase", theme: Theme.presets[1])])
        #expect(SidebarTestHook.space(named: "Work", in: state) == state.spaces[1].id)
        #expect(SidebarTestHook.space(named: "work", in: state) == nil)   // exactly
        #expect(SidebarTestHook.space(named: "Reading", in: state) == nil)
        state.spaces.append(Space(name: "Work", icon: "", theme: Theme.presets[2]))
        #expect(SidebarTestHook.space(named: "Work", in: state) == nil)   // two: neither
    }

    @Test func thePresetIsPickedAsTheSwatchPicksIt() {
        // ThemeEditor.presets: the preset's colours and grain, the space's intensity kept.
        var current = Theme.presets[0]
        current.tint = 0.3
        let picked = SidebarTestHook.theme(current, picking: 3)
        #expect(picked.colors == Theme.presets[3].colors)
        #expect(picked.grain == Theme.presets[3].grain)
        #expect(picked.tint == 0.3)
    }

    private let behind = SidebarTestHook.Shown(appActive: false, popover: .init(key: false, level: 0, parentIsMainWindow: true))

    @Test func itsLinesSayWhenTheStateIsUpAndWhereItWent() {
        // The capture script waits for "KITE_TEST_SIDEBAR: ready", then reads the run's facts that start it.
        #expect(SidebarTestHook.iconPicker(space: "Personal").readyLine(behind)
            == "KITE_TEST_SIDEBAR: ready: app active no; popover key no, level 0, parent the main window; icon picker for \"Personal\"")
        #expect(SidebarTestHook.newSpace(name: nil, preset: nil).readyLine(.init(appActive: false, popover: nil))
            == "KITE_TEST_SIDEBAR: ready: app active no; no popover; Create a Space")
        #expect(SidebarTestHook.newSpace(name: "Reading list", preset: 3).readyLine(
            .init(appActive: true, popover: .init(key: true, level: 101, parentIsMainWindow: false)))
            == "KITE_TEST_SIDEBAR: ready: app active yes; popover key yes, level 101, parent not the main window; "
            + "Create a Space, name \"Reading list\", preset 4, theme editor open")
        for hook in [SidebarTestHook.iconPicker(space: "x"), .newSpace(name: "y", preset: 0)] {
            #expect(!hook.armedLine.contains("ready"))
            #expect(!hook.failedLine("why").contains("ready"))
            #expect(hook.changedLine("why").hasPrefix("KITE_TEST_SIDEBAR: changed: "))
        }
    }

    // MARK: The Mac's runner, read from its sources (they don't build here).

    private static let mac = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/KiteMac")

    /// With LF line ends: a Windows checkout (Windows CI runs these too) has CRLF.
    private func source(_ path: String) throws -> String {
        try String(contentsOf: Self.mac.appendingPathComponent(path), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    @Test func theRunnerRunsOnTestSafeRunsOnlyAndClicksNothing() throws {
        let runner = try source("Diagnostics/SidebarTestHookRunner.swift")
        #expect(runner.contains("""
                static func start(in controller: BrowserWindowController,
                                  environment: [String: String] = ProcessInfo.processInfo.environment) {
                    guard WindowPresenter.testSafe else { return }
            """))
        // The paths a click takes, without the click: no events, no pointer, nothing fronted or activated.
        #expect(runner.contains("store.requestIconPicker(space: id)"))
        // A main window gone before the timer is a failed line, not silence; ready reports where the popover went
        // and whether Kite is active, and the watch goes on after it.
        #expect(runner.contains("return log(hook.failedLine(\"the main window went before the hook ran\"))"))
        #expect(runner.contains("SidebarTestHook.Shown(appActive: NSApp.isActive, popover: popover.map { facts($0, main: main) })"))
        #expect(runner.contains("parentIsMainWindow: main != nil && window?.parent === main"))
        #expect(runner.contains("if NSApp.isActive { return log(hook.changedLine(\"Kite is the active app\")) }"))
        #expect(runner.contains("store.beginNewSpace()"))
        for banned in ["NSEvent", "sendEvent", "postEvent", "CGEvent", "makeKey", "orderFront", "activate(", "UIInputSender"] {
            #expect(!runner.contains(banned), "\(banned)")
        }
        #expect(try source("AppDelegate.swift").contains("SidebarTestHookRunner.start(in: windowController)"))
    }

    @Test func thePageTakesTheNameAsItsFieldsValueAndTheRowOpensTheEditor() throws {
        let view = try source("Views/SpaceCreationView.swift")
        #expect(view.contains("if let typed = SidebarTestHookRunner.typedName(for: creation.spaceID) { name = typed }"))
        #expect(view.contains("guard let hookAnchor, SidebarTestHookRunner.opensThemeEditor(for: spaceID) else { return }"))
        #expect(view.contains("ThemeEditor.present(store: store, spaceID: spaceID, from: hookAnchor, pointing: true)"))
        // Ready means shown: each says which popover is up, and shows it through WindowPresenter.
        for file in ["Views/SpaceIconPicker.swift", "Views/ThemeEditor.swift"] {
            let view = try source(file)
            #expect(view.contains("@MainActor static var current: NSPopover? { shown?.isShown == true ? shown : nil }"), "\(file)")
            #expect(view.contains("WindowPresenter.show(popover, relativeTo: "), "\(file)")
            #expect(!view.contains("popover.show("), "\(file)")
        }
    }

    @Test func kitesLineComesInsideTheScriptsWait() throws {
        // The script waits SIDEBAR_READY_SECONDS once Kite's socket answers; Kite's runner starts a second after the
        // window is up and gives up readyTimeout later, so its ready (or failed) line must come with room to spare.
        let script = try String(contentsOf: Self.mac.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/mac-reference-captures.sh"), encoding: .utf8)
        let line = try #require(script.split(whereSeparator: \.isNewline).first { $0.hasPrefix("SIDEBAR_READY_SECONDS=") })
        let seconds = try #require(Double(line.dropFirst("SIDEBAR_READY_SECONDS=".count)))
        #expect(1 + SidebarTestHook.readyTimeout + 5 <= seconds)
        // And it allows exactly the hook's keys, presets 1-7 and nothing else.
        for key in SidebarTestHook.keys { #expect(script.contains("\"\(key)\": "), "\(key)") }
        #expect(script.contains(#""KITE_TEST_NEW_SPACE_THEME": ("1", "2", "3", "4", "5", "6", "7"),"#))
    }

    // MARK: The capture script's reading of the ready line, and its planner (scripts/mac-reference-captures.sh).

    private func script() throws -> String {
        try String(contentsOf: Self.mac.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/mac-reference-captures.sh"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    /// SIDEBAR_READY_OK, the ERE bash's =~ matches the ready line against.
    private func readyOK() throws -> String {
        let line = try #require(try script().split(separator: "\n").first { $0.hasPrefix("SIDEBAR_READY_OK='") })
        return String(line.dropFirst("SIDEBAR_READY_OK='".count).dropLast())
    }

    @Test func theScriptCapturesOnlyABackgroundRunsState() throws {
        let pattern = try readyOK()
        let regex = try NSRegularExpression(pattern: pattern)
        func passes(_ line: String) -> Bool {
            regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil
        }
        let picker = SidebarTestHook.iconPicker(space: "Personal"), page = SidebarTestHook.newSpace(name: "Reading list", preset: nil)
        let theme = SidebarTestHook.newSpace(name: "Reading list", preset: 3)
        let child = SidebarTestHook.Shown.Popover(key: false, level: 0, parentIsMainWindow: true)
        // Kite in the background, the popover the main window's child (key or not), or no popover: captured.
        #expect(passes(picker.readyLine(.init(appActive: false, popover: child))))
        #expect(passes(theme.readyLine(.init(appActive: false, popover: .init(key: true, level: 101, parentIsMainWindow: true)))))
        #expect(passes(page.readyLine(.init(appActive: false, popover: nil))))
        // Kite active, or a popover that isn't the main window's child: refused, whatever the rest says.
        #expect(!passes(picker.readyLine(.init(appActive: true, popover: child))))
        #expect(!passes(page.readyLine(.init(appActive: true, popover: nil))))
        #expect(!passes(theme.readyLine(.init(appActive: false, popover: .init(key: false, level: 0, parentIsMainWindow: false)))))
        // A name can't stand in for the facts: they come first.
        let spoof = SidebarTestHook.iconPicker(space: "app active no; no popover; x")
        #expect(!passes(spoof.readyLine(.init(appActive: true, popover: nil))))
        // And the other lines never pass.
        #expect(!passes(picker.armedLine) && !passes(picker.failedLine("x")) && !passes(picker.changedLine("x")))
        #if os(macOS)
        // Bash's own =~, as the script runs it.
        func bash(_ line: String) throws -> Bool {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/bash")
            process.arguments = ["-c", #"[[ "$1" =~ $2 ]]"#, "bash", line, pattern]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        }
        #expect(try bash(picker.readyLine(.init(appActive: false, popover: child))))
        #expect(try bash(page.readyLine(.init(appActive: false, popover: nil))))
        #expect(try !bash(picker.readyLine(.init(appActive: true, popover: child))))
        #expect(try !bash(theme.readyLine(.init(appActive: false, popover: .init(key: false, level: 0, parentIsMainWindow: false)))))
        #endif
    }

    #if os(macOS)
    /// Runs the script's planner (its first python heredoc) on a one-state request with this env and steps, every
    /// floor HEAD; nil when it plans it, else its refusal.
    private func plan(_ env: [String: String], steps: [[String: Any]] = []) throws -> String? {
        let text = try script()
        let opening = try #require(text.range(of: "\"$SIDEBAR_FLOOR\" <<'PY'\n"))
        let closing = try #require(text.range(of: "\nPY\n", range: opening.upperBound..<text.endIndex))
        let planner = String(text[opening.upperBound..<closing.lowerBound])
        let root = Self.mac.deletingLastPathComponent().deletingLastPathComponent()
        let session = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("windows/helix/states/three-spaces.json")))
        var state: [String: Any] = ["name": "s", "env": env]
        if !steps.isEmpty { state["steps"] = steps }
        let request: [String: Any] = ["id": "t", "session": ["inline": session], "states": [state]]
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("sidebar-plan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("plan"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try JSONSerialization.data(withJSONObject: request).write(to: folder.appendingPathComponent("request.json"))
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-", folder.appendingPathComponent("request.json").path,
                             folder.appendingPathComponent("plan").path, root.path, "SpaceCellView NewTabRowCell"]
            + Array(repeating: "HEAD", count: 5)   // TEXT, FIND, HIT, EXPECT and SIDEBAR floors: all in HEAD
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        try process.run()
        input.fileHandleForWriting.write(Data(planner.utf8))
        try input.fileHandleForWriting.close()
        let said = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : said
    }

    @Test func theScriptRefusesHostileSidebarRequests() throws {
        // What the hooks are for: planned.
        #expect(try plan(["KITE_TEST_ICON_PICKER": "Work"]) == nil)
        #expect(try plan(["KITE_TEST_NEW_SPACE": "1"]) == nil)
        #expect(try plan(["KITE_TEST_NEW_SPACE": "1", "KITE_TEST_NEW_SPACE_NAME": "Reading list", "KITE_TEST_NEW_SPACE_THEME": "4"]) == nil)
        #expect(try plan(["KITE_TEST_NEW_SPACE": "1"], steps: [["wait": 1]]) == nil)
        // Beside any other hook, each allowed on its own: refused.
        let others = ["KITE_TEST_CONTEXT_MENU": "1", "KITE_TEST_OPEN_URL": "https://example.com/", "KITE_TEST_ZAP_PICKER": "1",
                      "KITE_TEST_BOOST_MENU": "x", "KITE_TEST_REOPEN_MAIN_AFTER": "1", "KITE_TEST_ASSUME_VISIBLE": "1",
                      "KITE_TEST_TIDY_TITLE": "x", "KITE_TEST_LITTLE_PROFILE_PICK": "x", "KITE_TEST_LITTLE_EXTENSIONS_BUTTON": "1",
                      "KITE_TEST_EXPORT_DATA_PATH": "export.json", "KITE_TEST_FIND_OPEN": "1", "KITE_TEST_FIND": "domain"]
        for (key, value) in others {
            for hook in [["KITE_TEST_ICON_PICKER": "Work"], ["KITE_TEST_NEW_SPACE": "1"]] {
                let refusal = try plan(hook.merging([key: value]) { $1 })
                #expect(refusal?.contains("request.json refused") == true, "\(key) beside \(hook)")
            }
            #expect(try plan(["KITE_TEST_NEW_SPACE": "1"].merging([key: value]) { $1 })?.contains(key) == true, "\(key)")
        }
        // Not exact, mixed, the page's values alone, or with an input step: refused.
        for env in [["KITE_TEST_NEW_SPACE": "0"], ["KITE_TEST_NEW_SPACE": "true"], ["KITE_TEST_NEW_SPACE": " 1"],
                    ["KITE_TEST_NEW_SPACE": "1", "KITE_TEST_NEW_SPACE_THEME": "8"],
                    ["KITE_TEST_NEW_SPACE": "1", "KITE_TEST_NEW_SPACE_THEME": "04"],
                    ["KITE_TEST_NEW_SPACE": "1", "KITE_TEST_NEW_SPACE_NAME": "a\tb"],
                    ["KITE_TEST_NEW_SPACE": "1", "KITE_TEST_NEW_SPACE_NAME": "../x"],
                    ["KITE_TEST_NEW_SPACE": "1", "KITE_TEST_NEW_SPACE_NAME": " "],
                    ["KITE_TEST_ICON_PICKER": String(repeating: "x", count: 41)],
                    ["KITE_TEST_ICON_PICKER": "Work", "KITE_TEST_NEW_SPACE": "1"],
                    ["KITE_TEST_ICON_PICKER": "Work", "KITE_TEST_NEW_SPACE_NAME": "x"],
                    ["KITE_TEST_NEW_SPACE_NAME": "x"], ["KITE_TEST_NEW_SPACE_THEME": "4"]] {
            #expect(try plan(env)?.contains("request.json refused") == true, "\(env)")
        }
        let click: [String: Any] = ["ui": "input", "args": ["click": [86, 795]]]
        #expect(try plan(["KITE_TEST_NEW_SPACE": "1"], steps: [click])?.contains("takes no input steps") == true)
        #expect(try plan(["KITE_TEST_ICON_PICKER": "Work"], steps: [["wait": 1], click])?.contains("takes no input steps") == true)
    }
    #endif

    @Test func anInProcessCaptureDrawsAnOpenPopover() throws {
        // The popovers are child windows: the in-process render draws them over the window, as on screen.
        let capture = try source("Diagnostics/UICapture.swift")
        #expect(capture.contains("for child in window.childWindows ?? [] where child.isVisible && NSStringFromClass(type(of: child)).contains(\"Popover\") {"))
    }
}

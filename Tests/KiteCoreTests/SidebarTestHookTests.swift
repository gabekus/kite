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

    @Test func anInProcessCaptureDrawsAnOpenPopover() throws {
        // The popovers are child windows: the in-process render draws them over the window, as on screen.
        let capture = try source("Diagnostics/UICapture.swift")
        #expect(capture.contains("for child in window.childWindows ?? [] where child.isVisible && NSStringFromClass(type(of: child)).contains(\"Popover\") {"))
    }
}

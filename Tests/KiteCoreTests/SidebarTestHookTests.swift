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

    @Test func itsLinesSayWhenTheStateIsUp() {
        // The capture script waits for "KITE_TEST_SIDEBAR: ready" before it captures.
        #expect(SidebarTestHook.iconPicker(space: "Personal").readyLine == "KITE_TEST_SIDEBAR: ready: icon picker for \"Personal\"")
        #expect(SidebarTestHook.newSpace(name: nil, preset: nil).readyLine == "KITE_TEST_SIDEBAR: ready: Create a Space")
        #expect(SidebarTestHook.newSpace(name: "Reading list", preset: 3).readyLine
            == "KITE_TEST_SIDEBAR: ready: Create a Space, name \"Reading list\", preset 4, theme editor open")
        for hook in [SidebarTestHook.iconPicker(space: "x"), .newSpace(name: "y", preset: 0)] {
            #expect(!hook.armedLine.contains("ready"))
            #expect(!hook.failedLine("why").contains("ready"))
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
        // Ready means shown: each popover says so.
        #expect(try source("Views/SpaceIconPicker.swift").contains("@MainActor static var isShown: Bool { shown?.isShown == true }"))
        #expect(try source("Views/ThemeEditor.swift").contains("@MainActor static var isShown: Bool { shown?.isShown == true }"))
    }

    @Test func anInProcessCaptureDrawsAnOpenPopover() throws {
        // The popovers are child windows: the in-process render draws them over the window, as on screen.
        let capture = try source("Diagnostics/UICapture.swift")
        #expect(capture.contains("for child in window.childWindows ?? [] where child.isVisible && NSStringFromClass(type(of: child)).contains(\"Popover\") {"))
    }
}

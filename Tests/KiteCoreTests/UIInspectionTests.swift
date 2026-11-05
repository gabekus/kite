import Foundation
import Testing
@testable import KiteCore

@Suite struct UIInspectionTests {
    private func ui(_ arguments: [String: JSONValue]) throws -> UIInspection {
        guard case .ui(let inspection) = try AutomationCommand(tool: "ui", arguments: .object(arguments)) else {
            Issue.record("not a ui command")
            return .windows
        }
        return inspection
    }

    @Test func parsesEachAction() throws {
        #expect(try ui(["action": "windows"]) == .windows)
        #expect(try ui(["action": "tree", "root": "0.3", "match": "Sidebar", "window": 42])
            == .tree(window: 42, root: "0.3", depth: UIInspection.defaultDepth, match: "Sidebar", layers: false,
                     maxNodes: UIInspection.defaultMaxNodes))
        #expect(try ui(["action": "menu", "match": "⌘L"]) == .menu(match: "⌘L"))
        #expect(try ui(["action": "key_log"]) == .keyLog(limit: 30, clear: false))
        let trace = try ui(["action": "trace", "keys": "cmd+s", "seconds": 0.5])
        #expect(trace == .trace(window: nil, seconds: 0.5, keys: [try KeyChord.parse("cmd+s")], match: nil))
        #expect(!trace.isReadOnly)
        #expect(try ui(["action": "trace"]).isReadOnly)
    }

    @Test func captureReturnsAnImageUnlessOnlyPixelsAreAsked() throws {
        #expect(try ui(["action": "capture", "region": [0, 0, 240, 100]])
            == .capture(window: nil, region: UIRect(x: 0, y: 0, width: 240, height: 100), format: .png, pixels: [], image: true, save: nil))
        #expect(try ui(["action": "capture", "pixels": [[10, 20], [11.5, 20]]])
            == .capture(window: nil, region: nil, format: .png, pixels: [UIPoint(x: 10, y: 20), UIPoint(x: 11.5, y: 20)],
                        image: false, save: nil))
        #expect(try ui(["action": "capture", "pixels": [[1, 1]], "image": true, "format": "jpeg"])
            == .capture(window: nil, region: nil, format: .jpeg, pixels: [UIPoint(x: 1, y: 1)], image: true, save: nil))
    }

    @Test func captureSourceDefaultsToAutoAndRejectsUnknownOnes() throws {
        #expect(try ui(["action": "capture"])
            == .capture(window: nil, region: nil, format: .png, pixels: [], image: true, save: nil, source: .auto))
        #expect(try ui(["action": "capture", "source": "in-process"])
            == .capture(window: nil, region: nil, format: .png, pixels: [], image: true, save: nil, source: .inProcess))
        #expect(try ui(["action": "capture", "source": "screen"])
            == .capture(window: nil, region: nil, format: .png, pixels: [], image: true, save: nil, source: .screen))
        #expect(throws: (any Error).self) { try ui(["action": "capture", "source": "window-server"]) }
    }

    @Test func pointerSweepsIncludeBothEnds() throws {
        guard case .pointer(_, let points, _) = try ui(["action": "pointer", "from": [-4, 100], "to": [4, 100], "steps": 8]) else {
            Issue.record("not a pointer sweep")
            return
        }
        #expect(points.count == 9)
        #expect(points.first == UIPoint(x: -4, y: 100))
        #expect(points.last == UIPoint(x: 4, y: 100))
        #expect(points[4] == UIPoint(x: 0, y: 100))
        #expect(try ui(["action": "pointer", "from": [5, 5]]) == .pointer(window: nil, points: [UIPoint(x: 5, y: 5)]))
        #expect(try ui(["action": "pointer", "from": [5, 5], "modifiers": "shift"])
            == .pointer(window: nil, points: [UIPoint(x: 5, y: 5)], modifiers: .shift))
    }

    @Test func inputTakesExactlyOneEvent() throws {
        #expect(try ui(["action": "input", "keys": "cmd+t Escape"])
            == .input(window: nil, event: .keys(try KeyChord.parseSequence("cmd+t Escape"))))
        #expect(try ui(["action": "input", "click": [20, 30], "count": 2, "modifiers": "cmd"])
            == .input(window: nil, event: .click(UIPoint(x: 20, y: 30), button: .left, count: 2, modifiers: .meta)))
        #expect(try ui(["action": "input", "scroll": [100, 200], "dy": -40])
            == .input(window: nil, event: .scroll(UIPoint(x: 100, y: 200), dx: 0, dy: -40)))
        #expect(try ui(["action": "input", "scroll": [100, 200], "dx": 300, "phase": "gesture", "steps": 12])
            == .input(window: nil, event: .phasedScroll(UIPoint(x: 100, y: 200), dx: 300, dy: 0, phase: .gesture, steps: 12)))
        #expect(try ui(["action": "input", "scroll": [100, 200], "phase": "ended"])
            == .input(window: nil, event: .phasedScroll(UIPoint(x: 100, y: 200), dx: 0, dy: 0, phase: .ended, steps: 10)))
        #expect(try ui(["action": "input", "flags": "ctrl"]) == .input(window: nil, event: .flags(.control)))
        #expect(try ui(["action": "input", "flags": "none"]) == .input(window: nil, event: .flags([])))
        #expect(throws: AutomationCommand.InvalidArguments.self) { try ui(["action": "input", "scroll": [1, 2], "phase": "wobble"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try ui(["action": "input"]) }
        #expect(throws: AutomationCommand.InvalidArguments.self) { try ui(["action": "input", "keys": "a", "text": "b"]) }
    }

    @Test func rejectsBadArguments() {
        for arguments: [String: JSONValue] in [
            [:], ["action": "draw"], ["action": "tree", "root": "sidebar"], ["action": "capture", "region": [0, 0, 0, 10]],
            ["action": "pointer"], ["action": "pointer", "points": [[1]]], ["action": "trace", "seconds": 60],
            ["action": "input", "keys": "hyper+x"],
        ] {
            #expect(throws: AutomationCommand.InvalidArguments.self, "\(arguments)") { try ui(arguments) }
        }
    }

    @Test func worksInsideABatch() throws {
        let command = try AutomationCommand(tool: "batch", arguments: ["steps": [
            ["tool": "ui", "arguments": ["action": "input", "keys": "cmd+s"]],
            ["tool": "ui", "arguments": ["action": "tree", "match": "Sidebar"]],
        ]])
        guard case .batch(let steps) = command else {
            Issue.record("not a batch")
            return
        }
        #expect(steps.count == 2)
        #expect(!AutomationCommand.Tool.ui.takesTab)
    }

    @Test func hitTakesOnePointAndIsReadOnly() throws {
        let hit = try ui(["action": "hit", "point": [120, 364.5], "window": 7])
        #expect(hit == .hit(window: 7, point: UIPoint(x: 120, y: 364.5)))
        #expect(hit.isReadOnly)
        #expect(UIInspection.actions.contains("hit"))
        #expect(throws: (any Error).self) { try ui(["action": "hit"]) }
        #expect(throws: (any Error).self) { try ui(["action": "hit", "point": [1]]) }
        #expect(throws: (any Error).self) { try ui(["action": "hit", "point": "120,364"]) }
    }
    @Test func inputTakesAnExpectationForAClickOrDragOnly() throws {
        let rowExpect: JSONValue = ["path": "0.3.3.0.5.1", "class": "TabRowCell", "inside": ["SymbolButton", "SidebarPassthroughView"]]
        let row = UIHitExpectation(path: "0.3.3.0.5.1", className: "TabRowCell", inside: ["SymbolButton", "SidebarPassthroughView"])
        let rightClick = UIInputEvent.click(UIPoint(x: 120, y: 364.5), button: .right, count: 1, modifiers: [])
        let parsedClick = try ui(["action": "input", "window": 7, "click": [120, 364.5], "button": "right", "expect": rowExpect])
        #expect(parsedClick == UIInspection.input(window: 7, event: rightClick, expect: row))

        let spaceExpect: JSONValue = ["path": "0.3.4.0.1", "class": "SpaceCellView"]
        let drag = UIInputEvent.drag(from: UIPoint(x: 86, y: 795), to: UIPoint(x: 150, y: 795), steps: 10)
        let parsedDrag = try ui(["action": "input", "from": [86, 795], "to": [150, 795], "expect": spaceExpect])
        #expect(parsedDrag == UIInspection.input(window: nil, event: drag, expect: UIHitExpectation(path: "0.3.4.0.1", className: "SpaceCellView")))

        // Without one, nothing changes.
        let leftClick = UIInputEvent.click(UIPoint(x: 1, y: 2), button: .left, count: 1, modifiers: [])
        let none: UIHitExpectation? = nil
        #expect(try ui(["action": "input", "click": [1, 2]]) == UIInspection.input(window: nil, event: leftClick, expect: none))

        // Not a press: nothing to hit-test.
        let expect: JSONValue = ["path": "0.3", "class": "NewTabRowCell"]
        let notPresses: [[String: JSONValue]] = [
            ["action": "input", "keys": "cmd+t", "expect": expect],
            ["action": "input", "text": "a", "expect": expect],
            ["action": "input", "scroll": [1, 2], "dy": 3, "expect": expect],
            ["action": "input", "flags": "ctrl", "expect": expect],
        ]
        for arguments in notPresses {
            #expect(throws: AutomationCommand.InvalidArguments.self, "\(arguments)") { try ui(arguments) }
        }
        // Malformed.
        let malformed: [JSONValue] = [
            "0.3",
            ["class": "NewTabRowCell"],
            ["path": "0.3"],
            ["path": "", "class": "A"],
            ["path": "0..3", "class": "A"],
            ["path": "0.3.", "class": "A"],
            ["path": "titlebar", "class": "A"],
            ["path": "0.3", "class": ""],
            ["path": "0.3", "class": "A", "inside": "B"],
            ["path": "0.3", "class": "A", "inside": [""]],
            ["path": "0.3", "class": "A", "window": 3],
        ]
        for bad in malformed {
            let arguments: [String: JSONValue] = ["action": "input", "click": [1, 2], "expect": bad]
            #expect(throws: AutomationCommand.InvalidArguments.self, "\(bad)") { try ui(arguments) }
        }
    }
}

@Suite struct UIReportTests {
    let tree = UINode(kind: "NSView", frame: UIRect(x: 0, y: 0, width: 1280, height: 820), children: [
        UINode(kind: "NSVisualEffectView", frame: UIRect(x: 0, y: 0, width: 1280, height: 820),
               attributes: [.init("material", "sidebar"), .init("blending", "behindWindow")]),
        UINode(kind: "NSHostingView<SidebarView>", frame: UIRect(x: 0, y: 0, width: 240, height: 820), children: [
            UINode(kind: "AXButton", identifier: "newTab", label: "New Tab", frame: UIRect(x: 8, y: 100.5, width: 224, height: 34)),
        ]),
    ])

    @Test func printsAnIndentedTreeWithPaths() {
        let text = UIReport.tree(tree, depth: 10, match: nil, maxNodes: 100)
        #expect(text.contains("0 NSView [0,0 1280×820]"))
        #expect(text.contains("  0.0 NSVisualEffectView [0,0 1280×820] material=sidebar blending=behindWindow"))
        #expect(text.contains("    0.1.0 AXButton #newTab \"New Tab\" [8,100.5 224×34]"))
        #expect(text.hasPrefix("<untrusted-page-content"))
    }

    @Test func matchListsNodesFlatAndRootPicksASubtree() {
        let matched = UIReport.tree(tree, depth: 10, match: "new tab", maxNodes: 100)
        #expect(matched.contains("\n0.1.0 AXButton"))
        #expect(!matched.contains("NSVisualEffectView"))
        let sub = tree.node(at: "0.1")
        #expect(sub?.kind == "NSHostingView<SidebarView>")
        #expect(tree.node(at: "0.5") == nil)
        #expect(tree.node(at: "1") == nil)
        let text = UIReport.tree(sub!, rootPath: "0.1", depth: 10, match: nil, maxNodes: 100)
        #expect(text.contains("  0.1.0 AXButton"))
    }

    @Test func depthAndNodeLimitsSaySoInsteadOfDroppingSilently() {
        let shallow = UIReport.tree(tree, depth: 1, match: nil, maxNodes: 100)
        #expect(shallow.contains("… 2 children (root 0 to see them)"))
        let few = UIReport.tree(tree, depth: 10, match: nil, maxNodes: 2)
        // The hosting view's own child counts too.
        #expect(few.contains("… 2 more nodes"))
        #expect(UIReport.tree(tree, depth: 1, match: nil, maxNodes: 10, source: "Arc window").hasPrefix("<untrusted-page-content source=\"Arc window\""))
    }

    @Test func numbersStayShort() {
        #expect(UIReport.number(240) == "240")
        #expect(UIReport.number(12.5) == "12.5")
        #expect(UIReport.number(0.333) == "0.33")
        #expect(UIReport.number(-4) == "-4")
    }

    @Test func menuFlagsShortcutsThatFireWhileTyping() {
        let items = [
            UIMenuItem(path: ["Edit", "Emoji & Symbols"], key: "e", modifiers: [], action: "orderFrontCharacterPalette:",
                       target: nil, identifier: nil, isEnabled: true, isHidden: false, isOn: false),
            UIMenuItem(path: ["Edit", "Emoji & Symbols (fn)"], key: "e", modifiers: ["fn"], action: "orderFrontCharacterPalette:",
                       target: nil, identifier: nil, isEnabled: true, isHidden: false, isOn: false),
            UIMenuItem(path: ["File", "New Tab"], key: "t", modifiers: ["cmd"], action: "newTab:", target: "MenuRouter",
                       identifier: "newTab", isEnabled: true, isHidden: false, isOn: false),
            UIMenuItem(path: ["View", "Toggle Sidebar"], key: "s", modifiers: ["cmd"], action: "toggleSidebar:", target: "MenuRouter",
                       identifier: nil, isEnabled: true, isHidden: false, isOn: false),
            UIMenuItem(path: ["Spaces", "Next Space"], key: "s", modifiers: ["cmd"], action: "nextSpace:", target: "MenuRouter",
                       identifier: nil, isEnabled: true, isHidden: false, isOn: false),
            UIMenuItem(path: ["History", "Back"], key: "\u{F702}", modifiers: ["cmd"], action: "goBack:", target: nil,
                       identifier: nil, isEnabled: false, isHidden: false, isOn: false),
            UIMenuItem(path: ["Edit", "Start Dictation"], key: "🎤", modifiers: [], action: "startDictation:", target: nil,
                       identifier: nil, isEnabled: true, isHidden: false, isOn: false),
            // Arc's Tabs menu repeats File › New Tab… ⌘T: same action, so not a conflict.
            UIMenuItem(path: ["Tabs", "New Tab…"], key: "t", modifiers: ["cmd"], action: "newTab:", target: "MenuRouter",
                       identifier: nil, isEnabled: true, isHidden: false, isOn: false),
        ]
        #expect(items[0].firesWhileTyping)
        // AppKit matches fn E on a plain "e".
        #expect(items[1].firesWhileTyping)
        #expect(!items[2].firesWhileTyping)
        #expect(!items[5].firesWhileTyping)
        #expect(!items[6].firesWhileTyping)
        #expect(items[5].shortcut == "⌘←")
        let text = UIReport.menu(items, match: nil)
        #expect(text.contains("Edit > Emoji & Symbols  E  orderFrontCharacterPalette: → responder chain  (FIRES WHILE TYPING)"))
        #expect(text.contains("File > New Tab  ⌘T  newTab: → MenuRouter  #newTab"))
        #expect(text.contains("History > Back  ⌘←  goBack: → responder chain  (disabled)"))
        #expect(text.contains("CONFLICT ⌘S: View > Toggle Sidebar wins over Spaces > Next Space"))
        #expect(!text.contains("CONFLICT ⌘T"))
        #expect(UIReport.menu(items, match: "space").split(separator: "\n").first == "Spaces > Next Space  ⌘S  nextSpace: → MenuRouter")
    }

    @Test func pointerFoldsIdenticalSamplesIntoRuns() {
        func sample(_ x: Double, _ cursor: String) -> UIPointerSample {
            UIPointerSample(point: UIPoint(x: x, y: 50), hit: cursor == "arrow" ? "0.1 NSHostingView" : "0.5 SidebarResizeHandle",
                            cursorRects: [], trackingAreas: [], cursor: cursor)
        }
        let text = UIReport.pointer([sample(230, "arrow"), sample(231, "arrow"), sample(232, "arrow"),
                                     sample(233, "resizeLeftRight"), sample(234, "resizeLeftRight"), sample(235, "arrow")])
        #expect(text == """
            (230, 50) → (232, 50), 3 points: cursor arrow | hit 0.1 NSHostingView
            (233, 50) → (234, 50), 2 points: cursor resizeLeftRight | hit 0.5 SidebarResizeHandle
            (235, 50): cursor arrow | hit 0.1 NSHostingView
            """)
    }

    @Test func hitListsTheViewHitThenItsSuperviews() {
        let chain = [
            UIHitView(path: "0.3.3.0.5.1.1.6", className: "SymbolButton", frame: UIRect(x: 202, y: 352.5, width: 24, height: 24)),
            UIHitView(path: "0.3.3.0.5.1.1", className: "SidebarPassthroughView", frame: UIRect(x: 8, y: 346.5, width: 224, height: 36)),
            UIHitView(path: "0.3.3.0.5.1", className: "TabRowCell", frame: UIRect(x: 8, y: 344, width: 224, height: 41)),
            UIHitView(path: nil, className: "NSThemeFrame", frame: UIRect(x: 0, y: 0, width: 1280, height: 820), isHidden: true),
        ]
        #expect(UIReport.hit(UIPoint(x: 210, y: 364.5), chain: chain) == """
            Hit at (210, 364.5): the view a click there reaches, then its superviews.
            0.3.3.0.5.1.1.6 SymbolButton [202,352.5 24×24]
            0.3.3.0.5.1.1 SidebarPassthroughView [8,346.5 224×36]
            0.3.3.0.5.1 TabRowCell [8,344 224×41]
            - NSThemeFrame [0,0 1280×820] hidden=true
            """)
        #expect(UIReport.hit(UIPoint(x: -1, y: -1), chain: []) == "Hit at (-1, -1): nothing.")
    }

    @Test func anExpectationIsMetOnlyByTheApprovedViewOrWhatItAllowsInsideIt() {
        func view(_ path: String?, _ cls: String, hidden: Bool = false) -> UIHitView {
            UIHitView(path: path, className: cls, frame: UIRect(x: 0, y: 0, width: 10, height: 10), isHidden: hidden)
        }
        let rowUp = [view("0.3.3.0.5", "SidebarRowContainer"), view("0.3", "NSView"), view(nil, "NSThemeFrame")]
        let row = UIHitExpectation(path: "0.3.3.0.5.1", className: "TabRowCell", inside: ["SymbolButton", "SidebarPassthroughView"])
        let cell = UIHitExpectation(path: "0.3.4.0.1", className: "SpaceCellView")
        // The view itself, or allowed views all the way up to it.
        #expect(row.refusal(for: [view("0.3.3.0.5.1", "TabRowCell")] + rowUp) == nil)
        #expect(row.refusal(for: [view("0.3.3.0.5.1.1.6", "SymbolButton"), view("0.3.3.0.5.1.1", "SidebarPassthroughView"),
                                  view("0.3.3.0.5.1", "TabRowCell")] + rowUp) == nil)
        #expect(cell.refusal(for: [view("0.3.4.0.1", "SpaceCellView"), view("0.3.4.0", "NSView")]) == nil)
        // Nothing, another view, a class it doesn't allow on the way, the wrong class at the path, a hidden view, or a
        // view outside it.
        #expect(cell.refusal(for: []) == "it hits nothing")
        #expect(cell.refusal(for: [view("0.2", "WKWebView"), view("0", "NSView")])?.contains("WKWebView") == true)
        #expect(cell.refusal(for: [view("0.3.4.0.1.2", "SymbolButton"), view("0.3.4.0.1", "SpaceCellView")]) != nil)
        #expect(row.refusal(for: [view("0.3.3.0.5.1.0", "RenameField"), view("0.3.3.0.5.1", "TabRowCell")] + rowUp) != nil)
        #expect(cell.refusal(for: [view("0.3.4.0.1", "TabRowCell")])?.contains("not a SpaceCellView") == true)
        #expect(cell.refusal(for: [view("0.3.4.0.1", "SpaceCellView", hidden: true)])?.contains("hidden") == true)
        #expect(row.refusal(for: [view("0.3.3.0.5.1.1.6", "SymbolButton", hidden: true), view("0.3.3.0.5.1", "TabRowCell")]) != nil)
        #expect(row.refusal(for: [view("0.3.3.0.6.1.1.6", "SymbolButton"), view("0.3.3.0.6.1", "SidebarPassthroughView")])?
            .contains("isn't inside") == true)
        // A view the tree has no path for never matches a path.
        #expect(cell.refusal(for: [view(nil, "SpaceCellView")]) != nil)
    }
}

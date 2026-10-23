import Foundation
import Testing
@testable import KiteCore

@Suite struct BatchTests {
    @Test func parsesStepsAndPassesTheTabDown() throws {
        let command = try AutomationCommand(tool: "batch", arguments: [
            "tab": "T",
            "steps": [
                ["tool": "click", "arguments": ["ref": "e4"]],
                ["tool": "computer", "arguments": ["action": "key", "text": "Enter", "tab": "U"]],
                ["tool": "wait_for", "arguments": ["condition": "load"]],
                ["tool": "read_page", "arguments": ["changes_only": true]],
                ["tool": "list_spaces"],
            ],
        ])
        guard case .batch(let steps) = command else {
            Issue.record("expected a batch")
            return
        }
        #expect(steps.count == 5)
        #expect(steps[0] == .click(tab: "T", target: .ref("e4")))
        guard case .computer("U", _) = steps[1] else {
            Issue.record("a step's own tab wins")
            return
        }
        #expect(steps[2] == .waitFor(tab: "T", condition: .load, timeout: 10))
        #expect(steps[3] == .readPage(tab: "T", maxTextLength: AutomationCommand.defaultMaxTextLength, interactiveOnly: false, changesOnly: true))
        #expect(steps[4] == .listSpaces)
    }

    @Test(arguments: [
        JSONValue.object([:]),
        ["steps": []],
        ["steps": [["arguments": [:]]]],
        ["steps": [["tool": "batch", "arguments": ["steps": [["tool": "tabs_context"]]]]]],
        ["steps": [["tool": "click", "arguments": [:]]]],
        ["steps": [["tool": "click", "arguments": "e4"]]],
        ["steps": .array(Array(repeating: JSONValue.object(["tool": "tabs_context"]), count: AutomationCommand.maxBatchSteps + 1))],
    ])
    func rejectsBadBatches(arguments: JSONValue) {
        #expect(throws: AutomationCommand.InvalidArguments.self) { try AutomationCommand(tool: "batch", arguments: arguments) }
    }

    @Test func badStepsSayWhichStep() {
        do {
            _ = try AutomationCommand(tool: "batch", arguments: ["steps": [["tool": "tabs_context"], ["tool": "type", "arguments": [:]]]])
            Issue.record("expected an error")
        } catch {
            #expect("\(error)".hasPrefix("Step 2 (type):"))
        }
    }

    @Test func knowsWhichToolsTakeATab() {
        #expect(AutomationCommand.Tool.click.takesTab)
        #expect(AutomationCommand.Tool.readPage.takesTab)
        #expect(!AutomationCommand.Tool.listSpaces.takesTab)
        #expect(!AutomationCommand.Tool.batch.takesTab)
        #expect(AutomationCommand.Tool.batch.inputSchema["required"] == ["steps"])
    }
}

@Suite struct PageDiffTests {
    @Test func findsAddedAndRemovedLines() {
        let change = PageDiff.change(from: ["a", "b", "c", "d"], to: ["a", "c", "x", "d", "e"])
        #expect(change.removed == ["b"])
        #expect(change.added == ["x", "e"])
        #expect(PageDiff.change(from: ["a"], to: ["a"]).isEmpty)
        #expect(PageDiff.change(from: [], to: ["a"]).added == ["a"])
    }

    @Test func reportsOutlineAndTextChanges() {
        let before = PageDiff.Snapshot(url: "https://a.example/", outline: """
            - textbox "Search" [ref=e7]
            - button "Go" [ref=e8]
            """, text: "ready\nfooter")
        let after = PageDiff.Snapshot(url: "https://a.example/", outline: """
            - textbox "Search" value="kites" focused [ref=e7]
            - button "Go" [ref=e8]
            """, text: "3 results\nfooter")
        #expect(PageDiff.report(from: before, to: after) == """
            Outline:
            - textbox "Search" [ref=e7]
            + textbox "Search" value="kites" focused [ref=e7]
            Text:
            - ready
            + 3 results
            """)
        #expect(PageDiff.report(from: before, to: before) == "Nothing on the page changed.")
    }

    @Test func givesUpOnNewPagesAndBigChanges() {
        let a = PageDiff.Snapshot(url: "https://a.example/", outline: "", text: "x")
        #expect(PageDiff.report(from: a, to: PageDiff.Snapshot(url: "https://b.example/", outline: "", text: "x")) == nil)
        let big = PageDiff.Snapshot(url: "https://a.example/", outline: "", text: (0..<100).map { "line \($0)" }.joined(separator: "\n"))
        #expect(PageDiff.report(from: a, to: big) == nil)
    }

    @Test func handlesLongPagesQuickly() {
        let old = (0..<1500).map { "row \($0)" }
        var new = old
        new[700] = "row 700 changed"
        let change = PageDiff.change(from: old, to: new)
        #expect(change.added == ["row 700 changed"] && change.removed == ["row 700"])
    }
}

@Suite struct ScreenshotScaleTests {
    @Test func scalesOnlyWideViewports() {
        #expect(ScreenshotScale(viewportWidth: 1000).factor == 1)
        #expect(ScreenshotScale(viewportWidth: 1280).factor == 1)
        let wide = ScreenshotScale(viewportWidth: 2560)
        #expect(wide.factor == 0.5)
        #expect(wide.toPage(ViewportPoint(x: 100, y: 40)) == ViewportPoint(x: 200, y: 80))
        #expect(ScreenshotScale(viewportWidth: 0).factor == 1)
    }
}

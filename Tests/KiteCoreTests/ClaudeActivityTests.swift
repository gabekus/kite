import Foundation
import Testing
@testable import KiteCore

/// The quiet line under a working tab's title (Gabe, 5 Nov 2026: "i should be able to see somewhere non intrusive what
/// the agent is doing").
@Suite struct ClaudeActivityTests {
    let t0 = Date(timeIntervalSince1970: 1_000)

    @Test func saysWhatEachToolDoes() {
        #expect(ClaudeActivity.describe(.readPage(tab: nil, maxTextLength: 1, interactiveOnly: false, changesOnly: false)) == "Reading the page")
        #expect(ClaudeActivity.describe(.screenshot(tab: nil, format: .jpeg)) == "Looking at the page")
        #expect(ClaudeActivity.describe(.navigate(tab: nil, url: "back", newTab: false)) == "Going back")
        #expect(ClaudeActivity.describe(.navigate(tab: nil, url: "https://www.amazon.com/cart", newTab: false)) == "Opening amazon.com")
        #expect(ClaudeActivity.describe(.listSpaces) == nil)
        let button = ElementDescription(tag: "button", label: "Proceed to checkout")
        #expect(ClaudeActivity.clicking(button) == "Clicking Proceed to checkout")
        let zip = ElementDescription(tag: "input", type: "text", label: "Zip Code")
        #expect(ClaudeActivity.typing(into: zip) == "Typing in Zip Code")
        #expect(ClaudeActivity.filling(zip) == "Filling in Zip Code")
        #expect(ClaudeActivity.typing(into: ElementDescription(tag: "input", placeholder: "Search")) == "Typing in Search")
        #expect(ClaudeActivity.typing(into: nil) == "Typing")
    }

    @Test func neverShowsWhatClaudeTypes() {
        // A rich text box's label falls back to its own text on the page: only its placeholder names it.
        let body = ElementDescription(tag: "div", label: "Hi Pat, my card is 4242…", isContentEditable: true)
        #expect(ClaudeActivity.typing(into: body) == "Typing")
        let long = ElementDescription(tag: "button", label: String(repeating: "word ", count: 20))
        #expect(ClaudeActivity.clicking(long).count <= "Clicking ".count + ClaudeActivity.maxLabelLength)
    }

    @Test func keepsTheLastFewWithTimes() {
        var log = ClaudeActivity.Log()
        for i in 0..<7 { log.append("Step \(i)", at: t0.addingTimeInterval(Double(i))) }
        #expect(log.entries.count == ClaudeActivity.Log.capacity && log.latest?.text == "Step 6")
        log.refineLatest("Clicking Place order")
        #expect(log.latest?.text == "Clicking Place order")
        let tip = ClaudeActivity.tooltip(help: "Claude is working here", log: log, timeZone: TimeZone(identifier: "UTC")!)
        let lines = tip.components(separatedBy: "\n")
        #expect(lines.first == "Claude is working here" && lines[2] == "12:16:46 AM  Clicking Place order")
        #expect(lines.count == 2 + ClaudeActivity.Log.capacity)
        #expect(ClaudeActivity.tooltip(help: "Claude is working here", log: nil) == "Claude is working here")
    }
}

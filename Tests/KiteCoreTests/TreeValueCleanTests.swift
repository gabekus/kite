import Testing
@testable import KiteCore

struct TreeValueCleanTests {
    @Test func aValueCantFakeATreeLine() {
        // `ui tree` prints an accessibility value (a page's text, say) as an attribute; cleaned, a newline in it
        // can't start a line of its own that reads like another node with its own frame.
        let value = "Search\n0.3.2.1 SpaceCellView [68,778 36×34]"
        let printed = AccessibilityOutline.quote(AccessibilityOutline.clean(value, limit: 80))
        #expect(!printed.contains("\n"))
        #expect(printed == "\"Search 0.3.2.1 SpaceCellView [68,778 36×34]\"")
        let node = UINode(kind: "AXTextField", frame: UIRect(x: 0, y: 0, width: 10, height: 10),
                          attributes: [.init("value", printed)])
        #expect(node.line.split(separator: "\n").count == 1)
    }
}

import Foundation
import Testing
@testable import KiteCore

@Suite struct UINodeRedactionTests {
    @Test func keepsOnlyRolesFramesAndStructure() {
        let tree = UINode(
            kind: "AXWindow", identifier: "bigBrowserWindow-8A79", label: "My bank – Statements",
            frame: UIRect(x: 0, y: 0, width: 800, height: 600),
            attributes: [.init("subrole", "AXStandardWindow"), .init("url", "https://bank.example/acct")],
            children: [
                UINode(kind: "AXButton", identifier: "Tennis Reservations", label: "Tennis Reservations",
                       frame: UIRect(x: 5, y: 244, width: 305, height: 40),
                       attributes: [.init("selected", "true"), .init("value", "secret")]),
                UINode(kind: "AXButton", frame: UIRect(x: 76, y: 12.5, width: 32, height: 32),
                       attributes: [.init("enabled", "false")]),
            ]
        )
        let redacted = tree.redactingText()
        #expect(redacted.identifier == nil)
        #expect(redacted.label == "‹20 chars›")
        #expect(redacted.attributes == [.init("subrole", "AXStandardWindow")])
        #expect(redacted.frame == tree.frame)
        #expect(redacted.children[0].identifier == nil)
        #expect(redacted.children[0].label == "‹19 chars›")
        #expect(redacted.children[0].attributes == [.init("selected", "true")])
        #expect(redacted.children[1].attributes == [.init("enabled", "false")])

        let printed = UIReport.tree(redacted, depth: 5, match: nil, maxNodes: 100, source: "test")
        for secret in ["Tennis", "bank", "8A79", "secret", "acct"] {
            #expect(!printed.contains(secret), "\(secret)")
        }
    }
}

import Foundation
import Testing
@testable import KiteCore

/// Every window, activation, modal and app launch in KiteMac goes through WindowPresenter, which keeps a test-safe
/// run behind the user's windows. A line that must call one directly says why after `// presenter-exempt:`.
struct WindowPresenterGuardTests {
    @Test func kiteMacCallsWindowPresenterForWindowsModalsAndOtherApps() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/KiteMac")
        let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" && file.lastPathComponent != "WindowPresenter.swift" {
            let source = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            for violation in WindowPresenterGuard.violations(in: source) {
                Issue.record("\(file.path.replacingOccurrences(of: root.path + "/", with: "")):\(violation)")
            }
        }
        #expect(checked > 100)
    }

    @Test func theGuardSkipsCommentsAndExemptLines() {
        let source = """
            /// Calls makeKeyAndOrderFront(nil) in a doc comment.
            window.orderFront(nil) // presenter-exempt: the reason
            x = 1 // then runModal( in a comment
            window.level = .floating
            """
        #expect(WindowPresenterGuard.violations(in: source) == ["4: .level =  in window.level = .floating"])
    }

    @Test func aTestSafeRunSkipsTheShareMenu() throws {
        // NSSharingServicePicker lists other apps' services, which open windows of their own: skipped and logged, as
        // a modal is.
        let presenter = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/KiteMac/WindowPresenter.swift"), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        #expect(presenter.contains("""
                static func showSharingPicker(items: [Any], relativeTo rect: NSRect, of view: NSView, preferredEdge edge: NSRectEdge) {
                    guard !testSafe else { return logSkipped(
            """))
    }

    @Test func aPopoverShowsThroughWindowPresenter() {
        // NSPopover's show is a window of its own: only WindowPresenter.show(_:relativeTo:of:preferredEdge:) calls it.
        let source = """
            WindowPresenter.show(popover, relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
            """
        #expect(WindowPresenterGuard.violations(in: source)
            == ["2: .show(relativeTo in popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)"])
    }
}

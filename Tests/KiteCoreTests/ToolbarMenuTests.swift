import Testing
@testable import KiteCore

@Suite struct ToolbarMenuTests {
    private func titles(_ items: [ToolbarMenuItem]) -> [String] {
        items.map { $0.title ?? "---" }
    }

    @Test func webPageInArcsOrder() {
        let items = ToolbarMenu.items(hasURL: true, isWebPage: true, extensionsAvailable: true, showsFullURL: false)
        #expect(titles(items) == [
            "Copy URL", "Share", "Capture…", "Capture Full Page", "Capture in Portrait Mode",
            "---", "Manage Extensions…",
            "---", "Show Full URL", "Hide Toolbar",
        ])
        #expect(items.allSatisfy { $0.isEnabled })
    }

    @Test func fullURLItemSaysWhatItWillDo() {
        let items = ToolbarMenu.items(hasURL: true, isWebPage: true, extensionsAvailable: false, showsFullURL: true)
        #expect(titles(items) == ["Copy URL", "Share", "Capture…", "Capture Full Page", "Capture in Portrait Mode", "---", "Hide Full URL", "Hide Toolbar"])
    }

    @Test func kitePagesKeepADisabledCopyURLAndTheToolbarItem() {
        let items = ToolbarMenu.items(hasURL: true, isWebPage: false, extensionsAvailable: false, showsFullURL: false)
        #expect(titles(items) == ["Copy URL", "---", "Hide Toolbar"])
        #expect(items.first?.isEnabled == false)
    }

    @Test func noMenuWithoutAnAddress() {
        #expect(ToolbarMenu.items(hasURL: false, isWebPage: false, extensionsAvailable: true, showsFullURL: false).isEmpty)
    }

    @Test func toolbarItemFollowsTheToolbar() {
        let items = ToolbarMenu.items(hasURL: true, isWebPage: false, extensionsAvailable: false, showsFullURL: false, showsToolbar: false)
        #expect(items.last?.title == "Show as Toolbar")
    }
}

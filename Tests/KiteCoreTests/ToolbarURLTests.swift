import Foundation
import Testing
@testable import KiteCore

@Suite struct ToolbarURLTests {
    let page = URL(string: "https://www.example.com/docs/guide?tab=2&q=a%20b#install")!

    @Test func offShowsTheHostOnly() {
        #expect(ToolbarURL.text(for: page, full: false) == "www.example.com")
        #expect(ToolbarURL.text(for: URL(string: "http://127.0.0.1:8123/a/b?c=d")!, full: false) == "127.0.0.1")
    }

    @Test func onShowsTheWholeAddress() {
        #expect(ToolbarURL.text(for: page, full: true) == "https://www.example.com/docs/guide?tab=2&q=a%20b#install")
        #expect(ToolbarURL.text(for: URL(string: "http://127.0.0.1:8123/a/b?c=d")!, full: true) == "http://127.0.0.1:8123/a/b?c=d")
    }

    @Test func hostlessURLsShowInFull() {
        #expect(ToolbarURL.text(for: URL(string: "about:blank")!, full: false) == "about:blank")
        #expect(ToolbarURL.text(for: nil, full: true) == "")
    }

    @Test func offByDefault() throws {
        let defaults = try #require(UserDefaults(suiteName: "ToolbarURLTests-\(UUID().uuidString)"))
        #expect(!ToolbarURL.showsFullURL(in: defaults))
        defaults.set(true, forKey: ToolbarURL.showsFullURLKey)
        #expect(ToolbarURL.showsFullURL(in: defaults))
    }
}

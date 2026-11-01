import Foundation
import Testing
@testable import KiteCore

@Suite struct AppleScriptingTests {
    @Test func locationsUseArcsNames() {
        #expect(AppleScripting.location(.favorite) == "topApp")
        #expect(AppleScripting.location(.pinned) == "pinned")
        #expect(AppleScripting.location(.unpinned) == "unpinned")
    }

    @Test func windowTabsAreFavoritesThenTheSpacesTabs() {
        var state = BrowserState.makeDefault(seedURL: nil)
        let pinned = state.openTab(url: URL(string: "https://pinned.example"))
        state.togglePin(tab: pinned)
        let favorite = state.openTab(url: URL(string: "https://favorite.example"))
        state.toggleFavorite(tab: favorite)
        let unpinned = state.openTab(url: URL(string: "https://unpinned.example"))
        // A tab in another space isn't in this window's list.
        _ = state.openTab(url: URL(string: "https://work.example"), in: state.spaces[1].id, select: false)

        #expect(AppleScripting.windowTabs(state).map(\.id) == [favorite, pinned, unpinned])
        #expect(AppleScripting.spaceTabs(state.selectedSpace).map(\.id) == [pinned, unpinned])
        #expect(AppleScripting.spaceTabs(state.spaces[1]).count == 1)
    }

    @Test func newTabsNeedAURLWithAScheme() {
        #expect(AppleScripting.newTabURL("https://example.com/a") == URL(string: "https://example.com/a"))
        #expect(AppleScripting.newTabURL("  about:blank ") == URL(string: "about:blank"))
        #expect(AppleScripting.newTabURL(nil) == nil)
        #expect(AppleScripting.newTabURL("") == nil)
        #expect(AppleScripting.newTabURL("not a url") == nil)
        #expect(AppleScripting.newTabURL(42) == nil)
    }

    @Test func javaScriptResultsBecomeText() {
        #expect(AppleScripting.text(fromJavaScriptResult: nil) == "")
        #expect(AppleScripting.text(fromJavaScriptResult: NSNull()) == "")
        #expect(AppleScripting.text(fromJavaScriptResult: "Title") == "Title")
        #expect(AppleScripting.text(fromJavaScriptResult: NSNumber(value: 3)) == "3")
        #expect(AppleScripting.text(fromJavaScriptResult: NSNumber(value: 2.5)) == "2.5")
        #expect(AppleScripting.text(fromJavaScriptResult: NSNumber(value: true)) == "true")
        #expect(AppleScripting.text(fromJavaScriptResult: ["b": 1, "a": "x"]) == #"{"a":"x","b":1}"#)
        #expect(AppleScripting.text(fromJavaScriptResult: [1, 2]) == "[1,2]")
    }

    @Test func windowModeAtCreation() {
        #expect(AppleScripting.isIncognito(mode: "incognito", incognito: nil))
        #expect(AppleScripting.isIncognito(mode: "Incognito", incognito: false))
        #expect(!AppleScripting.isIncognito(mode: "normal", incognito: true))
        #expect(AppleScripting.isIncognito(mode: nil, incognito: true))
        #expect(!AppleScripting.isIncognito(mode: nil, incognito: nil))
    }

    @Test func javaScriptFromAppleEventsIsOffByDefaultAndSaved() throws {
        var state = BrowserState.makeDefault(seedURL: nil)
        #expect(!state.allowsJavaScriptFromAppleEvents)
        state.allowsJavaScriptFromAppleEvents = true
        let decoded = try JSONDecoder().decode(BrowserState.self, from: JSONEncoder().encode(state))
        #expect(decoded.allowsJavaScriptFromAppleEvents)

        // Sessions saved before the setting existed load with it off.
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as! [String: Any]
        json.removeValue(forKey: "allowsJavaScriptFromAppleEvents")
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.allowsJavaScriptFromAppleEvents)
    }
}

import Foundation
import Testing
@testable import KiteCore

@Suite struct TidyTabTitlesTests {
    private func state() -> (BrowserState, UUID) {
        var space = Space(name: "S", icon: "🏠", theme: Theme.presets[0])
        let tab = BrowserTab(url: URL(string: "https://example.com/post"), title: "How to Bake Bread: A Guide | Example Blog")
        space.tabs = [tab]
        space.selectedTabID = tab.id
        return (BrowserState(spaces: [space]), tab.id)
    }

    @Test func pinningATabMakesItANewlyPinnedTab() {
        let (before, id) = state()
        var after = before
        after.togglePin(tab: id)
        #expect(TidyTabTitles.newlyPinnedTabs(before: before, after: after).map(\.id) == [id])
    }

    @Test func unpinningOrOtherChangesDont() {
        var (before, id) = state()
        before.togglePin(tab: id)
        var after = before
        after.update(tab: id) { $0.title = "Another title" }
        #expect(TidyTabTitles.newlyPinnedTabs(before: before, after: after).isEmpty)
        after.togglePin(tab: id)
        #expect(TidyTabTitles.newlyPinnedTabs(before: before, after: after).isEmpty)
    }

    @Test func renamedOrUntitledTabsAreLeftAlone() {
        var (before, id) = state()
        before.renameTab(id, to: "Bread")
        var after = before
        after.togglePin(tab: id)
        #expect(TidyTabTitles.newlyPinnedTabs(before: before, after: after).isEmpty)

        var (untitled, other) = state()
        untitled.update(tab: other) { $0.title = "" }
        var pinned = untitled
        pinned.togglePin(tab: other)
        #expect(TidyTabTitles.newlyPinnedTabs(before: untitled, after: pinned).isEmpty)
    }

    @Test func aTabThatArrivesAlreadyPinnedIsnt() {
        let (before, _) = state()
        var after = before
        after.spaces[0].pinnedItems.append(.tab(BrowserTab(url: URL(string: "https://a.com"), title: "A")))
        #expect(TidyTabTitles.newlyPinnedTabs(before: before, after: after).isEmpty)
    }

    @Test func theReplysRewrittenTitleIsTheName() {
        #expect(TidyTabTitles.title(fromReply: #"{"filtered":"How to Bake Bread","rewritten":"Baking Bread"}"#) == "Baking Bread")
        let fenced = "```json\n{\n  \"filtered\": \"x\",\n  \"rewritten\": \" \\\"Bread\\\" \"\n}\n```"
        #expect(TidyTabTitles.title(fromReply: fenced) == "Bread")
        #expect(TidyTabTitles.title(fromReply: "Sorry, I can't.") == nil)
        #expect(TidyTabTitles.title(fromReply: #"{"rewritten":""}"#) == nil)
        #expect(TidyTabTitles.title(fromReply: #"{"filtered":"x"}"#) == nil)
    }

    @Test func thePromptWrapsThePagesTitleAndNamesTheLanguage() {
        let prompt = TidyTabTitles.prompt(title: "Bread", url: URL(string: "https://example.com/p"), language: "French")
        #expect(prompt.contains("<untrusted-page-content"))
        #expect(prompt.contains("example.com"))
        #expect(prompt.contains("in French"))
        #expect(prompt.contains("\"rewritten\""))
    }

    @Test func languageIsAnEnglishName() {
        #expect(TidyTabTitles.language(preferred: ["fr-CA"]) == "French")
        #expect(TidyTabTitles.language(preferred: []) == "English")
    }

    @Test func onByDefaultAsInGabesArc() throws {
        let suite = "TidyTabTitlesTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(TidyTabTitles.isEnabled(in: defaults))
        defaults.set(false, forKey: TidyTabTitles.enabledKey)
        #expect(!TidyTabTitles.isEnabled(in: defaults))
    }

    @Test func noToolsAndTheFastModel() {
        let arguments = TidyTabTitles.arguments()
        #expect(arguments.contains("--strict-mcp-config"))
        #expect(arguments.firstIndex(of: "--tools").map { arguments[$0 + 1] } == "")
        #expect(arguments.firstIndex(of: "--model").map { arguments[$0 + 1] } == "haiku")
    }
}

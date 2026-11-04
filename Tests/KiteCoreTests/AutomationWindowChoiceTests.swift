import Testing
@testable import KiteCore

@Suite struct AutomationWindowChoiceTests {
    typealias W = AutomationWindowChoice.Window<Int>

    @Test func keepsAnOpenNormalWindow() {
        let windows = [W(id: 2, isNormal: true, isOpen: true), W(id: 1, isNormal: true, isOpen: true)]
        #expect(AutomationWindowChoice.pick(current: 1, windows: windows) == .keep)
    }

    @Test func movesToTheFrontmostOpenNormalWindowWhenTheCurrentOneCloses() {
        let windows = [
            W(id: 4, isNormal: false, isOpen: true),  // incognito in front
            W(id: 1, isNormal: true, isOpen: false),  // the main window, closed
            W(id: 3, isNormal: true, isOpen: true),
            W(id: 2, isNormal: true, isOpen: true),
        ]
        #expect(AutomationWindowChoice.pick(current: 1, windows: windows) == .use(3))
    }

    @Test func aCurrentWindowMissingFromTheListIsReplaced() {
        #expect(AutomationWindowChoice.pick(current: 9, windows: [W(id: 2, isNormal: true, isOpen: true)]) == .use(2))
        #expect(AutomationWindowChoice.pick(current: nil, windows: [W(id: 2, isNormal: true, isOpen: true)]) == .use(2))
    }

    @Test func opensOneWhenNoNormalWindowIsLeft() {
        let windows = [W(id: 1, isNormal: true, isOpen: false), W(id: 5, isNormal: false, isOpen: true)]
        #expect(AutomationWindowChoice.pick(current: 1, windows: windows) == .openNew)
        #expect(AutomationWindowChoice.pick(current: nil, windows: [W]()) == .openNew)
    }

    @Test func neverMovesToAnIncognitoOrBlankWindow() {
        #expect(AutomationWindowChoice.pick(current: 5, windows: [W(id: 5, isNormal: false, isOpen: true)]) == .openNew)
    }
}

@Suite struct AutomationNeedsWindowTests {
    @Test func tabAndPageToolsNeedAWindow() {
        #expect(AutomationCommand.navigate(tab: nil, url: "https://example.com", newTab: true).needsWindow)
        #expect(AutomationCommand.tabsContext.needsWindow)
        #expect(AutomationCommand.switchSpace(space: "Work").needsWindow)
        #expect(AutomationCommand.readPage(tab: nil, maxTextLength: 100, interactiveOnly: false, changesOnly: false).needsWindow)
    }

    @Test func reportsDoNot() {
        #expect(!AutomationCommand.listDownloads.needsWindow)
        #expect(!AutomationCommand.ui(.windows).needsWindow)
        #expect(!AutomationCommand.batch(steps: [.listDownloads]).needsWindow)
        #expect(AutomationCommand.batch(steps: [.listDownloads, .tabsContext]).needsWindow)
    }
}

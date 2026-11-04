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

@Suite struct AutomationWindowOrderTests {
    @Test func visibleOnlySkipsAWindowHiddenWhileClaudeWorks() {
        let windows = [AutomationWindowChoice.Window(id: 1, isNormal: true, isOpen: true, isVisible: false),
                       AutomationWindowChoice.Window(id: 2, isNormal: true, isOpen: true)]
        #expect(AutomationWindowChoice.pick(current: 1, windows: windows) == .keep)
        #expect(AutomationWindowChoice.pick(current: 1, windows: windows, visibleOnly: true) == .use(2))
    }

    @Test func ordersByScreenThenByCreation() {
        // 3 and 1 on screen (3 in front); 2 and 4 hidden, kept in the order they were made.
        #expect(AutomationWindowChoice.frontToBack([1, 2, 3, 4], screenOrder: [9, 3, 1]) == [3, 1, 2, 4])
        #expect(AutomationWindowChoice.frontToBack([4, 2], screenOrder: []) == [4, 2])
    }
}

@Suite struct StoreWatchTests {
    @Test func reportsOnlyChanges() {
        var watch = StoreWatch<[String]>()
        let g = watch.generation
        let seen = [watch.saw(["a"], generation: g), watch.saw(["a"], generation: g), watch.saw(["b"], generation: g)]
        #expect(seen == [true, false, true])
    }

    @Test func rebindingDropsTheOldStoresCallbacksAndLooksAgain() {
        var watch = StoreWatch<[String]>()
        let old = watch.generation
        let first = watch.saw(["front A"], generation: old)
        let new = watch.rebind()
        // The old store changing no longer counts, and its re-arm is dropped.
        let stale = watch.saw(["front B"], generation: old)
        // The new store's first look counts even when its key happens to match the old one.
        let fresh = watch.saw(["front A"], generation: new)
        #expect(first && !stale && fresh)
        #expect(!watch.isCurrent(old) && watch.isCurrent(new))
    }
}

@Suite struct BackgroundWindowPresentationTests {
    @Test func claudesWindowNeverTakesTheKeyboardOnARealProfile() {
        let p = WindowPresentation.background(testSafe: false)
        #expect(p.order == .belowKey)
        #expect(!p.makesKey)
        #expect(!p.activates)
    }

    @Test func aTestRunPutsItBehindEverything() {
        let p = WindowPresentation.background(testSafe: true, level: 3)
        #expect(p.order == .behind)
        #expect(!p.makesKey && !p.activates)
        #expect(p.level == WindowPresentation.normalLevel)
    }

    @Test func theUsersWindowsStillComeForward() {
        #expect(WindowPresentation.decide(testSafe: false).makesKey)
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
        #expect(!AutomationCommand.listSpaces.needsWindow)
        #expect(!AutomationCommand.createSpace(name: "Travel", icon: nil, about: nil).needsWindow)
        #expect(!AutomationCommand.describeSpace(space: "Work", about: "Work things").needsWindow)
        #expect(!AutomationCommand.batch(steps: [.listDownloads]).needsWindow)
        #expect(AutomationCommand.batch(steps: [.listDownloads, .tabsContext]).needsWindow)
    }
}

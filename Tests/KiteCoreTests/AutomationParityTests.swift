import Foundation
import Testing
@testable import KiteCore

@Suite struct ParityPolicyTests {
    private func asks(_ action: AutomationAction) -> Bool {
        if case .confirm = AutomationPolicy.evaluate(action, host: "site.example") { return true }
        return false
    }

    private let chatBox = ElementDescription(tag: "div", role: "textbox", label: "Message", isContentEditable: true)
    private let searchBox = ElementDescription(tag: "input", type: "search", name: "q", inForm: true)
    private let sendButton = ElementDescription(tag: "button", type: "button", label: "Send")

    @Test func returnInAFieldAsksButNotInSearch() throws {
        let enter = try KeyChord.parse("Enter")
        #expect(asks(.keys([enter], focused: chatBox)))
        #expect(asks(.keys([try KeyChord.parse("cmd+Enter")], focused: ElementDescription(tag: "textarea"))))
        #expect(!asks(.keys([enter], focused: searchBox)))
        #expect(!asks(.keys([enter], focused: ElementDescription(tag: "input", type: "text", placeholder: "Search products"))))
        #expect(!asks(.keys([enter], focused: nil)))
    }

    @Test func returnOrSpaceOnAButtonIsAClick() throws {
        #expect(asks(.keys([try KeyChord.parse("Enter")], focused: sendButton)))
        #expect(asks(.keys([try KeyChord.parse("space")], focused: sendButton)))
        #expect(!asks(.keys([try KeyChord.parse("Enter")], focused: ElementDescription(tag: "a", label: "Docs"))))
    }

    @Test func otherKeysAreFine() throws {
        #expect(!asks(.keys(try KeyChord.parseSequence("cmd+a Backspace Tab ArrowDown"), focused: chatBox)))
    }

    @Test func submittingASearchDoesNotAsk() {
        #expect(!asks(.type(searchBox, text: "kite browser", submit: true)))
        #expect(asks(.type(chatBox, text: "hi", submit: true)))
    }

    @Test func clicksIntoOtherSitesFramesAsk() {
        let frame = ElementDescription(tag: "iframe", label: "Secure payment", href: "https://pay.example/frame")
        guard case .confirm(let request) = AutomationPolicy.evaluate(.click(frame), host: "shop.example") else {
            Issue.record("expected confirmation")
            return
        }
        #expect(request.action.contains("pay.example"))
    }

    @Test func formInputAsksOnlyForSecrets() {
        #expect(asks(.formInput(ElementDescription(tag: "input", type: "password"), value: "hunter2")))
        #expect(!asks(.formInput(ElementDescription(tag: "select", label: "Country"), value: "Japan")))
        #expect(!asks(.formInput(ElementDescription(tag: "input", type: "checkbox", label: "Bacon"), value: "true")))
    }

    @Test func javascriptRunsWithoutAsking() {
        #expect(!asks(.javascript(code: "document.title")))
    }

    @Test func uploadsAlwaysAskAndListThePaths() {
        guard case .confirm(let request) = AutomationPolicy.evaluate(
            .uploadFiles(["/Users/me/a.pdf", "/Users/me/b.png"], into: ElementDescription(tag: "input", type: "file")), host: nil) else {
            Issue.record("expected confirmation")
            return
        }
        #expect(request.action == "upload 2 files")
        #expect(request.detail.contains("a.pdf") && request.detail.contains("b.png"))
    }

    @Test func dialogs() {
        #expect(!asks(.answerDialog(kind: "alert", message: "Saved", accept: true)))
        #expect(!asks(.answerDialog(kind: "confirm", message: "Delete?", accept: false)))
        #expect(asks(.answerDialog(kind: "confirm", message: "Delete?", accept: true)))
        #expect(asks(.answerDialog(kind: "beforeunload", message: "", accept: true)))
        #expect(asks(.answerDialog(kind: "prompt", message: "Name?", accept: true)))
    }
}

@Suite struct ElementFinderTests {
    private let nodes: [AXNode] = [
        AXNode(nodeId: "1", role: "RootWebArea", name: "Shop", childIds: ["2", "3", "4", "5", "6", "7"], backendDOMNodeId: 1),
        AXNode(nodeId: "2", role: "searchbox", name: "Search products", parentId: "1", backendDOMNodeId: 10),
        AXNode(nodeId: "3", role: "button", name: "Add to cart", parentId: "1", backendDOMNodeId: 11),
        AXNode(nodeId: "4", role: "link", name: "Cart (2)", parentId: "1", backendDOMNodeId: 12),
        AXNode(nodeId: "5", role: "button", name: "Subscribe to newsletter", parentId: "1", backendDOMNodeId: 13),
        AXNode(nodeId: "6", role: "heading", name: "Kite Browser", parentId: "1", backendDOMNodeId: 14),
        AXNode(nodeId: "7", role: "generic", name: "Add to cart", parentId: "1", backendDOMNodeId: 15),
    ]

    @Test func findsByTextAndRole() {
        #expect(ElementFinder.find(nodes, query: "add to cart button").first?.ref == "e11")
        #expect(ElementFinder.find(nodes, query: "the search box").first?.ref == "e10")
        #expect(ElementFinder.find(nodes, query: "cart link").first?.ref == "e12")
        #expect(ElementFinder.find(nodes, query: "subscri").first?.ref == "e13")
        #expect(ElementFinder.find(nodes, query: "kite browser").first?.line == "heading \"Kite Browser\"")
    }

    @Test func skipsGenericNodesAndNonsense() {
        #expect(!ElementFinder.find(nodes, query: "add to cart").contains { $0.ref == "e15" })
        #expect(ElementFinder.find(nodes, query: "zebra").isEmpty)
        #expect(ElementFinder.find(nodes, query: "the of").isEmpty)
    }

    @Test func roleWordsAloneListThatRole() {
        let buttons = ElementFinder.find(nodes, query: "button")
        #expect(Set(buttons.map(\.ref)) == ["e11", "e13"])
    }

    @Test func outlineCanListOnlyControls() {
        let text = AccessibilityOutline.render(nodes, interactiveOnly: true).text
        #expect(!text.contains("heading"))
        #expect(text.split(separator: "\n").allSatisfy { $0.hasPrefix("- ") })
        #expect(text.contains("[ref=e11]"))
    }
}

@Suite struct TabActivityTests {
    @Test func collectsConsoleMessagesAndErrors() throws {
        var activity = TabActivity()
        activity.ingest(method: "Runtime.consoleAPICalled", params: [
            "type": "log", "args": [["type": "string", "value": "hello"], ["type": "number", "value": 42]],
            "stackTrace": ["callFrames": [["url": "https://a.example/app.js", "lineNumber": 9]]],
        ])
        activity.ingest(method: "Runtime.consoleAPICalled", params: ["type": "warning", "args": [["type": "object", "description": "Object"]]])
        activity.ingest(method: "Runtime.exceptionThrown", params: [
            "exceptionDetails": ["text": "Uncaught", "exception": ["description": "TypeError: x is undefined"]],
        ])
        #expect(activity.console.map(\.level) == ["log", "warning", "exception"])
        #expect(activity.console[0].text == "hello 42")
        #expect(activity.console[0].source == "https://a.example/app.js:10")

        let errors = activity.consoleReport(pattern: nil, onlyErrors: true, limit: 10)
        #expect(errors.contains("TypeError") && !errors.contains("hello"))
        #expect(activity.consoleReport(pattern: "HEL+O", onlyErrors: false, limit: 10).hasPrefix("1 message:"))
        #expect(activity.consoleReport(pattern: "nothing", onlyErrors: false, limit: 10) == "No console messages match.")
        activity.clearConsole()
        #expect(activity.consoleReport(pattern: nil, onlyErrors: false, limit: 10).hasPrefix("No console messages since"))
    }

    @Test func tracksRequestsAndIdleness() {
        var activity = TabActivity()
        let start = Date(timeIntervalSince1970: 1000)
        activity.ingest(method: "Network.requestWillBeSent",
                        params: ["requestId": "1", "request": ["url": "https://a.example/api", "method": "POST"], "type": "Fetch"], now: start)
        activity.ingest(method: "Network.requestWillBeSent",
                        params: ["requestId": "2", "request": ["url": "https://cdn.example/x.png", "method": "GET"]], now: start)
        #expect(activity.inFlight == 2)
        #expect(!activity.isNetworkIdle(now: start.addingTimeInterval(5)))
        activity.ingest(method: "Network.responseReceived", params: ["requestId": "1", "response": ["status": 201]])
        activity.ingest(method: "Network.loadingFinished", params: ["requestId": "1"], now: start.addingTimeInterval(1))
        activity.ingest(method: "Network.loadingFailed", params: ["requestId": "2", "errorText": "net::ERR_BLOCKED"], now: start.addingTimeInterval(1))
        #expect(activity.inFlight == 0)
        #expect(!activity.isNetworkIdle(now: start.addingTimeInterval(1.2)))
        #expect(activity.isNetworkIdle(now: start.addingTimeInterval(1.6)))

        let report = activity.networkReport(urlPattern: "api", limit: 10)
        #expect(report.contains("POST 201 Fetch https://a.example/api"))
        #expect(!report.contains("cdn"))
        #expect(activity.networkReport(urlPattern: nil, limit: 10).contains("failed (net::ERR_BLOCKED)"))
    }

    @Test func aNewDocumentEndsOldRequests() {
        var activity = TabActivity()
        activity.ingest(method: "Network.requestWillBeSent", params: ["requestId": "1", "request": ["url": "https://a.example/long"]])
        activity.ingest(method: "Page.frameNavigated", params: ["frame": ["id": "F", "url": "https://b.example"]])
        #expect(activity.inFlight == 0)
        // Child frames navigating don't.
        activity.ingest(method: "Network.requestWillBeSent", params: ["requestId": "2", "request": ["url": "https://b.example/x"]])
        activity.ingest(method: "Page.frameNavigated", params: ["frame": ["id": "G", "parentId": "F"]])
        #expect(activity.inFlight == 1)
    }

    @Test func remembersTheOpenDialog() {
        var activity = TabActivity()
        activity.ingest(method: "Page.javascriptDialogOpening", params: ["type": "confirm", "message": "Leave?", "url": "https://a.example"])
        #expect(activity.dialog == TabActivity.Dialog(kind: "confirm", message: "Leave?", defaultPrompt: nil))
        activity.ingest(method: "Page.javascriptDialogClosed", params: ["result": true])
        #expect(activity.dialog == nil)
        let kept = activity.ingest(method: "Page.loadEventFired", params: [:])
        #expect(!kept)
    }

    @Test func staysBounded() {
        var activity = TabActivity()
        for i in 0..<(TabActivity.consoleCapacity + 50) {
            activity.ingest(method: "Log.entryAdded", params: ["entry": ["level": "info", "text": .string("m\(i)")]])
        }
        #expect(activity.console.count == TabActivity.consoleCapacity)
        #expect(activity.console.last?.text == "m\(TabActivity.consoleCapacity + 49)")
    }
}

@Suite struct BrowserStateAutomationTests {
    private func makeState() -> (BrowserState, UUID, UUID) {
        var state = BrowserState(spaces: [Space(name: "Home", icon: "🏠", theme: Theme.presets[0])])
        let a = state.openTab(url: URL(string: "https://a.example"))
        let b = state.openTab(url: URL(string: "https://b.example"))
        return (state, a, b)
    }

    @Test func claudeSpaceIsMadeOnceInTheBackground() {
        var (state, _, _) = makeState()
        let selected = state.selectedSpaceID
        let first = state.claudeSpace(theme: Theme.presets[1])
        #expect(state.selectedSpaceID == selected)
        #expect(state.claudeSpace(theme: Theme.presets[1]) == first)
        #expect(state.spaces.count == 2)
        #expect(state.space(matching: "claude") == 1)
        #expect(state.space(matching: first.uuidString) == 1)
        #expect(state.space(matching: "nope") == nil)
    }

    @Test func movesTabsIntoFolders() {
        var (state, a, b) = makeState()
        let folder = state.createFolder(name: "Reading", inSpace: 0)
        #expect(state.folder(matching: "reading")?.folder.id == folder)
        do { let moved = state.moveTab(a, toFolder: folder); #expect(moved) }
        #expect(state.folders(inSpace: 0).first?.items.map(\.id) == [a])
        #expect(state.selectedSpace.tabs.map(\.id) == [b])
        #expect(state.location(of: a)?.section == .pinned)

        // Nested folders, and a pinned tab moving between folders.
        let inner = state.createFolder(name: "Inner", inSpace: 0)
        do { let moved = state.moveTab(a, toFolder: inner); #expect(moved) }
        #expect(state.folders(inSpace: 0).first { $0.id == folder }?.items.isEmpty == true)
        do { let moved = state.moveTab(UUID(), toFolder: folder); #expect(!moved) }
        do { let moved = state.moveTab(b, toFolder: UUID()); #expect(!moved) }
    }

    @Test func movingAcrossSpacesFixesTheOldSelection() {
        var (state, a, b) = makeState()
        let other = state.addBackgroundSpace(name: "Work", icon: "💼", theme: Theme.presets[2])
        let folder = state.createFolder(name: "Inbox", inSpace: state.spaceIndex(other)!)
        state.select(tab: b)
        do { let moved = state.moveTab(b, toFolder: folder); #expect(moved) }
        #expect(state.spaces[0].selectedTabID == a)
    }
}

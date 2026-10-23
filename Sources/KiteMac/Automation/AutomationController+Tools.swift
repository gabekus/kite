import AppKit
import KiteCore

// The tools themselves. Every page tool works on background tabs without
// bringing them forward; only a confirmation sheet shows the tab.

extension AutomationController {
    func run(_ command: AutomationCommand, connection: Int) async throws -> ToolOutput {
        switch command {
        case .tabsContext:
            return .text(AutomationReport.tabs(tabList()))
        case let .tabsCreate(url, active, placement):
            return try await openTab(url, active: active, placement: placement, connection: connection)
        case .navigate(nil, let url, true):
            return try await openTab(url, active: false, placement: settings.useClaudeSpace ? .claudeSpace : .currentSpace,
                                     connection: connection)
        case .tabsClose(let string):
            return try await closeTab(string)
        case .switchTab(let string):
            let tab = try resolveTab(string)
            store.mutate { $0.select(tab: tab.id) }
            return report("Switched to the tab.", tab.id)
        case let .resizeWindow(width, height):
            return try resizeWindow(width: width, height: height)
        case .listDownloads:
            return .text(downloadsReport())
        case .listSpaces, .switchSpace, .createSpace, .pinTab, .createFolder, .moveToFolder:
            return try kiteCommand(command)
        default:
            return try await pageCommand(command, connection: connection)
        }
    }

    // MARK: Page tools

    private func pageCommand(_ command: AutomationCommand, connection: Int) async throws -> ToolOutput {
        let tabArgument: String?
        switch command {
        case .readPage(let tab, _, _), .find(let tab, _), .getPageText(let tab, _), .screenshot(let tab), .click(let tab, _),
             .type(let tab, _, _, _), .formInput(let tab, _, _), .computer(let tab, _), .javascript(let tab, _),
             .waitFor(let tab, _, _), .handleDialog(let tab, _, _), .uploadFile(let tab, _, _), .readConsole(let tab, _, _, _, _),
             .readNetwork(let tab, _, _, _), .navigate(let tab, _, _):
            tabArgument = tab
        default:
            throw AutomationError(.failed, "\(command.tool.rawValue) isn't a page tool.")
        }
        let tab = try resolveTab(tabArgument)
        markControlled(tab.id, connection: connection)
        guard let host else { throw AutomationError(.failed, "Kite has no window open.") }
        let page = host.automationPage(for: tab)
        guard let driver = page.automation else { throw AutomationError(.unsupported, "This tab's engine can't be automated.") }
        let actions = driver as? PageActions
        if let actions { try await track(tab.id, page: page, actions: actions) }
        func act() throws -> PageActions {
            guard let actions else { throw WebKitAutomation.unsupported }
            return actions
        }

        // A page with a dialog open is frozen until someone answers it.
        if let dialog = activities[tab.id]?.dialog {
            switch command {
            case .handleDialog, .screenshot, .readConsole, .readNetwork: break
            default:
                throw AutomationError(.failed, "A \(dialog.kind) dialog is open in this tab: "
                    + UntrustedContent.wrap(dialog.message, source: "dialog") + "\nAnswer it with handle_dialog first.")
            }
        }

        switch command {
        case let .readPage(_, limit, interactiveOnly):
            let (outline, text) = try await driver.read(interactiveOnly: interactiveOnly)
            let current = store.state.tab(tab.id) ?? tab
            return .text(AutomationReport.page(tab: tab.id, url: current.url, title: current.displayTitle,
                                               outline: outline, text: text, textLimit: limit))

        case .find(_, let query):
            let nodes = try await act().allNodes()
            return .text(AutomationReport.find(ElementFinder.find(nodes, query: query), query: query, url: store.state.tab(tab.id)?.url))

        case .getPageText(_, let limit):
            let (source, text) = try await driver.mainText()
            let current = store.state.tab(tab.id) ?? tab
            return .text("Main text from <\(source)>.\n" + AutomationReport.page(
                tab: tab.id, url: current.url, title: current.displayTitle, outline: nil, text: text, textLimit: limit))

        case .screenshot:
            return screenshotOutput(try await driver.screenshot(), tab: tab.id)

        case .click(_, let target):
            let element = try await act().locate(target)
            try await authorize(.click(element.description), tab: tab)
            let actions = try act()
            try await untilDialog(tab.id) { try await actions.click(element) }
            await settle(tab.id)
            return report("Clicked \(Self.name(target)).", tab.id)

        case let .type(_, target, text, submit):
            let element: LocatedElement
            if let target {
                element = try await act().locate(target)
            } else if let focused = try await act().focusedElement() {
                element = focused
            } else {
                throw AutomationError(.notFound, "Nothing on the page has keyboard focus. Pass a ref or selector.")
            }
            try await authorize(.type(element.description, text: text, submit: submit), tab: tab)
            let actions = try act()
            try await untilDialog(tab.id) { try await actions.type(text, into: element, submit: submit) }
            if submit { await settle(tab.id) }
            let into = target.map { " into \(Self.name($0))" } ?? ""
            return report("Typed \(text.count) characters\(into)\(submit ? " and pressed Return" : "").", tab.id)

        case let .formInput(_, target, value):
            let element = try await act().locate(target)
            let text = value.stringValue ?? value.boolValue.map(String.init) ?? value.doubleValue.map { String(format: "%g", $0) } ?? ""
            try await authorize(.formInput(element.description, value: text), tab: tab)
            let actions = try act()
            var result = ""
            try await untilDialog(tab.id) { result = try await actions.setValue(value, on: element) }
            let shown = AutomationPolicy.isSensitiveField(element.description) ? "(hidden)" : UntrustedContent.wrap(result, source: "form value")
            return report("Set \(Self.name(target)). Its value is now \(shown)", tab.id)

        case let .computer(_, action):
            return try await computer(action, tab: tab, driver: driver, actions: actions)

        case .javascript(_, let code):
            try await authorize(.javascript(code: code, allowedInSettings: settings.allowJavaScript), tab: tab)
            let actions = try act()
            var result = "(a dialog opened before the script finished)"
            try await untilDialog(tab.id) { result = try await actions.run(code) }
            let cut = result.count > 50_000 ? String(result.prefix(50_000)) + "… (cut at 50000 characters)" : result
            return .text("Result:\n" + UntrustedContent.wrap(cut, source: store.state.tab(tab.id)?.url?.absoluteString ?? "page"))

        case let .waitFor(_, condition, timeout):
            return try await waitFor(condition, timeout: timeout, tab: tab.id, actions: act())

        case let .handleDialog(_, accept, promptText):
            guard let dialog = activities[tab.id]?.dialog else { throw AutomationError(.notFound, "No dialog is open in this tab.") }
            try await authorize(.answerDialog(kind: dialog.kind, message: dialog.message, accept: accept), tab: tab)
            try await act().answerDialog(accept: accept, promptText: promptText)
            activities[tab.id]?.dialogClosed()
            await settle(tab.id)
            return report("\(accept ? "Accepted" : "Dismissed") the \(dialog.kind) dialog.", tab.id)

        case let .uploadFile(_, target, paths):
            let files = try paths.map { path -> String in
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                    throw AutomationError(.notFound, "\(path) isn't a file on this Mac.")
                }
                return url.path
            }
            let element = try await act().locate(target)
            guard element.description.tag == "input", element.description.type == "file" else {
                throw AutomationError(.invalidArguments, "\(Self.name(target)) isn't a file input.")
            }
            try await authorize(.uploadFiles(files, into: element.description), tab: tab)
            try await act().setFiles(files, on: element)
            return report("Attached \(files.count) file\(files.count == 1 ? "" : "s").", tab.id)

        case let .readConsole(_, pattern, onlyErrors, limit, clear):
            guard actions != nil else { throw WebKitAutomation.unsupported }
            let text = activities[tab.id]?.consoleReport(pattern: pattern, onlyErrors: onlyErrors, limit: limit) ?? "No console messages."
            if clear { activities[tab.id]?.clearConsole() }
            return .text(UntrustedContent.wrap(text, source: "console of tab \(tab.id.uuidString)"))

        case let .readNetwork(_, pattern, limit, clear):
            guard actions != nil else { throw WebKitAutomation.unsupported }
            let text = activities[tab.id]?.networkReport(urlPattern: pattern, limit: limit) ?? "No requests."
            if clear { activities[tab.id]?.clearNetwork() }
            return .text(UntrustedContent.wrap(text, source: "network of tab \(tab.id.uuidString)"))

        case let .navigate(_, string, _):
            switch string.lowercased() {
            case "back":
                page.goBack()
            case "forward":
                page.goForward()
            default:
                let url = try resolveURL(string)
                try await authorize(.navigate(url), tab: tab)
                page.load(url)
            }
            await settle(tab.id, startDelay: 0.3)
            return report("Loaded.", tab.id)

        default:
            throw AutomationError(.failed, "\(command.tool.rawValue) isn't a page tool.")
        }
    }

    private func computer(_ action: ComputerAction, tab: BrowserTab, driver: PageAutomation, actions: PageActions?) async throws -> ToolOutput {
        if case .screenshot = action { return screenshotOutput(try await driver.screenshot(), tab: tab.id) }
        guard let actions else { throw WebKitAutomation.unsupported }

        /// A location's point, plus the element there for the policy.
        func resolve(_ location: ComputerAction.Location) async throws -> (ViewportPoint, LocatedElement?) {
            switch location {
            case .point(let point): return (point, try await actions.element(at: point))
            case .target(let target):
                let element = try await actions.locate(target)
                return (ViewportPoint(x: element.point.x, y: element.point.y), element)
            }
        }

        switch action {
        case .screenshot:
            fatalError("handled above")
        case let .click(location, button, count, modifiers):
            let (point, element) = try await resolve(location)
            // Right-clicks only open a menu; the rest go through the same checks as click.
            if button != .right, let element { try await authorize(.click(element.description), tab: tab) }
            try await untilDialog(tab.id) {
                if case .target = location, let element, !element.isHittable, button == .left, count == 1, modifiers.isEmpty {
                    try await actions.click(element)
                } else {
                    try await actions.click(at: point, button: button, count: count, modifiers: modifiers)
                }
            }
            await settle(tab.id)
            return report("\(button == .left ? "" : button.rawValue.capitalized + "-")\(["", "C", "Double-c", "Triple-c"][count])licked at (\(Int(point.x)), \(Int(point.y))).", tab.id)
        case .hover(let location):
            let (point, _) = try await resolve(location)
            try await actions.hover(point)
            return report("Moved the pointer to (\(Int(point.x)), \(Int(point.y))).", tab.id)
        case let .scroll(location, direction, amount):
            var point: ViewportPoint?
            if let location { point = try await resolve(location).0 }
            try await actions.scroll(at: point, direction: direction, amount: amount)
            try? await Task.sleep(for: .milliseconds(150))
            return report("Scrolled \(direction.rawValue) \(amount).", tab.id)
        case let .drag(from, to):
            try await actions.drag(from: from, to: to)
            return report("Dragged from (\(Int(from.x)), \(Int(from.y))) to (\(Int(to.x)), \(Int(to.y))).", tab.id)
        case let .key(chords, times):
            let focused = try await actions.focusedElement()
            try await authorize(.keys(chords, focused: focused?.description), tab: tab)
            try await untilDialog(tab.id) { for _ in 0..<times { try await actions.press(chords) } }
            if chords.contains(where: \.isEnter) { await settle(tab.id) }
            return report("Pressed \(chords.map(Self.keyName).joined(separator: " "))\(times > 1 ? " ×\(times)" : "").", tab.id)
        case .type(let text):
            let focused = try await actions.focusedElement()
            try await authorize(.type(focused?.description, text: text, submit: false), tab: tab)
            try await actions.insertText(text)
            return report("Typed \(text.count) characters.", tab.id)
        case .wait(let seconds):
            try await Task.sleep(for: .seconds(seconds))
            return report("Waited \(seconds) seconds.", tab.id)
        case let .zoom(x0, y0, x1, y1):
            let image = try await actions.zoom(x0: x0, y0: y0, x1: x1, y1: y1)
            return ToolOutput(content: [
                .image(base64: image.png.base64EncodedString(), mimeType: "image/png"),
                .text("Region (\(Int(x0)), \(Int(y0)))–(\(Int(x1)), \(Int(y1))) at full resolution (\(image.width)×\(image.height)). Click with the screenshot's coordinates, not this image's."),
            ])
        }
    }

    private func waitFor(_ condition: WaitCondition, timeout: TimeInterval, tab id: UUID, actions: PageActions) async throws -> ToolOutput {
        let met: Bool
        switch condition {
        case .load:
            if store.pages[id]?.isLoading != true, (try? await actions.readyStateIsComplete()) == true {
                met = true
            } else {
                met = await waitForEvent(id, timeout: timeout) { method, _, _ in method == "Page.loadEventFired" }
            }
        case .navigation:
            var navigated = false
            met = await waitForEvent(id, timeout: timeout) { method, params, _ in
                if method == "Page.frameNavigated", params["frame"]?["parentId"] == nil { navigated = true }
                return navigated && method == "Page.loadEventFired"
            }
        case .selector(let selector):
            met = try await actions.waitFor(selector: selector, text: nil, timeout: timeout)
        case .text(let text):
            met = try await actions.waitFor(selector: nil, text: text, timeout: timeout)
        case .networkIdle:
            met = await waitForEvent(id, timeout: timeout) { _, _, activity in activity.isNetworkIdle() }
        }
        guard met else {
            throw AutomationError(.timeout, "Still waiting after \(Int(timeout * 1000)) ms. Take a screenshot or read_page to see why.")
        }
        return report("Done waiting.", id)
    }

    // MARK: Tabs and windows

    private func openTab(_ string: String?, active: Bool, placement: TabPlacement, connection: Int) async throws -> ToolOutput {
        guard let host else { throw AutomationError(.failed, "Kite has no window open.") }
        let url = try string.map(resolveURL)
        if let url, case .deny(let reason) = AutomationPolicy.evaluate(.navigate(url), host: nil) {
            throw AutomationError(.denied, reason)
        }
        let spaceID: UUID?
        switch placement {
        case .currentSpace: spaceID = nil
        case .claudeSpace: spaceID = store.mutate { $0.claudeSpace(theme: Theme.presets[Theme.presets.count - 1]) }
        case .space(let name):
            guard let index = store.state.space(matching: name) else {
                throw AutomationError(.notFound, "There's no space called \(name). Call list_spaces.")
            }
            spaceID = store.state.spaces[index].id
        }
        let id = store.mutate { $0.openTab(url: url, in: spaceID, select: false) }
        if active { store.mutate { $0.select(tab: id) } }
        claudeOpened.insert(id)
        markControlled(id, connection: connection)
        guard let tab = store.state.tab(id) else { throw AutomationError(.failed, "Couldn't open a tab.") }
        if let url {
            do {
                try await authorize(.navigate(url), tab: tab)
            } catch {
                host.closeAutomatedTab(id)
                throw error
            }
            _ = host.automationPage(for: tab)
            await settle(id, startDelay: 0.3)
        }
        let space = store.state.location(of: id)?.space.map { store.state.spaces[$0].name } ?? ""
        return report("Opened a new \(active ? "" : "background ")tab in \(space).", id)
    }

    private func closeTab(_ string: String) async throws -> ToolOutput {
        let tab = try resolveTab(string)
        if !claudeOpened.contains(tab.id) {
            try await require(ConfirmationRequest(
                action: "close a tab it didn't open",
                detail: "Tab: “\(tab.displayTitle)”. You can reopen it with ⇧⌘T."), tab: tab.id)
        }
        host?.closeAutomatedTab(tab.id)
        claudeOpened.remove(tab.id)
        return .text("Closed tab \(tab.id.uuidString).")
    }

    private func resizeWindow(width: Int, height: Int) throws -> ToolOutput {
        guard let window = host?.window else { throw AutomationError(.failed, "Kite has no window open.") }
        var frame = window.frame
        let visible = window.screen?.visibleFrame ?? frame
        frame.size = NSSize(width: min(CGFloat(width), visible.width), height: min(CGFloat(height), visible.height))
        frame.origin.y = min(max(frame.origin.y, visible.minY), visible.maxY - frame.height)
        frame.origin.x = min(max(frame.origin.x, visible.minX), visible.maxX - frame.width)
        window.setFrame(frame, display: true, animate: false)
        return .text("The window is now \(Int(window.frame.width))×\(Int(window.frame.height)) points.")
    }

    // MARK: Kite tools

    private func kiteCommand(_ command: AutomationCommand) throws -> ToolOutput {
        func spaceIndex(_ name: String) throws -> Int {
            guard let index = store.state.space(matching: name) else {
                throw AutomationError(.notFound, "There's no space called \(name). Call list_spaces.")
            }
            return index
        }
        switch command {
        case .listSpaces:
            let state = store.state
            return .text(AutomationReport.spaces(state.spaces.indices.map { i in
                let space = state.spaces[i]
                return AutomationReport.SpaceSummary(
                    id: space.id, name: space.name, icon: space.icon, pinned: space.pinned.count, tabs: space.tabs.count,
                    folders: state.folders(inSpace: i).map(\.name), isFront: space.id == state.selectedSpaceID)
            }))
        case .switchSpace(let name):
            let index = try spaceIndex(name)
            store.mutate { $0.selectSpace(at: index) }
            return .text("Switched to \(store.state.spaces[index].name).")
        case let .createSpace(name, icon):
            let count = store.state.spaces.count
            let id = store.mutate {
                $0.addBackgroundSpace(name: name, icon: icon ?? "🗂️", theme: Theme.presets[count % Theme.presets.count])
            }
            return .text("Made space \(id.uuidString) (not switched to it).")
        case let .pinTab(string, pinned):
            let tab = try resolveTab(string)
            switch store.state.location(of: tab.id)?.section {
            case .favorite?:
                throw AutomationError(.invalidArguments, "That tab is a favorite; favorites can't be pinned or unpinned.")
            case .pinned? where !pinned, .unpinned? where pinned:
                store.mutate { $0.togglePin(tab: tab.id) }
            default:
                break
            }
            return .text("The tab is \(pinned ? "pinned" : "unpinned").")
        case let .createFolder(name, spaceName):
            let index = try spaceName.map(spaceIndex) ?? store.state.selectedSpaceIndex
            let id = store.mutate { $0.createFolder(name: name, inSpace: index) }
            return .text("Made folder \(id.uuidString) in \(store.state.spaces[index].name)'s pinned tabs.")
        case let .moveToFolder(string, folderName):
            let tab = try resolveTab(string)
            guard let (_, folder) = store.state.folder(matching: folderName) else {
                throw AutomationError(.notFound, "There's no folder called \(folderName). Call list_spaces to see folders.")
            }
            guard store.mutate({ $0.moveTab(tab.id, toFolder: folder.id) }) else {
                throw AutomationError(.invalidArguments, "That tab can't move into a folder (favorites stay in the favorites grid).")
            }
            return .text("Moved the tab into \(folder.name).")
        default:
            throw AutomationError(.failed, "\(command.tool.rawValue) isn't a Kite tool.")
        }
    }

    // MARK: Reports

    func report(_ action: String, _ id: UUID) -> ToolOutput {
        let tab = store.state.tab(id)
        var text = AutomationReport.afterAction(action, tab: id, url: tab?.url, title: tab?.displayTitle ?? "")
        if let dialog = activities[id]?.dialog {
            text += "\nA \(dialog.kind) dialog is now open: " + UntrustedContent.wrap(dialog.message, source: "dialog")
                + "\nAnswer it with handle_dialog."
        }
        return .text(text)
    }

    private func screenshotOutput(_ image: Screenshot, tab id: UUID) -> ToolOutput {
        ToolOutput(content: [
            .image(base64: image.png.base64EncodedString(), mimeType: "image/png"),
            .text("Screenshot of tab \(id.uuidString), \(image.width)×\(image.height). Its pixels are the coordinates computer clicks use."),
        ])
    }

    private func downloadsReport() -> String {
        guard !downloads.isEmpty else { return "No downloads since Claude was allowed to control Kite." }
        let lines = downloads.values.sorted { $0.id < $1.id }.map { download -> String in
            let size = download.totalBytes > 0 ? "\(download.receivedBytes)/\(download.totalBytes) bytes" : "\(download.receivedBytes) bytes"
            return "- \(download.state), \(size): \(download.path) (from \(download.url))"
        }
        return UntrustedContent.wrap(lines.joined(separator: "\n"), source: "downloads")
    }

    func tabList() -> [AutomationReport.Tab] {
        let state = store.state
        let front = state.selectedTab?.id
        var tabs = state.favorites.map {
            AutomationReport.Tab(id: $0.id, title: $0.displayTitle, url: $0.url, space: "Favorites", section: "favorite", isFront: $0.id == front)
        }
        for space in state.spaces {
            tabs += space.pinned.map {
                AutomationReport.Tab(id: $0.id, title: $0.displayTitle, url: $0.url, space: space.name, section: "pinned", isFront: $0.id == front)
            }
            tabs += space.tabs.map {
                AutomationReport.Tab(id: $0.id, title: $0.displayTitle, url: $0.url, space: space.name, section: "tab", isFront: $0.id == front)
            }
        }
        return tabs
    }

    func resolveURL(_ string: String) throws -> URL {
        guard let url = URLInput.resolve(string, engine: store.state.searchEngine) else {
            throw AutomationError(.invalidArguments, "\"\(string)\" isn't a URL.")
        }
        return url
    }

    static func name(_ target: AutomationTarget) -> String {
        switch target {
        case .ref(let ref): ref
        case .selector(let selector): "the element matching \(selector)"
        }
    }

    static func keyName(_ chord: KeyChord) -> String {
        var parts: [String] = []
        if chord.modifiers.contains(.control) { parts.append("ctrl") }
        if chord.modifiers.contains(.alt) { parts.append("alt") }
        if chord.modifiers.contains(.shift) { parts.append("shift") }
        if chord.modifiers.contains(.meta) { parts.append("cmd") }
        return (parts + [chord.key == " " ? "Space" : chord.key]).joined(separator: "+")
    }
}

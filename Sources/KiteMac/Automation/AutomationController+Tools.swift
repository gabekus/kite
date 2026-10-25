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
        case .networkLog(let query):
            return .text(network.report(try networkQuery(query), recording: isRecordingNetwork))
        case let .networkRequest(id, body, maxBodyLength):
            return try await networkRequest(id, body: body, maxBodyLength: maxBodyLength)
        case let .exportHAR(query, bodies):
            return try await exportHAR(try networkQuery(query), bodies: bodies)
        case .listSpaces, .switchSpace, .createSpace, .pinTab, .createFolder, .moveToFolder:
            return try kiteCommand(command)
        case .ui(let inspection):
            guard UIDiagnostics.isEnabled else {
                throw AutomationError(.disabled, "Diagnostics for Claude is off. Ask the user to turn it on in the Kite menu "
                    + "(test builds: launch with KITE_DIAGNOSTICS=1 and a KITE_SUPPORT_PATH profile).")
            }
            return try await UIDiagnostics.shared.run(inspection)
        case .batch(let steps):
            return await runBatch(steps, connection: connection)
        default:
            return try await pageCommand(command, connection: connection)
        }
    }

    // MARK: Page tools

    private func pageCommand(_ command: AutomationCommand, connection: Int) async throws -> ToolOutput {
        let tabArgument: String?
        switch command {
        case .readPage(let tab, _, _, _), .find(let tab, _), .getPageText(let tab, _), .screenshot(let tab, _), .click(let tab, _),
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

        // A page with a dialog open is frozen until someone answers it.
        if let dialog = activities[tab.id]?.dialog {
            switch command {
            case .handleDialog, .screenshot, .readConsole, .readNetwork: break
            default:
                throw AutomationError(.failed, "A \(dialog.kind) dialog is open in this tab: "
                    + UntrustedContent.wrap(dialog.message, source: "dialog") + "\nAnswer it with handle_dialog first.")
            }
        }

        let output = try await pageAction(command, tab: tab, page: page, driver: driver, actions: actions)
        // After something that can change the page, say what changed since Claude's last read
        // (only when there is a last read, so a tab that's never been read costs nothing extra).
        switch command {
        case .click, .type, .formInput, .handleDialog, .navigate, .computer(_, .click), .computer(_, .key), .computer(_, .type):
            return await withChanges(output, tab: tab.id, driver: driver)
        default:
            return output
        }
    }

    private func pageAction(_ command: AutomationCommand, tab: BrowserTab, page: WebPage, driver: PageAutomation,
                            actions: PageActions?) async throws -> ToolOutput {
        func act() throws -> PageActions {
            guard let actions else { throw WebKitAutomation.unsupported }
            return actions
        }

        switch command {
        case let .readPage(_, limit, interactiveOnly, changesOnly):
            let (outline, text) = try await driver.read(interactiveOnly: interactiveOnly)
            let current = store.state.tab(tab.id) ?? tab
            let snapshot = PageDiff.Snapshot(url: current.url?.absoluteString ?? "", outline: outline ?? "", text: text)
            defer { if !interactiveOnly { snapshots[tab.id] = snapshot } }
            if changesOnly, !interactiveOnly, let previous = snapshots[tab.id] {
                if let changes = PageDiff.report(from: previous, to: snapshot) {
                    return .text("Changes since your last read of tab \(tab.id.uuidString):\n"
                        + UntrustedContent.wrap(changes, source: current.url?.absoluteString ?? "page"))
                }
                // Too much changed for a diff to help: fall through to the whole page.
            }
            // A first "changes only" read has nothing to compare with: it only records the baseline,
            // since whoever asked for changes wanted little back. read_page or find show the page.
            if changesOnly && !interactiveOnly {
                return .text("No earlier read of this tab, so this one is now the baseline (\(snapshot.outline.count) outline lines, "
                    + "\(snapshot.text.count) lines of text). Later changes_only reads and actions report differences from it. "
                    + "Use find or read_page to see the page itself.")
            }
            return .text(AutomationReport.page(tab: tab.id, url: current.url, title: current.displayTitle,
                                               outline: outline, text: text, textLimit: limit))

        case .find(_, let query):
            let nodes = try await act().allNodes()
            var matches = ElementFinder.find(nodes, query: query)
            // Jev reads meaning, not just words ("checkout" finds "Proceed to payment"), in well under a second.
            if let jev {
                let candidates = ElementFinder.candidates(nodes, query: query, limit: Jev.maxOptions)
                if candidates.count > 1, let answers = try? await jev.ask(state: query, questions: Jev.finding(query, among: candidates)) {
                    let picked = Jev.found(answers, among: candidates)
                    let refs = Set(picked.map(\.ref))
                    matches = Array((picked + matches.filter { !refs.contains($0.ref) }).prefix(20))
                }
            }
            return .text(AutomationReport.find(matches, query: query, url: store.state.tab(tab.id)?.url))

        case .getPageText(_, let limit):
            let (source, text) = try await driver.mainText()
            let current = store.state.tab(tab.id) ?? tab
            return .text("Main text from <\(source)>.\n" + AutomationReport.page(
                tab: tab.id, url: current.url, title: current.displayTitle, outline: nil, text: text, textLimit: limit))

        case .screenshot(_, let format):
            return screenshotOutput(try await driver.screenshot(format: format), tab: tab.id)

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
            // Pages often keep a hidden copy of a field (a search box behind a button); typing there does nothing visible.
            let hidden = element.isHittable ? "" : " That field isn't visible on screen (hidden, covered or zero-size), so the page may ignore it; click whatever reveals it first."
            return report("Typed \(text.count) characters\(into)\(submit ? " and pressed Return" : "").\(hidden)", tab.id)

        case let .formInput(_, target, value):
            let element = try await act().locate(target)
            let text = value.stringValue ?? value.boolValue.map(String.init) ?? value.doubleValue.map { String(format: "%g", $0) } ?? ""
            try await authorize(.formInput(element.description, value: text), tab: tab)
            let actions = try act()
            var result = ""
            try await untilDialog(tab.id) { result = try await actions.setValue(value, on: element) }
            let shown = AutomationPolicy.isSensitiveField(element.description) ? "(hidden)" : UntrustedContent.wrap(result, source: "form value")
            var output = report("Set \(Self.name(target)).", tab.id)
            output.content.append(.text("Its value is now \(shown)"))
            return output

        case let .computer(_, action):
            return try await computer(action, tab: tab, driver: driver, actions: actions)

        case .javascript(_, let code):
            try await authorize(.javascript(code: code), tab: tab)
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
        if case .screenshot(let format) = action { return screenshotOutput(try await driver.screenshot(format: format), tab: tab.id) }
        guard let actions else { throw WebKitAutomation.unsupported }
        // Coordinates come from screenshots, which may be scaled down; the page wants CSS pixels.
        let scale = try await actions.screenshotScale()

        /// How a location reads back to Claude: the screenshot coordinates it sent, or the element.
        func describe(_ location: ComputerAction.Location) -> String {
            switch location {
            case .point(let shown): "(\(Self.format(shown.x)), \(Self.format(shown.y)))"
            case .target(let target): Self.name(target)
            }
        }

        /// A location's point, plus the element there for the policy.
        func resolve(_ location: ComputerAction.Location) async throws -> (ViewportPoint, LocatedElement?) {
            switch location {
            case .point(let shown):
                let point = scale.toPage(shown)
                return (point, try await actions.element(at: point))
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
            return report("\(button == .left ? "" : button.rawValue.capitalized + "-")\(["", "C", "Double-c", "Triple-c"][count])licked \(location.isPoint ? "at " : "")\(describe(location)).", tab.id)
        case .hover(let location):
            let (point, _) = try await resolve(location)
            try await actions.hover(point)
            return report("Moved the pointer to \(describe(location)).", tab.id)
        case let .scroll(location, direction, amount):
            var point: ViewportPoint?
            if let location { point = try await resolve(location).0 }
            try await actions.scroll(at: point, direction: direction, amount: amount)
            try? await Task.sleep(for: .milliseconds(150))
            return report("Scrolled \(direction.rawValue) \(amount).", tab.id)
        case let .drag(from, to):
            try await actions.drag(from: scale.toPage(from), to: scale.toPage(to))
            return report("Dragged from \(describe(.point(from))) to \(describe(.point(to))).", tab.id)
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
            let f = scale.factor
            let image = try await actions.zoom(x0: x0 / f, y0: y0 / f, x1: x1 / f, y1: y1 / f)
            return ToolOutput(content: [
                .image(base64: image.data.base64EncodedString(), mimeType: image.format.mimeType),
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

    // MARK: Batches and changes

    /// Runs steps in order, stopping at the first error, and before any step that would ask the user:
    /// that step has to be its own call, so the user sees it on its own.
    private func runBatch(_ steps: [AutomationCommand], connection: Int) async -> ToolOutput {
        var lines: [String] = []
        var images: [ToolOutput.Content] = []
        var failed = false
        var paused = false
        batchTab = nil
        for (index, step) in steps.enumerated() {
            let label = "Step \(index + 1) (\(step.tool.rawValue))"
            do {
                let output = try await AutomationController.$inBatch.withValue(true) {
                    try await run(step, connection: connection)
                }
                images += output.content.filter { if case .image = $0 { true } else { false } }
                lines.append("\(label):\n\(output.text)")
            } catch let needs as NeedsConfirmation {
                lines.append("\(label) not run: it needs the user's OK to \(needs.request.action). Call it on its own and Kite will ask them.")
                paused = true
            } catch let error as AutomationError {
                lines.append("\(label) failed: \(error.message)")
                failed = true
            } catch {
                lines.append("\(label) failed: \(error)")
                failed = true
            }
            if failed || paused {
                let rest = steps.count - index - 1
                if rest == 1 { lines.append("Step \(steps.count) not run.") }
                if rest > 1 { lines.append("Steps \(index + 2)–\(steps.count) not run.") }
                break
            }
        }
        let summary = failed ? "The batch stopped at an error." : paused ? "The batch paused before a step that needs the user's OK."
            : "All \(steps.count) steps ran."
        // Steps report only what they did; where the tab ended up is said once, here.
        if let id = batchTab, let tab = store.state.tab(id) {
            lines.append(AutomationReport.afterAction("", tab: id, url: tab.url, title: tab.displayTitle)
                .trimmingCharacters(in: .whitespaces))
        }
        return ToolOutput(content: [.text(([summary] + lines).joined(separator: "\n\n"))] + images, isError: failed)
    }

    /// Appends what changed on the page since Claude's last read of it, and makes this the new baseline.
    private func withChanges(_ output: ToolOutput, tab id: UUID, driver: PageAutomation) async -> ToolOutput {
        guard let previous = snapshots[id], activities[id]?.dialog == nil,
              let (outline, text) = try? await driver.read(interactiveOnly: false) else { return output }
        let url = store.state.tab(id)?.url?.absoluteString ?? ""
        let snapshot = PageDiff.Snapshot(url: url, outline: outline ?? "", text: text)
        snapshots[id] = snapshot
        var result = output
        if let changes = PageDiff.report(from: previous, to: snapshot) {
            result.content.append(.text("Changes since your last read:\n" + UntrustedContent.wrap(changes, source: url)))
        } else {
            result.content.append(.text("The page changed a lot (or is a new page). Call read_page to see it."))
        }
        return result
    }

    // MARK: Tabs and windows

    private func openTab(_ string: String?, active: Bool, placement: TabPlacement, connection: Int) async throws -> ToolOutput {
        guard let host else { throw AutomationError(.failed, "Kite has no window open.") }
        let url = try string.map(resolveURL)
        if let url, case .deny(let reason) = AutomationPolicy.evaluate(.navigate(url), host: nil) {
            throw AutomationError(.denied, reason)
        }
        // A Claude task's tabs go in its folder in the Claude space, out of the user's way.
        let task = Self.agentTask
        var placement = placement
        if task != nil, case .currentSpace = placement { placement = .claudeSpace }
        let spaceID: UUID?
        switch placement {
        case .currentSpace: spaceID = nil
        case .claudeSpace: spaceID = store.mutate { $0.claudeSpace() }
        case .space(let name):
            guard let index = store.state.space(matching: name) else {
                throw AutomationError(.notFound, "There's no space called \(name). Call list_spaces.")
            }
            spaceID = store.state.spaces[index].id
        }
        let id = store.mutate { $0.openTab(url: url, in: spaceID, select: false) }
        if let task {
            taskOpenedTab?(task, id)
            taskTabs[task, default: []].append(id)
        }
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
        // A task's tabs are pinned in its folder, where closing would only unload them.
        if Self.agentTask == nil || !store.mutate({ $0.removePinnedTab(tab.id) }) {
            host?.closeAutomatedTab(tab.id)
        }
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
        var text: String
        if AutomationController.inBatch {
            batchTab = id
            text = action
        } else {
            text = AutomationReport.afterAction(action, tab: id, url: tab?.url, title: tab?.displayTitle ?? "")
        }
        if let dialog = activities[id]?.dialog {
            text += "\nA \(dialog.kind) dialog is now open: " + UntrustedContent.wrap(dialog.message, source: "dialog")
                + "\nAnswer it with handle_dialog."
        }
        return .text(text)
    }

    private func screenshotOutput(_ image: Screenshot, tab id: UUID) -> ToolOutput {
        ToolOutput(content: [
            .image(base64: image.data.base64EncodedString(), mimeType: image.format.mimeType),
            .text("Screenshot of tab \(id.uuidString), \(image.width)×\(image.height)\(image.scale < 1 ? " (scaled to \(Int((image.scale * 100).rounded()))% of the page)" : ""). Its pixels are the coordinates computer clicks use."),
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

    /// A coordinate as Claude sent it: whole numbers without a decimal point.
    static func format(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
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

private extension ComputerAction.Location {
    var isPoint: Bool {
        if case .point = self { return true }
        return false
    }
}

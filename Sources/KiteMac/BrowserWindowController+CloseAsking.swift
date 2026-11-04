import AppKit
import KiteCore

/// The person's own closes ask the page first, as Chrome does: a page with unsaved changes shows "Leave
/// site?" and the close goes ahead only on Leave (`WebPage.requestClose`, `PageClose`). Automation, AppleScript
/// and the tab switcher close without asking (`close(tab:)`), and so do hibernation and quitting.
extension BrowserWindowController {
    /// What a window close or Clear Today may end: the Peek's page, or a tab's.
    enum CloseTarget: Hashable, Sendable {
        case peek
        case tab(UUID)
    }

    /// Archive Tab as the person does it: ⌘W, the close button, the sidebar's menus, Close Split Pane.
    /// Only this window's own page is asked; a page shown in another window closes without asking there.
    func closeAsking(tab id: UUID) {
        guard let page = pool.loadedPage(id) else { return close(tab: id) }
        page.requestClose { [weak self] outcome in
            guard outcome == .close, let self, store.state.location(of: id) != nil else { return }
            close(tab: id)
        }
    }

    /// Clear Today, asking first: the space's Today tabs go only once every live page with a beforeunload
    /// handler let go. `clear` says which tabs (run on a copy); exactly those are archived afterwards, and the
    /// selection from before asking comes back, since asking brings a background tab forward.
    func clearAsking(inSpace spaceID: UUID, _ clear: (inout BrowserState) -> [BrowserTab],
                     done: @escaping ([BrowserTab]) -> Void) {
        guard !isConfirmingClose else { return NSSound.beep() }
        var preview = store.state
        let ids = clear(&preview).map(\.id)
        let state = store.state
        let frontSpace = state.selectedSpaceID
        let selected = state.spaces.first { $0.id == spaceID }?.selectedTabID
        let archive = { [weak self] in
            guard let self else { return }
            done(store.mutate { $0.archiveToday(ids, inSpace: spaceID, frontSpace: frontSpace, selected: selected) })
        }
        let targets = ids.filter { pool.loadedPage($0) != nil }.map(CloseTarget.tab)
        guard !targets.isEmpty else { return archive() }
        confirmClosing(targets) { proceed in if proceed { archive() } }
    }

    /// Several tabs at once (a tab group's close, Archive Item on a split): asked together, all or nothing,
    /// like a window close; then each closes as Archive Tab does.
    func closeAsking(tabs ids: [UUID]) {
        guard ids.count > 1 else { return ids.forEach(closeAsking(tab:)) }
        guard !isConfirmingClose else { return NSSound.beep() }
        let targets = ids.filter { pool.loadedPage($0) != nil }.map(CloseTarget.tab)
        let closeAll = { [weak self] in
            guard let self else { return }
            for id in ids where store.state.location(of: id) != nil { close(tab: id) }
        }
        guard !targets.isEmpty else { return closeAll() }
        confirmClosing(targets) { proceed in if proceed { closeAll() } }
    }

    /// The rest of `windowShouldClose`. Closing one of several normal windows ends no tabs (they share one
    /// sidebar, and the other windows take their pages), so only a Peek is asked; the last normal window,
    /// an incognito or a Blank window ends its tabs, and every live page with a handler is asked.
    func shouldCloseAfterAsking(_ sender: NSWindow) -> Bool {
        if closeConfirmed { return true }
        if isConfirmingClose { return false }
        var targets: [CloseTarget] = linkPeek == nil ? [] : [.peek]
        if closingEndsTabs { targets += pool.livePages.keys.map(CloseTarget.tab) }
        guard !targets.isEmpty else { return true }
        confirmClosing(targets) { [weak self, weak sender] proceed in
            guard proceed, let self, let sender else { return }
            // Claude may have started working in a tab meanwhile.
            if !isIncognito, hidesInsteadOfClosing?() == true { return sender.orderOut(nil) }
            closeConfirmed = true
            sender.close()
        }
        return false
    }

    private var closingEndsTabs: Bool {
        guard let shared = pool.shared else { return true }
        let others = (NSApp.delegate as? AppDelegate)?.browserControllers ?? []
        // A window hidden while Claude works still keeps the tabs; a closed one doesn't.
        return !others.contains { $0 !== self && !$0.hasClosed && $0.pool.shared === shared }
    }

    private func page(for target: CloseTarget) -> WebPage? {
        switch target {
        case .peek: linkPeek?.page
        case .tab(let id): pool.loadedPage(id)
        }
    }

    /// Chrome's window close: the pages with a beforeunload handler are asked in turn, the ones on screen
    /// first, and `completion(true)` once all let go; the rest are left alone until then, so Cancel keeps
    /// them as they were. A page that let go is closing already: it's dropped at once, and its tab loads
    /// again when shown. Nothing hibernates meanwhile, so no page goes unasked.
    func confirmClosing(_ targets: [CloseTarget], completion: @escaping (Bool) -> Void) {
        isConfirmingClose = true
        pool.holdsPages = true
        let finish = { [weak self] (proceed: Bool) in
            guard let self else { return }
            isConfirmingClose = false
            pool.holdsPages = false
            completion(proceed)
        }
        let group = DispatchGroup()
        var withHandler: Set<CloseTarget> = []
        for target in targets {
            guard let page = page(for: target) else { continue }
            group.enter()
            page.hasBeforeUnloadHandler { has in
                if has { withHandler.insert(target) }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let shown = Set(shownTabIDs.map(CloseTarget.tab) + (linkPeek == nil ? [] : [.peek]))
            var chain = PageCloseChain(asking: PageCloseChain.order(targets, shown: shown, hasHandler: withHandler))
            ask(chain.start(), in: &chain, finish: finish)
        }
    }

    private func ask(_ step: PageCloseChain<CloseTarget>.Step, in chain: inout PageCloseChain<CloseTarget>,
                     finish: @escaping (Bool) -> Void) {
        switch step {
        case .ask(let target):
            guard let page = page(for: target) else {
                var rest = chain
                return ask(rest.answered(.close), in: &rest, finish: finish)
            }
            var waiting = chain
            page.requestClose { [weak self] outcome in
                guard let self else { return }
                let next = waiting.answered(outcome)
                if outcome == .close { drop(target) }
                ask(next, in: &waiting, finish: finish)
            }
        case .proceed:
            finish(true)
        case .stop(let approved):
            // Not while quitting: a new page would hold up the quit, which waits for every page to close.
            let quitting = (NSApp.delegate as? AppDelegate)?.isTerminating == true
            if !quitting, approved.contains(where: { if case .tab(let id) = $0 { shownTabIDs.contains(id) } else { false } }) {
                reloadShownTabs()
            }
            finish(false)
        }
    }

    /// A page that let go is closing: take it out now.
    private func drop(_ target: CloseTarget) {
        switch target {
        case .peek: closeLinkPeek(animated: false)
        case .tab(let id): pool.discard(id, keepHistory: true)
        }
    }
}

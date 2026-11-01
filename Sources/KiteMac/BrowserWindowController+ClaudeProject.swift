import AppKit
import KiteCore

extension BrowserWindowController {
    /// ⌘J in a space routed to a Claude Project: the project's page opens in a Peek over the
    /// tab and the request is posted in its composer, so it lands in the project's own
    /// conversation and the replies show in the Peek. Expanding the Peek keeps it as a tab.
    /// A space with no tab on screen gets the page as a new tab instead.
    ///
    /// The page may first ask the user to sign in to claude.ai; Kite keeps waiting for the
    /// composer while they do. If Send never becomes ready, the text stays in the composer.
    func postToClaudeProject(_ url: URL, message: String) {
        let page: () -> WebPage?
        if let tab = store.state.selectedTab, store.state.visibleTabs.contains(where: { $0.id == tab.id }) {
            openLinkPeek(url, from: tab.id)
            guard let session = linkPeek else { return }
            page = { [weak self, weak session] in
                guard let self, let session, linkPeek === session else { return nil }
                return session.page
            }
        } else {
            store.mutate { $0.openTab(url: url) }
            guard let id = store.state.selectedTab?.id else { return }
            page = { [weak self] in self?.pool.loadedPage(id) }
        }
        let script = ClaudeRoute.composerScript(message: message)
        Task { @MainActor in
            var typedFor = 0
            // About five minutes: long enough to sign in first.
            for _ in 0..<600 {
                try? await Task.sleep(for: .milliseconds(500))
                // The Peek was closed, or the tab.
                guard let current = page() else { return }
                let state = await withCheckedContinuation { done in
                    current.evaluateJavaScript(script) { done.resume(returning: ($0 as? String).flatMap(ClaudeRoute.ComposerState.init)) }
                }
                switch state {
                case .sent?: return
                case .typed?:
                    typedFor += 1
                    // Send still not ready after ten seconds: leave the text for the user to send.
                    if typedFor >= 20 { return }
                case .waiting?, .signIn?, nil:
                    typedFor = 0
                }
            }
        }
    }
}

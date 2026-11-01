import AppKit
import KiteCore

/// Arc Max's Tidy Tabs: the Today divider's Tidy button asks Kite's built-in Claude to group the
/// space's unpinned tabs, then shows each group under a header. Edit › Undo Tidy Tabs puts the
/// list back; a header's Remove Header drops just the header (Undo Remove Header).
extension BrowserWindowController {
    func tidyTabs(inSpace spaceID: UUID) {
        guard TidyTabs.isEnabled(), !store.tidyingSpaceIDs.contains(spaceID) else { return }
        let candidates = store.state.tidyCandidates(inSpace: spaceID)
        guard candidates.count >= TidyTabs.minimumTabs else { return NSSound.beep() }
        let ids = candidates.map(\.id)
        let prompt = TidyTabs.prompt(for: candidates.map { TidyTabs.Item(title: $0.displayTitle, url: $0.url) })
        store.tidyingSpaceIDs.insert(spaceID)
        Task { @MainActor [weak self] in
            let reply: Result<String, Error>
            do { reply = .success(try await TidyTabsClient.ask(prompt)) } catch { reply = .failure(error) }
            guard let self else { return }
            self.store.tidyingSpaceIDs.remove(spaceID)
            switch reply {
            case .failure(TidyTabsClient.Failure.noClaude):
                self.showToast("Tidy Tabs needs Claude Code. Click the Claude button in the sidebar to set it up.")
            case .failure:
                self.showToast("Couldn't tidy tabs")
            case .success(let text):
                self.applyTidy(text, spaceID: spaceID, tabs: ids)
            }
        }
    }

    private func applyTidy(_ reply: String, spaceID: UUID, tabs ids: [UUID]) {
        guard let space = store.state.spaces.first(where: { $0.id == spaceID }) else { return }
        let before = (space.tabs.map(\.id), space.tabGroups)
        guard let groups = TidyTabs.parse(reply, tabCount: ids.count),
              store.mutate({ $0.applyTidy(inSpace: spaceID, tabs: ids, groups: groups) })
        else {
            // Arc's toast when the model found no groups.
            return showToast("No tab groups found")
        }
        registerTodayUndo(spaceID: spaceID, restoring: before, name: "Tidy Tabs")
    }

    func removeTabGroupHeader(_ groupID: UUID) {
        guard let space = store.state.spaces.first(where: { $0.tabGroups.contains { $0.id == groupID } }) else { return }
        let before = (space.tabs.map(\.id), space.tabGroups)
        store.mutate { _ = $0.removeTabGroupHeader(groupID) }
        registerTodayUndo(spaceID: space.id, restoring: before, name: "Remove Header")
    }

    /// Arc's undo titles: "Tidy Tabs" and "Remove Header" (Edit › Undo …).
    private func registerTodayUndo(spaceID: UUID, restoring before: ([UUID], [TodayTabGroup]), name: String) {
        guard let space = store.state.spaces.first(where: { $0.id == spaceID }) else { return }
        let after = (space.tabs.map(\.id), space.tabGroups)
        window?.undoManager?.registerUndo(withTarget: self) { controller in
            controller.store.mutate { $0.restoreToday(inSpace: spaceID, tabs: before.0, groups: before.1) }
            controller.window?.undoManager?.registerUndo(withTarget: controller) { controller in
                controller.store.mutate { $0.restoreToday(inSpace: spaceID, tabs: after.0, groups: after.1) }
            }
            controller.window?.undoManager?.setActionName(name)
        }
        window?.undoManager?.setActionName(name)
    }
}

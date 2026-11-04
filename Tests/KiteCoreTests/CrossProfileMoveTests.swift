import Foundation
import Testing
@testable import KiteCore

@Suite struct CrossProfileMoveTests {
    /// Three spaces. Home and Notes use the default profile, Work uses "Profile 1". Home has Today
    /// tabs t1 t2 and a pinned tab p1; Work has a Today tab w1.
    private func make() -> (BrowserState, home: UUID, notes: UUID, work: UUID, t: [UUID], p1: UUID, w1: UUID) {
        var state = BrowserState(spaces: [
            Space(name: "Home", icon: "🏠", theme: Theme.presets[0]),
            Space(name: "Notes", icon: "📝", theme: Theme.presets[1]),
            Space(name: "Work", icon: "💼", theme: Theme.presets[2]),
        ])
        state.profiles.append(Profile(directory: "Profile 1", name: "Work"))
        state.spaces[2].profile = "Profile 1"
        let home = state.spaces[0].id, notes = state.spaces[1].id, work = state.spaces[2].id
        let t2 = state.openTab(url: URL(string: "https://two.example"), in: home)
        let t1 = state.openTab(url: URL(string: "https://one.example"), in: home)
        let p1 = state.openTab(url: URL(string: "https://pinned.example"), in: home)
        state.dropSidebarItems([p1], on: .pinned(space: home, folder: nil, before: nil))
        let w1 = state.openTab(url: URL(string: "https://work.example"), in: work, select: false)
        state.selectSpace(home)
        return (state, home, notes, work, [t1, t2], p1, w1)
    }

    @Test func sameProfileNeedsNoWarning() {
        let (state, _, notes, _, t, p1, _) = make()
        #expect(state.crossProfileMove([t[0]], on: .unpinned(space: notes, before: nil)) == nil)
        #expect(state.crossProfileMove([t[0]], on: .space(notes)) == nil)
        #expect(state.crossProfileMove([p1], on: .pinned(space: notes, folder: nil, before: nil)) == nil)
    }

    @Test func differentProfileWarnsWithArcsWording() throws {
        let (state, _, _, work, t, _, _) = make()
        let move = try #require(state.crossProfileMove([t[0]], on: .unpinned(space: work, before: nil)))
        #expect(move == CrossProfileMove(spaceName: "Work", tabCount: 1))
        #expect(move.title == "Move tab to Work?")
        #expect(move.message == "Work is using a different Profile, so you might get logged out or lose your progress in this tab.\n\nThis can't be undone!")
        // The space strip's icon too.
        #expect(state.crossProfileMove([t[0]], on: .space(work)) != nil)
        // And back the other way.
        let (back, home, _, _, _, _, w1) = make()
        #expect(back.crossProfileMove([w1], on: .unpinned(space: home, before: nil))?.spaceName == "Home")
    }

    @Test func severalTabsSayTheseTabs() throws {
        let (state, _, _, work, t, _, _) = make()
        let move = try #require(state.crossProfileMove(t, on: .unpinned(space: work, before: nil)))
        #expect(move.tabCount == 2)
        #expect(move.title == "Move tabs to Work?")
        #expect(move.message.contains("lose your progress in these tabs."))
    }

    @Test func pinnedAndUnpinnedTabsBothWarn() {
        let (state, _, _, work, t, p1, _) = make()
        // Pinned to Today, Today to pinned, and pinned to pinned.
        #expect(state.crossProfileMove([p1], on: .unpinned(space: work, before: nil))?.tabCount == 1)
        #expect(state.crossProfileMove([t[0]], on: .pinned(space: work, folder: nil, before: nil))?.tabCount == 1)
        #expect(state.crossProfileMove([p1], on: .pinned(space: work, folder: nil, before: nil))?.tabCount == 1)
    }

    @Test func aFolderCountsItsTabs() throws {
        var (state, _, notes, work, t, p1, _) = make()
        let folder = state.createFolder(name: "F", inSpace: 0)
        state.dropSidebarItems([p1], on: .folder(folder))
        state.dropSidebarItems([t[1]], on: .folder(folder))
        let move = try #require(state.crossProfileMove([folder], on: .pinned(space: work, folder: nil, before: nil)))
        #expect(move.tabCount == 2)
        #expect(move.title == "Move tabs to Work?")
        #expect(state.crossProfileMove([folder], on: .pinned(space: notes, folder: nil, before: nil)) == nil)
        // A tab dropped on a folder row in another profile's space.
        let workFolder = state.createFolder(name: "W", inSpace: 2)
        #expect(state.crossProfileMove([t[0]], on: .folder(workFolder))?.spaceName == "Work")
        // An empty folder has no pages to lose.
        let empty = state.createFolder(name: "Empty", inSpace: 0)
        #expect(state.crossProfileMove([empty], on: .pinned(space: work, folder: nil, before: nil)) == nil)
    }

    @Test func favoritesAndDisallowedDropsNeverWarn() {
        let (state, _, _, work, t, _, w1) = make()
        #expect(state.crossProfileMove([t[0]], on: .favorites(before: nil)) == nil)
        // Folders can't go to Today, so there's nothing to confirm.
        var withFolder = state
        let folder = withFolder.createFolder(name: "F", inSpace: 0)
        #expect(withFolder.crossProfileMove([folder], on: .unpinned(space: work, before: nil)) == nil)
        // Into a split with a tab of the other profile.
        #expect(state.crossProfileMove([t[0]], on: .split(with: w1, side: .right))?.spaceName == "Work")
    }

    @Test func suppressionIsReadFromDefaults() throws {
        let defaults = try #require(UserDefaults(suiteName: "CrossProfileMoveTests-\(UUID())"))
        #expect(!CrossProfileMove.isSuppressed(in: defaults))
        defaults.set(true, forKey: CrossProfileMove.suppressedKey)
        #expect(CrossProfileMove.isSuppressed(in: defaults))
    }
}

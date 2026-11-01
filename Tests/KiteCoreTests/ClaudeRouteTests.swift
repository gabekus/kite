import Foundation
import Testing
@testable import KiteCore

@Suite struct ClaudeRouteTests {
    @Test func readsProjectLinks() {
        #expect(ClaudeRoute.projectID(fromLink: "https://claude.ai/code/project/chan_017CD7Aqj4RZ") == "chan_017CD7Aqj4RZ")
        #expect(ClaudeRoute.projectID(fromLink: " https://claude.ai/code/project/chan_abc/cmsg_def?x=1 ") == "chan_abc")
        #expect(ClaudeRoute.projectID(fromLink: "chan_abc-_9") == "chan_abc-_9")
        #expect(ClaudeRoute.projectID(fromLink: "https://evil.example/code/project/chan_abc") == nil)
        #expect(ClaudeRoute.projectID(fromLink: "http://claude.ai/code/project/chan_abc") == nil)
        #expect(ClaudeRoute.projectID(fromLink: "https://claude.ai/project/0198-uuid") == nil)
        #expect(ClaudeRoute.projectID(fromLink: "chan_a/../b") == nil)
        #expect(ClaudeRoute.projectURL(id: "chan_abc").absoluteString == "https://claude.ai/code/project/chan_abc")
    }

    @Test func eachSpaceKeepsItsOwnRoute() throws {
        let komado = UUID(), other = UUID()
        var routes = ClaudeRoutes()
        routes.set(.project(id: "chan_k", name: "Komado"), for: komado)
        routes.set(.folder(path: "/Users/me/dev/kite"), for: other)
        #expect(routes.route(for: komado) == .project(id: "chan_k", name: "Komado"))
        #expect(routes.route(for: UUID()) == .newChat)
        // Picking a project remembers it for the other spaces' pickers.
        #expect(routes.projects == [.init(id: "chan_k", name: "Komado")])
        routes.set(.newChat, for: other)
        #expect(routes.spaces[other.uuidString] == nil)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("routes.json")
        try routes.save(to: url)
        #expect(ClaudeRoutes.load(from: url) == routes)
        #expect(ClaudeRoutes.load(from: url.appendingPathExtension("missing")) == ClaudeRoutes())
    }

    @Test func projectMessageCarriesTheAttachedTab() {
        #expect(ClaudeRoute.projectMessage(goal: "order the 12 kaleido 3s", tab: nil) == "order the 12 kaleido 3s")
        let tab = ClaudeInvocation.TabContext(id: UUID(), title: "Cart", url: "https://shop.example/cart")
        #expect(ClaudeRoute.projectMessage(goal: "order these", tab: tab).hasSuffix("(From Kite. I'm looking at “Cart” — https://shop.example/cart)"))
    }

    @Test func composerScriptQuotesTheMessage() {
        let script = ClaudeRoute.composerScript(message: "it's \"quoted\"\n</script>")
        #expect(script.contains(#"const text = "it's \"quoted\"\n<\/script>";"#))
    }

    @Test func listsRecentClaudeCodeFolders() throws {
        let files = FileManager.default
        let home = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let old = home.appendingPathComponent("dev/old"), new = home.appendingPathComponent("dev/new.app")
        for folder in [old, new] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        let projects: [String: Any] = [old.path: [:], new.path: [:], "/tmp/x": [:], home.path + "/gone": [:],
                                       home.path + "/dev/kite/.claude/worktrees/a": [:]]
        try JSONSerialization.data(withJSONObject: ["projects": projects]).write(to: home.appendingPathComponent(".claude.json"))
        let transcripts = home.appendingPathComponent(".claude/projects")
        for (folder, age) in [(old, 100.0), (new, 10.0)] {
            let dir = transcripts.appendingPathComponent(ClaudeCodeFolders.transcriptKey(folder.path))
            try files.createDirectory(at: dir, withIntermediateDirectories: true)
            try files.setAttributes([.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: dir.path)
        }
        // The temporary directory itself is under /var or /private, which `recent` skips, so check the order
        // with that filter out of the way.
        #expect(ClaudeCodeFolders.transcriptKey("/Users/me/dev/new.app") == "-Users-me-dev-new-app")
        #expect(ClaudeCodeFolders.isCandidate("/Users/me/dev/kite", home: "/Users/me"))
        #expect(!ClaudeCodeFolders.isCandidate("/Users/me", home: "/Users/me"))
        #expect(!ClaudeCodeFolders.isCandidate("/private/tmp/k", home: "/Users/me"))
        #expect(!ClaudeCodeFolders.isCandidate("/Users/me/dev/kite/.claude/worktrees/a", home: "/Users/me"))
        #expect(ClaudeCodeFolders.recent(home: home, candidate: { _ in true }) == [new.path, old.path])
    }
}

import Foundation
import Testing
@testable import KiteCore

@Suite struct ArcLinkRoutingImportTests {
    private static let space = "00000000-0000-4000-8000-000000000002"
    private static let rule = "00000000-0000-4000-8000-0000000000a1"

    private static func component(_ style: String, _ pattern: String) -> [String: Any] {
        ["id": UUID().uuidString, "componentType": ["urlMatch": ["_0": [style: [:]], "_1": pattern]]]
    }

    /// Mirrors the shape of a real StorableLinkRouting.json.
    static let fixture: Data = try! JSONSerialization.data(withJSONObject: [
        "version": 1,
        "rules": [
            ["id": rule, "sourceComponents": [component("contains", "spotify"), component("matches", "figma.com")],
             "destination": ["space": ["_0": ["space": ["_0": space]]]]],
            ["id": UUID().uuidString, "sourceComponents": [component("contains", "zoom.us")],
             "destination": ["littleArc": ["_0": ["mostRecent": [:]]]]],
            ["id": UUID().uuidString, "sourceComponents": [component("contains", "notion")],
             "destination": ["mostRecent": [:]]],
            ["id": UUID().uuidString, "sourceComponents": [component("contains", "bank")],
             "destination": ["profile": ["_0": ["custom": ["_0": ["directoryBasename": "Profile 1"]]]]]],
        ],
        "defaultDestination": ["littleArc": ["_0": ["mostRecent": [:]]]],
    ])

    @Test func readsArcRoutes() throws {
        let result = try #require(ArcLinkRoutingImport.parse(Self.fixture))
        #expect(result.rules.count == 3)
        #expect(result.skipped == 1)
        let first = result.rules[0]
        #expect(first.id == UUID(uuidString: Self.rule))
        #expect(first.destination == .space(UUID(uuidString: Self.space)!))
        #expect(first.components.map(\.style) == [.contains, .matches])
        #expect(first.components.map(\.pattern) == ["spotify", "figma.com"])
        #expect(result.rules[1].destination == .littleKite)
        #expect(result.rules[2].destination == .mostRecentSpace)
        #expect(result.defaultDestination == .littleKite)

        // Routed as in Arc once the space is imported.
        var state = AirTrafficControl.State()
        state.merge(arc: result)
        let url = URL(string: "https://open.spotify.com/track/1")!
        #expect(state.destination(for: url, spaceIDs: [UUID(uuidString: Self.space)!], opensExternalLinksInLittleKite: false)
            == .space(UUID(uuidString: Self.space)!))
    }

    @Test func importingAgainReplacesArcsRoutesAndKeepsKites() throws {
        let result = try #require(ArcLinkRoutingImport.parse(Self.fixture))
        let own = AirTrafficControl.Rule(components: [AirTrafficControl.Component(pattern: "github")])
        var state = AirTrafficControl.State(rules: [own])
        #expect(state.merge(arc: result) == 3)
        var changed = result
        changed.rules[0].components[0].pattern = "music"
        #expect(state.merge(arc: changed) == 0)
        #expect(state.rules.count == 4)
        #expect(state.rules[0] == own)
        #expect(state.rules[1].components[0].pattern == "music")
    }

    @Test func noDefaultKeepsKites() throws {
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "rules": []])
        let result = try #require(ArcLinkRoutingImport.parse(data))
        #expect(result.isEmpty)
        var state = AirTrafficControl.State(defaultDestination: .mostRecentSpace)
        state.merge(arc: result)
        #expect(state.defaultDestination == .mostRecentSpace)
        #expect(ArcLinkRoutingImport.parse(Data("[]".utf8)) == nil)
    }
}

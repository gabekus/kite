import Foundation
import Testing
@testable import KiteCore

@Suite struct DeveloperModeTests {
    @Test func togglesPerHostAcrossPorts() {
        var state = BrowserState.makeDefault()
        let dev = URL(string: "http://LocalHost:3000/app")
        let otherPort = URL(string: "http://localhost:5173")
        let site = URL(string: "https://example.com")

        #expect(!state.isInDeveloperMode(dev))
        #expect(state.developerModeMenuTitle(for: dev) == "Turn on Developer Mode for this site")

        state.toggleDeveloperMode(for: dev)
        #expect(state.developerModeEnabledForHosts == ["localhost"])
        #expect(state.isInDeveloperMode(dev))
        #expect(state.isInDeveloperMode(otherPort))
        #expect(!state.isInDeveloperMode(site))
        #expect(state.developerModeMenuTitle(for: dev) == "Turn off Developer Mode for this site")

        state.toggleDeveloperMode(for: otherPort)
        #expect(!state.isInDeveloperMode(dev))
        #expect(state.developerModeEnabledForHosts.isEmpty)
    }

    @Test func ignoresPagesWithoutAHost() {
        var state = BrowserState.makeDefault()
        state.toggleDeveloperMode(for: URL(string: "about:blank"))
        state.toggleDeveloperMode(for: nil)
        #expect(state.developerModeEnabledForHosts.isEmpty)
        #expect(!state.isInDeveloperMode(nil))
    }

    @Test func reloadSettingAppliesOnlyInDeveloperMode() {
        var state = BrowserState.makeDefault()
        let dev = URL(string: "http://localhost:8080")
        let site = URL(string: "https://example.com")
        state.devModeReloadState = .forceReload
        #expect(state.reloadSetting(for: dev) == .reload)
        state.toggleDeveloperMode(for: dev)
        #expect(state.reloadSetting(for: dev) == .forceReload)
        #expect(state.reloadSetting(for: site) == .reload)
    }

    @Test func roundTripsAndDecodesOlderSessions() throws {
        var state = BrowserState.makeDefault()
        state.toggleDeveloperMode(for: URL(string: "http://localhost:3000"))
        state.devModeReloadState = .forceReload
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(BrowserState.self, from: data)
        #expect(decoded.developerModeEnabledForHosts == ["localhost"])
        #expect(decoded.devModeReloadState == .forceReload)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        json["developerModeEnabledForHosts"] = nil
        json["devModeReloadState"] = "somethingNewer"
        let old = try JSONDecoder().decode(BrowserState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.developerModeEnabledForHosts.isEmpty)
        #expect(old.devModeReloadState == .reload)
    }
}

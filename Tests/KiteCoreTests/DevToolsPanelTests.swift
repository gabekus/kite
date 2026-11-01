import Testing
@testable import KiteCore

@Suite struct DevToolsPanelTests {
    @Test func lastOnlyHooksTheFrontend() {
        let script = DevToolsPanel.last.chromiumFrontendScript
        #expect(script.contains("host.loadCompleted = function"))
        #expect(!script.contains("DevToolsAPI."))
        #expect(script.hasSuffix("})(null);"))
    }

    @Test func eachPanelCallsDevToolsAPI() {
        #expect(DevToolsPanel.inspectElement.chromiumFrontendScript.contains("DevToolsAPI.enterInspectElementMode()"))
        #expect(DevToolsPanel.console.chromiumFrontendScript.contains("DevToolsAPI.showPanel('console')"))
        #expect(DevToolsPanel.network.chromiumFrontendScript.contains("DevToolsAPI.showPanel('network')"))
    }

    @Test func panelCallWaitsForLoadCompleted() {
        let script = DevToolsPanel.console.chromiumFrontendScript
        #expect(script.contains("if (host.kiteState.loaded) call(); else host.kiteState.queue.push(call);"))
    }
}

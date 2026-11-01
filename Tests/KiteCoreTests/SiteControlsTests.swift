import Foundation
import Testing
@testable import KiteCore

@Suite struct SiteControlsTests {
    @Test func securityTitleFollowsTheScheme() {
        #expect(SiteControls.securityTitle(for: URL(string: "https://example.com")) == "Secure")
        #expect(SiteControls.securityTitle(for: URL(string: "http://example.com")) == "Insecure")
        #expect(SiteControls.securityTitle(for: URL(string: "kite://history")) == nil)
        #expect(SiteControls.securityTitle(for: URL(string: "about:blank")) == nil)
        #expect(SiteControls.securityTitle(for: nil) == nil)
    }

    @Test func appliesOnlyToWebsites() {
        #expect(SiteControls.applies(to: URL(string: "https://www.wikipedia.org/wiki/Kite")))
        #expect(!SiteControls.applies(to: URL(string: "file:///tmp/a.html")))
        #expect(!SiteControls.applies(to: URL(string: "kite://history")))
        #expect(!SiteControls.applies(to: nil))
    }

    @Test func originKeepsSchemeHostAndPort() {
        #expect(SiteControls.origin(of: URL(string: "https://Example.com/a?b=1")!) == "https://example.com")
        #expect(SiteControls.origin(of: URL(string: "http://localhost:8080/x")!) == "http://localhost:8080")
        #expect(SiteControls.origin(of: URL(string: "about:blank")!) == nil)
    }

    @Test func arcsWords() {
        #expect(SiteControls.adblockTitle == "Block Ads & Trackers")
        #expect(SiteControls.onOff(true) == "On")
        #expect(SiteControls.onOff(false) == "Off")
        #expect(SitePermissionValue.allow.subtitle == "Allowed")
        #expect(SitePermissionValue.block.subtitle == "Blocked")
    }

    @Test func clickingAPermissionFlipsIt() {
        #expect(SitePermissionValue.allow.toggled == .block)
        #expect(SitePermissionValue.block.toggled == .allow)
        #expect(SitePermissionValue.ask.toggled == .allow)
    }

    @Test func zoomReadsAsAPercentage() {
        #expect(SiteControls.zoomPercent(1) == "100%")
        #expect(SiteControls.zoomPercent(1.1) == "110%")
        #expect(SiteControls.zoomPercent(0.8999999) == "90%")
    }
}

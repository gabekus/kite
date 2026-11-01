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
        #expect(SiteControls.developerModeTitle == "Developer Mode")
        #expect(SiteControls.settingsTitle == "Settings")
        #expect(SiteControls.settingsHoverText == "More")
        #expect(SiteControls.allSiteSettingsTitle == "All Site Settings\u{2026}")
    }

    @Test func siteSettingsPageIsKeyedByOrigin() {
        let url = InternalPage.siteSettingsURL(for: URL(string: "http://LocalHost:8080/a/b?q=1#x"))
        #expect(url?.absoluteString == "kite://site-settings?site=http://localhost:8080")
        #expect(InternalPage(url) == .siteSettings)
        #expect(InternalPage.site(inSiteSettings: url)?.absoluteString == "http://localhost:8080")
        #expect(InternalPage.siteSettingsURL(for: URL(string: "https://example.com"))?.absoluteString
            == "kite://site-settings?site=https://example.com")
        #expect(InternalPage.siteSettingsURL(for: URL(string: "kite://history")) == nil)
        #expect(InternalPage.siteSettingsURL(for: nil) == nil)
        #expect(InternalPage.site(inSiteSettings: URL(string: "kite://site-settings")) == nil)
        #expect(InternalPage.site(inSiteSettings: URL(string: "kite://site-settings?site=file:///tmp")) == nil)
        #expect(InternalPage.site(inSiteSettings: URL(string: "kite://history?site=https://a.com")) == nil)
        #expect(InternalPage.siteSettings.title == "Site Settings")
    }

    @Test func boostsWordsAreArcs() {
        #expect(SiteControls.boostsTitle == "Boosts")
        #expect(SiteControls.boostsHoverText == "Manage")
        #expect(SiteControls.boostSubtitle(true) == "Enabled")
        #expect(SiteControls.boostSubtitle(false) == "Disabled")
        #expect(SiteControls.newBoostTitle == "New Boost")
        #expect(SiteControls.manageBoostsMenuTitle == "Manage Boosts\u{2026}")
        #expect(SiteControls.newBoostMenuTitle == "New Boost\u{2026}")
    }

    @Test func footerMenuOffersBoostsOnlyWithoutABoostsSection() {
        #expect(SiteControls.includesBoostsInMenu(siteBoostCount: 0, boostsAvailable: true))
        #expect(!SiteControls.includesBoostsInMenu(siteBoostCount: 2, boostsAvailable: true))
        #expect(!SiteControls.includesBoostsInMenu(siteBoostCount: 0, boostsAvailable: false))
    }

    @Test func actionRowFollowsArc() {
        #expect(SiteControls.actions(boostsEnabled: true, captureEnabled: true, optionKeyDown: false)
            == [.share, .newBoost, .capture, .captureFullPage])
        #expect(SiteControls.actions(boostsEnabled: false, captureEnabled: true, optionKeyDown: false)
            == [.share, .copyURL, .capture, .captureFullPage])
        #expect(SiteControls.actions(boostsEnabled: true, captureEnabled: true, optionKeyDown: true)
            == [.share, .newBoost, .capture, .capturePortraitMode])
        #expect(SiteControls.actions(boostsEnabled: false, captureEnabled: false, optionKeyDown: true) == [.share, .copyURL])
        #expect(SiteControlsAction.capture.title == "Capture a portion of this page")
        #expect(SiteControlsAction.captureFullPage.title == "Capture the full page")
        #expect(SiteControlsAction.capturePortraitMode.title == "Capture in Portrait Mode")
        #expect(!SiteControlsAction.share.dismissesPopover && SiteControlsAction.capture.dismissesPopover)
    }

    @Test func extensionsSectionStrings() {
        #expect(SiteControls.pinButtonTitle(isPinned: true) == "Unpin")
        #expect(SiteControls.pinButtonTitle(isPinned: false) == "Pin")
        #expect(SiteControls.manageExtensionsMenuTitle == "Manage Extensions\u{2026}")
        #expect(SiteControls.addExtensionMenuTitle == "Add Extension\u{2026}")
        #expect(SiteControls.showsPinButton(isPinned: true, isHovered: false))
        #expect(SiteControls.showsPinButton(isPinned: false, isHovered: true))
        #expect(!SiteControls.showsPinButton(isPinned: false, isHovered: false))
    }

    @Test func clickingAPermissionFlipsIt() {
        #expect(SitePermissionValue.allow.toggled == .block)
        #expect(SitePermissionValue.block.toggled == .allow)
        #expect(SitePermissionValue.ask.toggled == .allow)
    }
}

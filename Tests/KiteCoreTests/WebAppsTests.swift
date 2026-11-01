import Foundation
import Testing
@testable import KiteCore

@Suite struct WebAppsTests {
    let document = URL(string: "https://app.example.com/inbox/today?x=1#top")!
    let manifestURL = URL(string: "https://app.example.com/static/app.webmanifest")!

    func parse(_ json: String, document: URL? = nil) -> WebAppManifest? {
        WebAppManifest.parse(Data(json.utf8), manifestURL: manifestURL, documentURL: document ?? self.document)
    }

    // MARK: Manifest

    @Test func readsTheManifestsFieldsAndResolvesAgainstTheManifestURL() throws {
        let manifest = try #require(parse("""
            {"name": " Example Mail ", "short_name": "Mail", "start_url": "../inbox/?source=pwa",
             "scope": "/inbox/", "display": "standalone", "theme_color": "#1A73E8", "background_color": "white",
             "icons": [{"src": "icon-192.png", "sizes": "192x192", "type": "image/png"},
                       {"src": "/icon-512.png", "sizes": "512x512", "purpose": "any maskable"}]}
            """))
        #expect(manifest.name == "Example Mail")
        #expect(manifest.shortName == "Mail")
        #expect(manifest.startURL.absoluteString == "https://app.example.com/inbox/?source=pwa")
        #expect(manifest.scope.absoluteString == "https://app.example.com/inbox/")
        #expect(manifest.id == manifest.startURL)
        #expect(manifest.display == .standalone)
        #expect(manifest.themeColor == "#1a73e8")
        #expect(manifest.backgroundColor == "#ffffff")
        #expect(manifest.icons.map(\.url.absoluteString) == [
            "https://app.example.com/static/icon-192.png", "https://app.example.com/icon-512.png",
        ])
        #expect(manifest.icons[0].size == 192)
        #expect(manifest.icons[1].purposes == ["any", "maskable"])
    }

    @Test func defaultsFollowTheSpec() throws {
        let manifest = try #require(parse("{}"))
        // start_url: the document, without its fragment; scope: its directory; display: browser.
        #expect(manifest.startURL.absoluteString == "https://app.example.com/inbox/today?x=1")
        #expect(manifest.scope.absoluteString == "https://app.example.com/inbox/")
        #expect(manifest.display == .browser)
        #expect(manifest.name == nil)
        #expect(manifest.icons.isEmpty)
        #expect(parse("[1, 2]") == nil)
        #expect(parse("not json") == nil)
    }

    @Test func crossOriginStartURLFallsBackToTheDocument() throws {
        let manifest = try #require(parse(#"{"start_url": "https://evil.example.net/"}"#))
        #expect(manifest.startURL.absoluteString == "https://app.example.com/inbox/today?x=1")
    }

    @Test func scopeThatDoesNotContainStartURLFallsBackToTheDefault() throws {
        let outside = try #require(parse(#"{"start_url": "/inbox/", "scope": "/settings/"}"#))
        #expect(outside.scope.absoluteString == "https://app.example.com/inbox/")
        let otherOrigin = try #require(parse(#"{"start_url": "/inbox/", "scope": "https://other.example.com/"}"#))
        #expect(otherOrigin.scope.absoluteString == "https://app.example.com/inbox/")
        let wide = try #require(parse(#"{"start_url": "/inbox/", "scope": "/?q=1#f"}"#))
        #expect(wide.scope.absoluteString == "https://app.example.com/")
    }

    @Test func idResolvesAgainstStartURLsOrigin() throws {
        let manifest = try #require(parse(#"{"start_url": "/inbox/", "id": "mail#x"}"#))
        #expect(manifest.id.absoluteString == "https://app.example.com/mail")
        let foreign = try #require(parse(#"{"start_url": "/inbox/", "id": "https://other.example.com/mail"}"#))
        #expect(foreign.id.absoluteString == "https://app.example.com/inbox/")
    }

    @Test func unknownDisplayIsBrowser() throws {
        #expect(try #require(parse(#"{"display": "tabbed"}"#)).display == .browser)
        #expect(try #require(parse(#"{"display": "MINIMAL-UI"}"#)).display == .minimalUI)
        #expect(!WebAppDisplay.browser.opensInWindow)
        #expect(WebAppDisplay.fullscreen.opensInWindow)
    }

    // MARK: Scope

    @Test func withinScopeIsSameOriginAndPathPrefix() {
        let scope = URL(string: "https://app.example.com/inbox/")!
        #expect(WebApps.isURL(URL(string: "https://app.example.com/inbox/")!, withinScope: scope))
        #expect(WebApps.isURL(URL(string: "https://APP.example.com/inbox/42?a#b")!, withinScope: scope))
        #expect(!WebApps.isURL(URL(string: "https://app.example.com/inbox")!, withinScope: scope))
        #expect(!WebApps.isURL(URL(string: "https://app.example.com/settings")!, withinScope: scope))
        #expect(!WebApps.isURL(URL(string: "http://app.example.com/inbox/")!, withinScope: scope))
        #expect(!WebApps.isURL(URL(string: "https://app.example.com:8443/inbox/")!, withinScope: scope))
        #expect(!WebApps.isURL(URL(string: "https://example.com/inbox/")!, withinScope: scope))
        // Default ports are the same origin.
        #expect(WebApps.isURL(URL(string: "https://app.example.com:443/inbox/x")!, withinScope: scope))
        #expect(WebApps.isURL(URL(string: "http://127.0.0.1:8000/app/x")!, withinScope: URL(string: "http://127.0.0.1:8000/app/")!))
    }

    @Test func defaultScopeIsTheStartURLsDirectory() {
        #expect(WebApps.defaultScope(for: URL(string: "https://a.com/x/y/z.html?q")!).absoluteString == "https://a.com/x/y/")
        #expect(WebApps.defaultScope(for: URL(string: "https://a.com")!).absoluteString == "https://a.com/")
        #expect(WebApps.defaultScope(for: URL(string: "https://a.com/x/")!).absoluteString == "https://a.com/x/")
    }

    // MARK: Icons

    @Test func picksTheLargestRasterAnyPurposeIcon() {
        let base = "https://a.com/"
        let icons = [
            WebAppIcon(url: URL(string: base + "48.png")!, size: 48),
            WebAppIcon(url: URL(string: base + "mask.png")!, size: 1024, purposes: ["maskable"]),
            WebAppIcon(url: URL(string: base + "icon.svg")!, size: nil, type: "image/svg+xml"),
            WebAppIcon(url: URL(string: base + "512.png")!, size: 512, purposes: ["any", "maskable"]),
            WebAppIcon(url: URL(string: base + "192.png")!, size: 192),
        ]
        #expect(WebApps.bestIcon(icons)?.url.lastPathComponent == "512.png")
        #expect(WebApps.bestIcon([icons[2]])?.url.lastPathComponent == "icon.svg")
        #expect(WebApps.bestIcon([icons[1]]) == nil)
        #expect(WebAppIcon.largestSize(in: "16x16 32x32 any") == 32)
        #expect(WebAppIcon.largestSize(in: "any") == nil)
        #expect(WebAppIcon.largestSize(in: "192X192") == 192)
    }

    // MARK: Colours

    @Test func normalisesCSSColours() {
        #expect(WebApps.normalizedColor("#ABC") == "#aabbcc")
        #expect(WebApps.normalizedColor("#abcd") == "#aabbcc")
        #expect(WebApps.normalizedColor("#112233ff") == "#112233")
        #expect(WebApps.normalizedColor("rgb(255, 0, 128)") == "#ff0080")
        #expect(WebApps.normalizedColor("rgba(0 0 0 / 50%)") == "#000000")
        #expect(WebApps.normalizedColor("rgb(100%, 50%, 0%)") == "#ff8000")
        #expect(WebApps.normalizedColor(" Navy ") == "#000080")
        #expect(WebApps.normalizedColor("#12") == nil)
        #expect(WebApps.normalizedColor("hsl(0, 100%, 50%)") == nil)
        #expect(WebApps.normalizedColor("#ggg") == nil)
    }

    @Test func picksAReadableForeground() {
        #expect(WebApps.prefersDarkForeground(on: "#ffffff"))
        #expect(WebApps.prefersDarkForeground(on: "#ffd700"))
        #expect(!WebApps.prefersDarkForeground(on: "#000000"))
        #expect(!WebApps.prefersDarkForeground(on: "#0b57d0"))
    }

    // MARK: Install candidates

    @Test func candidateFromAManifest() throws {
        let page = WebAppPageInfo(url: document.absoluteString, title: "Inbox (3)",
                                  manifest: manifestURL.absoluteString,
                                  icons: [.init(href: "https://app.example.com/touch.png", rel: "apple-touch-icon")],
                                  themeColor: "#000")
        let manifest = try #require(parse(#"{"short_name": "Mail", "start_url": "/inbox/", "display": "standalone"}"#))
        let app = try #require(WebApp.candidate(page: page, manifest: manifest))
        #expect(app.name == "Mail")
        #expect(app.startURL.absoluteString == "https://app.example.com/inbox/")
        #expect(app.display == .standalone)
        // No theme_color or icons in the manifest: the page's meta theme-color and touch icon.
        #expect(app.themeColor == "#000000")
        #expect(app.iconURL?.absoluteString == "https://app.example.com/touch.png")
        #expect(app.manifestURL == manifestURL)
        #expect(app.id == WebApps.appID(for: manifest.id))
    }

    @Test func candidateWithoutAManifestUsesThePage() throws {
        let page = WebAppPageInfo(url: "http://127.0.0.1:8000/docs/page.html#s", title: "  Docs  ")
        let app = try #require(WebApp.candidate(page: page, manifest: nil))
        #expect(app.name == "Docs")
        #expect(app.startURL.absoluteString == "http://127.0.0.1:8000/docs/page.html")
        #expect(app.scope.absoluteString == "http://127.0.0.1:8000/docs/")
        #expect(app.display == .standalone)
        #expect(app.iconURL?.absoluteString == "http://127.0.0.1:8000/favicon.ico")
        let untitled = try #require(WebApp.candidate(page: WebAppPageInfo(url: "https://site.test/"), manifest: nil))
        #expect(untitled.name == "site.test")
        #expect(WebApp.candidate(page: WebAppPageInfo(url: "file:///tmp/x.html"), manifest: nil) == nil)
    }

    @Test func pageInfoDecodesTheScriptsJSON() throws {
        let json = #"{"url":"https://a.com/","title":"A","manifest":"https://a.com/m.json","manifestCredentials":false,"icons":[{"href":"https://a.com/i.png","sizes":"64x64","rel":"icon"}],"themeColor":null,"applicationName":null}"#
        let info = try #require(WebAppPageInfo.decode(json))
        #expect(info.manifestURL?.absoluteString == "https://a.com/m.json")
        #expect(info.iconCandidates.first?.size == 64)
        #expect(WebAppPageInfo.decode(42) == nil)
    }

    // MARK: Ids and launch URLs

    @Test func appIDsAreStableHex() {
        let id = WebApps.appID(for: URL(string: "https://a.com/start#frag")!)
        #expect(id == WebApps.appID(for: URL(string: "https://a.com/start")!))
        #expect(id != WebApps.appID(for: URL(string: "https://b.com/start")!))
        #expect(WebApps.isAppID(id))
        #expect(!WebApps.isAppID("XYZ"))
        let launch = WebApps.launchURL(for: id)
        #expect(launch.absoluteString == "kite-app://\(id)")
        #expect(WebApps.appID(fromLaunchURL: launch) == id)
        #expect(WebApps.appID(fromLaunchURL: URL(string: "https://\(id)")!) == nil)
        #expect(WebApps.appID(fromLaunchURL: URL(string: "kite-app://nothex")!) == nil)
    }

    @Test func windowTitleIsThePageThenTheApp() {
        #expect(WebApps.windowTitle(appName: "Mail", pageTitle: "Inbox") == "Inbox")
        #expect(WebApps.windowTitle(appName: "Mail", pageTitle: " ") == "Mail")
        #expect(WebApps.windowTitle(appName: "Mail", pageTitle: nil) == "Mail")
    }

    // MARK: State

    @Test func stateInstallsReplacesAndRemoves() throws {
        func app(_ id: String, _ name: String) -> WebApp {
            WebApp(id: id, manifestID: URL(string: "https://a.com/\(id)")!, name: name,
                   startURL: URL(string: "https://a.com/")!, scope: URL(string: "https://a.com/")!, display: .standalone)
        }
        var state = WebAppsState()
        state.install(app("0000000000000001", "beta"))
        state.install(app("0000000000000002", "Alpha"))
        state.install(app("0000000000000001", "Beta"))
        #expect(state.apps.count == 2)
        #expect(state.sorted.map(\.name) == ["Alpha", "Beta"])
        let data = try JSONEncoder().encode(state)
        #expect(try JSONDecoder().decode(WebAppsState.self, from: data) == state)
        #expect(state.remove(id: "0000000000000002")?.name == "Alpha")
        #expect(state.remove(id: "0000000000000002") == nil)
        #expect(state.app(id: "0000000000000001")?.name == "Beta")
    }

    // MARK: Launcher bundle

    @Test func bundleNamesAreSafeAndUnique() {
        #expect(WebAppShim.bundleName(for: "Mail") == "Mail.app")
        #expect(WebAppShim.bundleName(for: "a/b:c") == "a-b-c.app")
        #expect(WebAppShim.bundleName(for: "..hidden") == "hidden.app")
        #expect(WebAppShim.bundleName(for: "   ") == "Web App.app")
        #expect(WebAppShim.bundleName(for: "Mail", taken: ["mail.app", "Mail 2.app"]) == "Mail 3.app")
        #expect(WebAppShim.bundleName(for: String(repeating: "x", count: 100)).count == 64 + 4)
    }

    @Test func launcherOpensTheAppsURLInKite() {
        let id = "0123456789abcdef"
        let script = WebAppShim.launcherScript(appID: id, kiteBundleID: "dev.gabek.Kite'; rm -rf /")
        #expect(script.hasPrefix("#!/bin/sh\n"))
        #expect(script.contains("exec /usr/bin/open -b 'dev.gabek.Kiterm-rf' 'kite-app://0123456789abcdef'"))
        let app = WebApp(id: id, manifestID: URL(string: "https://a.com/")!, name: "Mail",
                         startURL: URL(string: "https://a.com/")!, scope: URL(string: "https://a.com/")!, display: .standalone)
        let plist = WebAppShim.infoPlist(for: app, kiteBundleID: "dev.gabek.Kite")
        #expect(plist["CFBundleExecutable"] as? String == "launcher")
        #expect(plist["CFBundleIdentifier"] as? String == "dev.gabek.Kite.app.0123456789abcdef")
        #expect(plist["CFBundleName"] as? String == "Mail")
        #expect(plist["CFBundlePackageType"] as? String == "APPL")
        #expect(plist["KiteAppURL"] as? String == "kite-app://0123456789abcdef")
        #expect(PropertyListSerialization.propertyList(plist, isValidFor: .xml))
    }

    // MARK: Chrome's install icon and dialog

    @Test func promotableNeedsANameAWindowAndA144pxIcon() throws {
        let good = try #require(parse(#"{"name": "A", "display": "standalone", "icons": [{"src": "a.png", "sizes": "192x192"}]}"#))
        #expect(WebAppInstallability.isPromotable(good))
        let shortOnly = try #require(parse(#"{"short_name": "A", "display": "minimal-ui", "icons": [{"src": "a.png", "sizes": "144x144"}]}"#))
        #expect(WebAppInstallability.isPromotable(shortOnly))
        let svg = try #require(parse(#"{"name": "A", "display": "fullscreen", "icons": [{"src": "a.svg", "sizes": "any", "type": "image/svg+xml"}]}"#))
        #expect(WebAppInstallability.isPromotable(svg))
        let noName = try #require(parse(#"{"display": "standalone", "icons": [{"src": "a.png", "sizes": "192x192"}]}"#))
        #expect(!WebAppInstallability.isPromotable(noName))
        let browser = try #require(parse(#"{"name": "A", "icons": [{"src": "a.png", "sizes": "192x192"}]}"#))
        #expect(!WebAppInstallability.isPromotable(browser))
        let small = try #require(parse(#"{"name": "A", "display": "standalone", "icons": [{"src": "a.png", "sizes": "96x96"}]}"#))
        #expect(!WebAppInstallability.isPromotable(small))
        let maskableOnly = try #require(parse(#"{"name": "A", "display": "standalone", "icons": [{"src": "a.png", "sizes": "512x512", "purpose": "maskable"}]}"#))
        #expect(!WebAppInstallability.isPromotable(maskableOnly))
    }

    @Test func readsDescriptionAndScreenshots() throws {
        let manifest = try #require(parse("""
            {"description": " Mail for teams ", "screenshots": [
              {"src": "s1.png", "sizes": "1280x720", "form_factor": "wide", "label": "Inbox"},
              {"src": "s2.png", "form_factor": "narrow"},
              {"src": "s3.png"}]}
            """))
        #expect(manifest.description == "Mail for teams")
        #expect(manifest.screenshots.count == 3)
        #expect(manifest.screenshots[0].url.absoluteString == "https://app.example.com/static/s1.png")
        #expect(manifest.screenshots[0].label == "Inbox")
        #expect(WebAppInstallability.desktopScreenshots(manifest).map(\.url.lastPathComponent) == ["s1.png"])
    }

    @Test func desktopTakesAtMostEightWideScreenshots() throws {
        let entries = (0..<10).map { #"{"src": "s\#($0).png", "form_factor": "wide"}"# }.joined(separator: ",")
        let manifest = try #require(parse(#"{"screenshots": ["# + entries + "]}"))
        #expect(WebAppInstallability.desktopScreenshots(manifest).count == 8)
    }

    @Test func screenshotsKeepTheFirstAspectRatioAndChromesLimits() {
        let accepted = WebAppInstallability.acceptedScreenshots([
            (1280, 720), nil, (1920, 1080), (720, 1280), (200, 100), (4000, 2250), (1600, 900), (2400, 800),
        ])
        #expect(accepted == [0, 2, 6])
        // Too long a strip is skipped even first.
        #expect(WebAppInstallability.acceptedScreenshots([(2400, 800), (1280, 720)]) == [1])
    }

    @Test func dialogTextFollowsChrome() {
        #expect(WebAppInstallability.dialogDescription(String(repeating: "a", count: 400))?.count == 300)
        #expect(WebAppInstallability.dialogDescription("") == nil)
        #expect(WebAppInstallability.displayOrigin(URL(string: "https://www.reddit.com/?pwa")!) == "www.reddit.com")
        #expect(WebAppInstallability.displayOrigin(URL(string: "http://127.0.0.1:8729/app/")!) == "127.0.0.1:8729")
        #expect(WebAppInstallability.displayOrigin(URL(string: "https://a.com:443/")!) == "a.com")
    }
}

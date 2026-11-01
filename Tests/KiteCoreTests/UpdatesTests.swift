import Foundation
import Testing
@testable import KiteCore

@Suite struct AppVersionTests {
    func v(_ s: String) -> AppVersion { AppVersion(s)! }

    @Test func parsesTagsAndBundleVersions() {
        #expect(v("0.1.0").numbers == [0, 1, 0])
        #expect(v("v1.2").numbers == [1, 2])
        #expect(v("kite-3.4.5").numbers == [3, 4, 5])
        #expect(v(" 2 ").numbers == [2])
        #expect(v("1.0.0-beta.2").prerelease == ["beta", "2"])
        #expect(v("1.0.0+build.7").prerelease.isEmpty)
        #expect(AppVersion("") == nil)
        #expect(AppVersion("latest") == nil)
        #expect(AppVersion("1..2") == nil)
        #expect(AppVersion("1.x") == nil)
    }

    @Test func comparesNumbersNotText() {
        #expect(v("0.10.0") > v("0.9.9"))
        #expect(v("1.2.10") > v("1.2.9"))
        #expect(v("2") > v("1.99.99"))
        #expect(v("0.1.0") < v("v0.1.1"))
    }

    @Test func missingTrailingZerosAreEqual() {
        #expect(v("1.2") == v("1.2.0"))
        #expect(!(v("1.2") < v("1.2.0")))
        #expect(Set([v("1.2"), v("1.2.0.0")]).count == 1)
    }

    @Test func prereleaseSortsBeforeRelease() {
        #expect(v("1.0.0-beta") < v("1.0.0"))
        #expect(v("1.0.0-alpha") < v("1.0.0-beta"))
        #expect(v("1.0.0-beta.2") < v("1.0.0-beta.10"))
        #expect(v("1.0.0-beta") < v("1.0.0-beta.1"))
        #expect(v("1.0.0-1") < v("1.0.0-alpha"))
        #expect(v("0.9.0") < v("1.0.0-beta"))
    }
}

@Suite struct UpdatesTests {
    func release(tag: String, assets: String = "[]", extra: String = "") -> Data {
        Data("""
        {"tag_name":"\(tag)","name":"Kite \(tag)","body":"Fixes.","html_url":"https://github.com/gabekus/kite/releases/tag/\(tag)",
         "draft":false,"prerelease":false,"assets":\(assets)\(extra)}
        """.utf8)
    }

    @Test func newerReleaseIsAvailable() {
        let assets = """
        [{"name":"Kite-0.2.0.zip","browser_download_url":"https://example.com/k.zip"},
         {"name":"Kite-0.2.0.dmg","browser_download_url":"https://example.com/k.dmg"}]
        """
        guard case .available(let r) = Updates.outcome(currentVersion: "0.1.0", statusCode: 200, body: release(tag: "v0.2.0", assets: assets)) else {
            Issue.record("expected an update"); return
        }
        #expect(r.version == AppVersion("0.2.0"))
        #expect(r.tag == "v0.2.0")
        #expect(r.title == "Kite v0.2.0")
        #expect(r.notes == "Fixes.")
        #expect(r.pageURL.absoluteString == "https://github.com/gabekus/kite/releases/tag/v0.2.0")
        #expect(r.download?.absoluteString == "https://example.com/k.dmg")
    }

    @Test func sameOrOlderIsUpToDate() {
        #expect(Updates.outcome(currentVersion: "0.1.0", statusCode: 200, body: release(tag: "v0.1")) == .upToDate(current: AppVersion("0.1.0")!))
        #expect(Updates.outcome(currentVersion: "0.3.0", statusCode: 200, body: release(tag: "v0.2.0")) == .upToDate(current: AppVersion("0.3.0")!))
    }

    @Test func prereleaseIsIgnored() {
        let body = Data("""
        {"tag_name":"v9.0.0","html_url":"https://github.com/gabekus/kite/releases/tag/v9.0.0","prerelease":true}
        """.utf8)
        #expect(Updates.outcome(currentVersion: "0.1.0", statusCode: 200, body: body) == .upToDate(current: AppVersion("0.1.0")!))
    }

    @Test func missingTitleFallsBackToVersion() {
        let body = Data(#"{"tag_name":"v1.0","name":"","html_url":"https://github.com/gabekus/kite/releases/tag/v1.0"}"#.utf8)
        guard case .available(let r) = Updates.outcome(currentVersion: "0.1.0", statusCode: 200, body: body) else {
            Issue.record("expected an update"); return
        }
        #expect(r.title == "Kite 1.0")
        #expect(r.download == nil)
    }

    @Test func noReleasesIs404() {
        #expect(Updates.outcome(currentVersion: "0.1.0", statusCode: 404, body: Data(#"{"message":"Not Found"}"#.utf8)) == .noReleases)
    }

    @Test func failures() {
        guard case .failed = Updates.outcome(currentVersion: "0.1.0", statusCode: 403, body: Data()) else { Issue.record("403"); return }
        guard case .failed = Updates.outcome(currentVersion: "0.1.0", statusCode: 500, body: Data()) else { Issue.record("500"); return }
        guard case .failed = Updates.outcome(currentVersion: "0.1.0", statusCode: 200, body: Data("nope".utf8)) else { Issue.record("json"); return }
        guard case .failed = Updates.outcome(currentVersion: "0.1.0", statusCode: 200, body: release(tag: "nightly")) else { Issue.record("tag"); return }
        guard case .failed = Updates.outcome(currentVersion: "dev", statusCode: 200, body: release(tag: "v1")) else { Issue.record("current"); return }
    }
}

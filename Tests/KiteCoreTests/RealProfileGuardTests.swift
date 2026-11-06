import Foundation
import Testing
@testable import KiteCore

@Suite struct RealProfileGuardTests {
    let home = "/Users/gabe"
    let installed = "/Applications/Kite.app"
    /// The build that held the real profile's socket on 5 Nov 2026.
    let baseline = "/Users/gabe/dev/kite-perf/build/baseline.app"
    let dev = "dev.gabek.Kite.dev"
    let real = "dev.gabek.Kite"
    /// No file system: paths compare as written.
    let plain: (String) -> String = { $0 }

    func check(_ id: String?, _ path: String?, _ environment: [String: String] = [:]) -> RealProfileGuard.Verdict {
        RealProfileGuard.check(bundleID: id, bundlePath: path, environment: environment, home: home, resolve: plain)
    }

    @Test func theInstalledKiteOpensTheRealProfile() {
        #expect(check(real, installed) == .allowed)
        #expect(check(real, "/Users/gabe/Applications/Kite.app") == .allowed)
        #expect(check(real, "/applications/kite.app/") == .allowed)
        #expect(check(real, installed, ["KITE_SUPPORT_PATH": "/Users/gabe/Library/Application Support/Kite"]) == .allowed)
    }

    @Test func anythingElseIsRefusedOnTheRealProfile() {
        // Launch Services started the dev bundle for a link: no KITE_SUPPORT_PATH.
        guard case .refused(let message) = check(dev, baseline) else { Issue.record("baseline.app was allowed"); return }
        #expect(message.contains(baseline))
        #expect(message.contains("KITE_SUPPORT_PATH"))
        // A release build (dev.gabek.Kite) still in a checkout, a dev bundle copied into /Applications, a bare
        // `swift build` binary, and a renamed copy next to the installed one.
        #expect(check(real, "/Users/gabe/dev/kite-release/build/Kite.app") != .allowed)
        #expect(check(dev, installed) != .allowed)
        #expect(check(nil, "/Users/gabe/dev/kite/.build/debug") != .allowed)
        #expect(check(real, "/Applications/Kite 2.app") != .allowed)
        #expect(check(real, nil) != .allowed)
    }

    @Test func pointingKiteSupportPathAtTheRealProfileIsStillTheRealProfile() {
        for path in ["/Users/gabe/Library/Application Support/Kite", "/Users/gabe/Library/Application Support/Kite/",
                     "/Users/gabe/Library/Application Support/Kite/Chromium", "/users/gabe/library/application support/kite"] {
            #expect(check(dev, baseline, ["KITE_SUPPORT_PATH": path]) != .allowed, "\(path)")
        }
        // Not inside it: a sibling with the same prefix.
        #expect(check(dev, baseline, ["KITE_SUPPORT_PATH": "/Users/gabe/Library/Application Support/Kite Test"]) == .allowed)
    }

    @Test func aLinkToTheRealProfileIsResolved() {
        let link = "/tmp/k.link"
        let resolve: (String) -> String = { $0 == link ? "/Users/gabe/Library/Application Support/Kite" : $0 }
        let verdict = RealProfileGuard.check(bundleID: dev, bundlePath: baseline, environment: ["KITE_SUPPORT_PATH": link],
                                             home: home, resolve: resolve)
        #expect(verdict != .allowed)
    }

    @Test func testProfilesAreAllowed() {
        #expect(check(dev, baseline, ["KITE_SUPPORT_PATH": "/tmp/k.AbCd"]) == .allowed)
        #expect(check(nil, "/Users/gabe/dev/kite/.build/debug", ["KITE_SUPPORT_PATH": "/tmp/k.AbCd"]) == .allowed)
    }

    @Test func aTestCanStandInForTheRealProfile() {
        // KITE_TEST_REAL_PROFILE only adds a folder: the real profile stays refused.
        let environment = ["KITE_SUPPORT_PATH": "/tmp/k.AbCd", RealProfileGuard.testRealProfileKey: "/tmp/k.AbCd"]
        #expect(check(dev, baseline, environment) != .allowed)
        #expect(check(dev, baseline, [RealProfileGuard.testRealProfileKey: "/tmp/k.other"]) != .allowed)
        #expect(check(real, installed, environment) == .allowed)
    }

    @Test func theRealProfileSocketIsRecognized() {
        let socket = "/Users/gabe/Library/Application Support/Kite/Automation/kite.sock"
        #expect(RealProfileGuard.isRealProfileSocket(socket, environment: [:], home: home, resolve: plain))
        #expect(!RealProfileGuard.isRealProfileSocket("/tmp/k.AbCd/Automation/kite.sock", environment: [:], home: home, resolve: plain))
        #expect(RealProfileGuard.isRealProfileSocket("/tmp/k.AbCd/Automation/kite.sock",
                                                     environment: [RealProfileGuard.testRealProfileKey: "/tmp/k.AbCd"],
                                                     home: home, resolve: plain))
    }

    @Test func aKiteBuildAsTheDefaultBrowserIsCaught() {
        // What macOS had on 5 Nov 2026: links went to dev.gabek.Kite.dev, build 1231 (baseline.app).
        #expect(RealProfileGuard.isStrayKiteDefault(handlerBundleID: dev, handlerPath: baseline, home: home, resolve: plain))
        #expect(RealProfileGuard.isStrayKiteDefault(handlerBundleID: real, handlerPath: "/Users/gabe/dev/kite-release/build/Kite.app",
                                                    home: home, resolve: plain))
        #expect(!RealProfileGuard.isStrayKiteDefault(handlerBundleID: real, handlerPath: installed, home: home, resolve: plain))
        // Another browser, or a web app's launcher, is none of Kite's business.
        #expect(!RealProfileGuard.isStrayKiteDefault(handlerBundleID: "com.apple.Safari", handlerPath: "/Applications/Safari.app",
                                                     home: home, resolve: plain))
        #expect(!RealProfileGuard.isStrayKiteDefault(handlerBundleID: "dev.gabek.Kite.app.0123456789abcdef", handlerPath: nil,
                                                     home: home, resolve: plain))
    }

    @Test func aServerIsDescribedByItsAppAndStartTime() {
        let started = DateComponents(calendar: Calendar.current, year: 2026, month: 11, day: 5, hour: 17, minute: 12, second: 3).date!
        let server = SocketServerProcess(pid: 651, executablePath: baseline + "/Contents/MacOS/Kite", bundleID: dev,
                                         build: "1231", startedAt: started)
        #expect(server.bundlePath == baseline)
        #expect(server.summary == "PID 651 (\(baseline), dev.gabek.Kite.dev build 1231, started 2026-11-05 17:12:03)")
        #expect(!server.isInstalledKite(home: home))
        #expect(server.notInstalledWarning.contains("not /Applications/Kite.app"))
        #expect(server.notInstalledWarning.contains("kill 651"))
        let real = SocketServerProcess(pid: 11179, executablePath: installed + "/Contents/MacOS/Kite", bundleID: real)
        #expect(real.isInstalledKite(home: home))
        #expect(SocketServerProcess.bundlePath(ofExecutable: "/Users/gabe/dev/kite/.build/debug/Kite") == nil)
    }

    #if canImport(Darwin)
    /// A real socket: the lookup names this test process as its server.
    @Test func theServingProcessIsReadFromTheSocket() throws {
        let path = "/tmp/kite-guard-\(getpid())-\(UInt32.random(in: 0...UInt32.max)).sock"
        defer { unlink(path) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path.utf8)
            buffer[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        #expect(bound == 0)
        #expect(listen(fd, 1) == 0)
        let server = try #require(SocketServerProcess.serving(socketPath: path))
        #expect(server.pid == getpid())
        #expect(server.executablePath != nil)
        #expect(server.startedAt.map { $0 < Date() } == true)
        #expect(SocketServerProcess.serving(socketPath: path + ".none") == nil)
    }
    #endif
}

import AppKit
import KiteCore

/// main.swift's first step: a build that isn't the installed Kite never starts on the real profile
/// (`RealProfileGuard`), so it can't open the user's tabs and cookies or take Claude's automation socket.
///
/// It refuses rather than falling back to a throwaway profile: a fallback would look like Kite with every tab and
/// sign-in gone (what agents saw on 5 Nov 2026), Gabe's links would land in a profile deleted on quit, and an agent
/// that forgot `KITE_SUPPORT_PATH` would go on driving the installed Kite through the real socket, thinking it was
/// its test build. A refusal exits at once with the reason on stderr.
@MainActor
enum RealProfileRefusal {
    static func refuseIfNeeded() {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let bundle = Bundle.main
        // What AppDelegate.supportDirectory is without KITE_SUPPORT_PATH, should it ever differ from the home's.
        var guardEnvironment = environment
        if guardEnvironment[RealProfileGuard.testRealProfileKey] == nil {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Kite", isDirectory: true).path
            if support != RealProfileGuard.realSupportDirectory(home: home) {
                guardEnvironment[RealProfileGuard.testRealProfileKey] = support
            }
        }
        let verdict = RealProfileGuard.check(bundleID: bundle.bundleIdentifier, bundlePath: bundle.bundleURL.path,
                                             environment: guardEnvironment, home: home)
        guard case .refused(let message) = verdict else { return }
        FileHandle.standardError.write(Data((message + "\n").utf8))
        NSLog("%@", message)
        // Launch Services (a link from another app, the Dock, Finder, `open`) is launchd's child: there's nobody
        // reading stderr, so say it on screen. A shell or script that started it reads the line above.
        if getppid() == 1 || environment["KITE_TEST_REFUSAL_ALERT"] == "1" {
            showAlert(message, home: home)
        }
        exit(RealProfileGuard.refusedExitStatus)
    }

    private static func showAlert(_ message: String, home: String) {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let installed = RealProfileGuard.installedBundlePaths(home: home)
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            .first { Bundle(url: $0)?.bundleIdentifier == RealProfileGuard.installedBundleID }
        let opensLinks = isDefaultBrowser
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "This Kite is a test build and won't open your profile"
        var text = "\(Bundle.main.bundleURL.path) isn't the Kite in Applications, so it won't open your tabs and "
            + "sign-ins or take Claude's connection."
        if opensLinks {
            text += "\n\nIt started because macOS's default browser is set to this test build "
                + "(\(Bundle.main.bundleIdentifier ?? "?")), so the link you opened went nowhere."
            if installed != nil { text += " Set the default browser back to the Kite in Applications to fix that." }
        } else {
            text += "\n\nTo test it, launch it with KITE_SUPPORT_PATH set to a fresh folder (mktemp -d /tmp/k.XXXX)."
        }
        alert.informativeText = text + "\n\n" + message
        alert.addButton(withTitle: "Quit")
        if opensLinks, installed != nil { alert.addButton(withTitle: "Use Kite in Applications for Links") }
        WindowPresenter.activateApp()
        guard WindowPresenter.runModal(alert) == .alertSecondButtonReturn, let installed else { return }
        restoreDefaultBrowser(to: installed)
    }

    /// The installed Kite, once launched: if macOS sends web links to another Kite build (a debug bundle, a release
    /// build in a checkout), says so and offers to take them back. That build would start on the real profile the
    /// next time a link is opened from another app with no test Kite running (5 Nov 2026), and builds older than
    /// RealProfileGuard don't refuse.
    static func checkDefaultBrowser() {
        let home = NSHomeDirectory()
        let bundle = Bundle.main
        guard RealProfileGuard.isInstalledKite(bundleID: bundle.bundleIdentifier, bundlePath: bundle.bundleURL.path, home: home),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return }
        let id = Bundle(url: handler)?.bundleIdentifier
        guard RealProfileGuard.isStrayKiteDefault(handlerBundleID: id, handlerPath: handler.path, home: home) else { return }
        NSLog("Kite: macOS opens web links in %@ (%@), not this Kite; a link from another app would start it on the real "
            + "profile.", handler.path, id ?? "?")
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Links open in a test build of Kite"
            alert.informativeText = "macOS sends web links from other apps to \(handler.path) (\(id ?? "?")), not this Kite. "
                + "A link opened while it isn't running starts that build, which is how an old test build took over "
                + "Claude's connection on 5 Nov 2026."
            alert.addButton(withTitle: "Use This Kite for Links")
            alert.addButton(withTitle: "Not Now")
            guard WindowPresenter.runModal(alert) == .alertFirstButtonReturn else { return }
            for scheme in ["http", "https"] {
                // macOS asks the user to confirm the change.
                NSWorkspace.shared.setDefaultApplication(at: bundle.bundleURL, toOpenURLsWithScheme: scheme) { error in
                    if let error { DispatchQueue.main.async { WindowPresenter.presentError(error) } }
                }
            }
        }
    }

    /// Whether Launch Services sends web links to this bundle ID (the incident: a dev bundle as the default browser).
    private static var isDefaultBrowser: Bool {
        guard let id = Bundle.main.bundleIdentifier,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!) else { return false }
        return Bundle(url: handler)?.bundleIdentifier == id
    }

    /// macOS asks the user to confirm each change; waits for both answers before Kite exits.
    private static func restoreDefaultBrowser(to app: URL) {
        var remaining = 2
        for scheme in ["http", "https"] {
            NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) { error in
                if let error { NSLog("Kite: couldn't make %@ the default for %@: %@", app.path, scheme, "\(error)") }
                DispatchQueue.main.async { remaining -= 1 }
            }
        }
        let deadline = Date().addingTimeInterval(120)
        while remaining > 0, Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
    }
}

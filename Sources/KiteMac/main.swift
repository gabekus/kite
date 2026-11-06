import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

MainActor.assumeIsolated {
    // Before anything opens a profile: only the installed Kite may start on the real one (exits otherwise).
    RealProfileRefusal.refuseIfNeeded()
    // A build install-app.sh staged that the last quit didn't swap in: swap it now and open that one instead.
    StagedUpdate.finishIfWaiting()
    let environment = ProcessInfo.processInfo.environment
    if environment["KITE_SUPPORT_PATH"] != nil {
        // A test run shares UserDefaults with whatever app has its bundle ID. Debug bundles are
        // dev.gabek.Kite.dev (bundle-app.sh); as dev.gabek.Kite it would write the installed Kite's settings.
        if Bundle.main.bundleIdentifier == "dev.gabek.Kite" {
            NSLog("Kite: warning: a KITE_SUPPORT_PATH run as dev.gabek.Kite writes the installed Kite's settings; use a debug bundle")
        }
        // scripts/check-test-defaults.sh: shows where a test run's settings land.
        if let key = environment["KITE_TEST_DEFAULTS_PROBE"], !key.isEmpty {
            UserDefaults.standard.set(true, forKey: key)
        }
    }
    let delegate = AppDelegate()
    // Folders of profiles deleted last run, before Chromium (or WebKit) opens any profile.
    ProfileFolders.deletePending()

    #if canImport(CEFBridge)
    // CEF requires its NSApplication subclass, so create it before anything touches NSApp.
    let app = KCApplication.shared as! KCApplication
    app.delegate = delegate
    // Diagnostics runs start as an accessory app, which macOS doesn't bring forward at launch (AppDelegate
    // makes it regular once launched).
    app.setActivationPolicy(UIDiagnostics.enabledByEnvironment ? .accessory : .regular)
    app.willTerminate = {
        delegate.isTerminating = true
        delegate.saveSession()
    }

    if KCRuntime.isAvailable && environment["KITE_ENGINE"] != "webkit" {
        let settings = KCRuntimeSettings()
        settings.profilePath = AppDelegate.supportDirectory.appendingPathComponent("Chromium").path
        // Extensions such as 1Password reach their desktop apps through these. Chromium reads a
        // manifest on every connect, so syncing again when Kite comes forward picks up new apps.
        let hostsDirectory = URL(fileURLWithPath: settings.profilePath).appendingPathComponent("NativeMessagingHosts")
        let hostsQueue = DispatchQueue(label: "dev.gabek.Kite.native-messaging-hosts", qos: .utility)
        let syncHosts = { NativeMessagingHosts.sync(from: NativeMessagingHosts.macSourceDirectories(), into: hostsDirectory) }
        syncHosts()
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil) { _ in
            hostsQueue.async { syncHosts() }
        }
        settings.remoteDebuggingPort = Int32(environment["KITE_REMOTE_DEBUGGING_PORT"] ?? "") ?? 0
        KCRuntime.energySaverEnabled = AppDelegate.energySaverSetting
        // Test profiles stay out of the login keychain, so test runs never prompt
        // for "Chromium Safe Storage". KITE_MOCK_KEYCHAIN=0 or 1 overrides.
        settings.useMockKeychain = environment["KITE_MOCK_KEYCHAIN"].map { $0 == "1" }
            ?? (environment["KITE_SUPPORT_PATH"] != nil)
        // Diagnostics runs sit behind the user's windows; keep pages painting so ui capture sees them.
        if UIDiagnostics.enabledByEnvironment {
            settings.extraSwitches = ["--disable-backgrounding-occluded-windows", "--disable-renderer-backgrounding"]
        }
        // Kite's helper extension lists and manages extensions (ExtensionsModel).
        if let helper = Bundle.main.resourceURL?.appendingPathComponent("KiteHelperExtension"),
           FileManager.default.fileExists(atPath: helper.appendingPathComponent("manifest.json").path) {
            settings.extensionDirectories = [helper.path]
        }
        // scripts/test-profile-in-use.sh: a test profile can make Chromium "fail" with a given CEF result code.
        let forcedFailure = environment["KITE_SUPPORT_PATH"] == nil ? nil : environment["KITE_TEST_CHROMIUM_FAIL"].flatMap { Int32($0) }
        if forcedFailure == nil, KCRuntime.initialize(with: settings) {
            delegate.engine = ChromiumEngine()
            KCRuntime.runMessageLoop()
            KCRuntime.shutdown()
            exit(0)
        }
        // Chromium didn't start (most often the last Kite's helpers still hold the profile, right after a restart).
        // CEF can't be initialized twice in a process, so Kite starts itself again (execv: same PID, so a script's $!
        // still names it) rather than drop to WebKit.
        let attempt = EngineFallback.attempt(environment: environment)
        let startAgain = { (why: String) in
            guard let executable = Bundle.main.executablePath else { return }
            let args = CommandLine.arguments.map { strdup($0) } + [nil]
            execv(executable, args)
            NSLog("Kite: couldn't start again for %@ (errno %d)", why, errno)
        }
        let exitCode = forcedFailure ?? KCRuntime.lastExitCode
        // Another Kite has the profile: a restart's old one gets a few seconds to quit; one that stays is refused.
        if EngineFallback.profileInUseExitCodes.contains(exitCode) {
            RealProfileRefusal.waitForProfileHolder(profile: settings.profilePath)
        }
        switch EngineFallback.next(attempt: attempt, exitCode: exitCode) {
        case .retry:
            NSLog("Kite: Chromium didn't start (try %d of %d); starting again", attempt, EngineFallback.maxAttempts)
            Thread.sleep(forTimeInterval: EngineFallback.retryDelay)
            setenv(EngineFallback.attemptKey, String(attempt + 1), 1)
            startAgain("another try")
        case .refuseProfileInUse:
            // Still open after every try: another Kite is using it, not one that's quitting.
            RealProfileRefusal.refuseProfileInUse(profile: settings.profilePath)
        case .webKit:
            NSLog("Kite: Chromium didn't start after %d tries; starting again on WebKit", attempt)
            // Not in this process: after a failed CefInitialize, AppKit never finishes launching here.
            setenv("KITE_ENGINE", "webkit", 1)
            setenv(EngineFallback.fellBackKey, "1", 1)
            startAgain("WebKit")
        }
        // execv failed: there's no good way on from here.
        exit(1)
    }
    // The fresh process a failed Chromium started on WebKit (EngineFallback.Step.webKit).
    if environment["KITE_ENGINE"] == "webkit", environment[EngineFallback.fellBackKey] == "1" {
        AppDelegate.engineFellBack = true
    }
    #else
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(UIDiagnostics.enabledByEnvironment ? .accessory : .regular)
    #endif

    delegate.engine = WebKitEngine()
    ProfileFolders.usesWebKit = true
    app.run()
}

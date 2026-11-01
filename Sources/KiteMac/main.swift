import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

MainActor.assumeIsolated {
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

    #if canImport(CEFBridge)
    // CEF requires its NSApplication subclass, so create it before anything touches NSApp.
    let app = KCApplication.shared as! KCApplication
    app.delegate = delegate
    // Diagnostics runs start as an accessory app, which macOS doesn't bring forward at launch (AppDelegate
    // makes it regular once launched).
    app.setActivationPolicy(UIDiagnostics.enabledByEnvironment ? .accessory : .regular)
    app.willTerminate = { delegate.saveSession() }

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
        KCRuntime.energySaverEnabled = UserDefaults.standard.bool(forKey: AppDelegate.energySaverKey)
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
        if KCRuntime.initialize(with: settings) {
            delegate.engine = ChromiumEngine()
            KCRuntime.runMessageLoop()
            KCRuntime.shutdown()
            exit(0)
        }
    }
    #else
    let app = NSApplication.shared
    app.delegate = delegate
    app.setActivationPolicy(UIDiagnostics.enabledByEnvironment ? .accessory : .regular)
    #endif

    delegate.engine = WebKitEngine()
    app.run()
}

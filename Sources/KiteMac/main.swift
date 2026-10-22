import AppKit
#if canImport(CEFBridge)
import CEFBridge
#endif

MainActor.assumeIsolated {
    let environment = ProcessInfo.processInfo.environment
    let delegate = AppDelegate()

    #if canImport(CEFBridge)
    // CEF requires its NSApplication subclass, so create it before anything touches NSApp.
    let app = KCApplication.shared as! KCApplication
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.willTerminate = { delegate.saveSession() }

    if KCRuntime.isAvailable && environment["KITE_ENGINE"] != "webkit" {
        let settings = KCRuntimeSettings()
        settings.profilePath = AppDelegate.supportDirectory.appendingPathComponent("Chromium").path
        settings.remoteDebuggingPort = Int32(environment["KITE_REMOTE_DEBUGGING_PORT"] ?? "") ?? 0
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
    app.setActivationPolicy(.regular)
    #endif

    delegate.engine = WebKitEngine()
    app.run()
}

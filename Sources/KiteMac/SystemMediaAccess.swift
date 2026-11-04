import AppKit
import AVFoundation

/// macOS's own camera and microphone access for Kite (System Settings › Privacy & Security).
/// A site Kite allows can use them only once macOS has allowed Kite too: onboarding asks up
/// front, and CEFBridge asks the first time a site is given either.
@MainActor
enum SystemMediaAccess {
    enum Device: CaseIterable {
        case camera, microphone

        var mediaType: AVMediaType { self == .camera ? .video : .audio }
        var title: String { self == .camera ? "Camera" : "Microphone" }
        /// Its own pane in Privacy & Security, where macOS lists Kite once Kite has asked.
        var settingsURL: URL? {
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_\(self == .camera ? "Camera" : "Microphone")")
        }
    }

    enum Status { case allowed, notAsked, off }

    static func status(_ device: Device) -> Status {
        switch AVCaptureDevice.authorizationStatus(for: device.mediaType) {
        case .authorized: .allowed
        case .notDetermined: .notAsked
        default: .off
        }
    }

    /// Asks macOS about each device it hasn't been asked about yet, one prompt after the other.
    static func requestAll() async {
        for device in Device.allCases where status(device) == .notAsked {
            _ = await AVCaptureDevice.requestAccess(for: device.mediaType)
        }
    }

    static func openSettings(_ device: Device) {
        if let url = device.settingsURL { NSWorkspace.shared.open(url) }
    }

    /// A site Kite allowed can't have `devices` because macOS has them off: says so in `window`'s
    /// browser window (or the front one), with the way to turn them on.
    static func reportBlocked(_ devices: [Device], in window: NSWindow?) {
        guard let first = devices.first else { return }
        let controller = window?.windowController as? BrowserWindowController
            ?? NSApp.orderedWindows.lazy.compactMap { $0.windowController as? BrowserWindowController }.first
        let names = devices.map { $0.title.lowercased() }.joined(separator: " and ")
        controller?.showToast("Kite can’t use your \(names): it’s off in System Settings.",
                              action: (title: "Turn On…", run: { openSettings(first) }))
    }
}

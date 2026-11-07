import AppKit
import AVFoundation
import CoreBluetooth
import CoreGraphics
import CoreLocation
import EventKit
import UserNotifications

/// Every macOS permission Kite uses (System Settings › Privacy & Security), so onboarding can ask for
/// them all up front instead of one at a time when a site or a feature first needs one.
@MainActor
enum SystemAccess {
    enum Permission: CaseIterable {
        case camera, microphone, location, notifications, calendars, bluetooth, screenRecording, fullDiskAccess

        var title: String {
            switch self {
            case .camera: "Camera"
            case .microphone: "Microphone"
            case .location: "Location"
            case .notifications: "Notifications"
            case .calendars: "Calendars"
            case .bluetooth: "Bluetooth"
            case .screenRecording: "Screen Recording"
            case .fullDiskAccess: "Full Disk Access"
            }
        }

        /// What Kite uses it for, as the row's tooltip.
        var purpose: String {
            switch self {
            case .camera: "Video calls on sites you allow."
            case .microphone: "Calls and voice search on sites you allow."
            case .location: "Maps and nearby results on sites you allow."
            case .notifications: "Tells you when Claude finishes a task."
            case .calendars: "Upcoming events when you hover a calendar favorite."
            case .bluetooth: "Signing in with a passkey from your phone."
            case .screenRecording: "Sharing your screen on calls."
            case .fullDiskAccess: "Fills in codes from your texts, and imports Safari's history."
            }
        }

        var symbol: String {
            switch self {
            case .camera: "video.fill"
            case .microphone: "mic.fill"
            case .location: "location.fill"
            case .notifications: "bell.fill"
            case .calendars: "calendar"
            case .bluetooth: "dot.radiowaves.left.and.right"
            case .screenRecording: "rectangle.dashed.badge.record"
            case .fullDiskAccess: "internaldrive.fill"
            }
        }

        /// Whether macOS can show its own prompt for it. Full Disk Access is only turned on in System Settings.
        var canAsk: Bool { self != .fullDiskAccess }

        /// Its pane in System Settings.
        var settingsURL: URL? {
            let pane: String
            switch self {
            case .camera: pane = "com.apple.preference.security?Privacy_Camera"
            case .microphone: pane = "com.apple.preference.security?Privacy_Microphone"
            case .location: pane = "com.apple.preference.security?Privacy_LocationServices"
            case .notifications: pane = "com.apple.Notifications-Settings.extension?id=\(Bundle.main.bundleIdentifier ?? "dev.gabek.Kite")"
            case .calendars: pane = "com.apple.preference.security?Privacy_Calendars"
            case .bluetooth: pane = "com.apple.preference.security?Privacy_Bluetooth"
            case .screenRecording: pane = "com.apple.preference.security?Privacy_ScreenCapture"
            case .fullDiskAccess: pane = "com.apple.preference.security?Privacy_AllFiles"
            }
            return URL(string: "x-apple.systempreferences:" + pane)
        }
    }

    enum Status: Equatable { case allowed, notAsked, off }

    /// Notifications only answer asynchronously; this is the last answer, refreshed by `refresh()`.
    private static var notificationStatus = Status.notAsked
    private static let askedScreenRecordingKey = "askedScreenRecording"
    /// UNUserNotificationCenter throws outside an app bundle (`swift build`'s .build/debug/Kite).
    private static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    /// What macOS says about each permission now (notifications as of the last `refresh()`).
    static func status(_ permission: Permission) -> Status {
        switch permission {
        case .camera: return SystemMediaAccess.status(.camera).access
        case .microphone: return SystemMediaAccess.status(.microphone).access
        case .location:
            switch CLLocationManager().authorizationStatus {
            case .notDetermined: return .notAsked
            case .denied, .restricted: return .off
            default: return .allowed
            }
        case .notifications: return notificationStatus
        case .calendars:
            switch EKEventStore.authorizationStatus(for: .event) {
            case .fullAccess: return .allowed
            case .notDetermined: return .notAsked
            default: return .off
            }
        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways: return .allowed
            case .notDetermined: return .notAsked
            default: return .off
            }
        case .screenRecording:
            // macOS has no "not asked yet" for it; Kite remembers whether it asked. A grant counts
            // once Kite restarts.
            if CGPreflightScreenCaptureAccess() { return .allowed }
            return UserDefaults.standard.bool(forKey: askedScreenRecordingKey) ? .off : .notAsked
        case .fullDiskAccess:
            // macOS's own permission database can only be opened with Full Disk Access.
            return BrowserImportController.access(URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC/TCC.db")) == .readable
                ? .allowed : .off
        }
    }

    static func statuses() -> [(Permission, Status)] { Permission.allCases.map { ($0, status($0)) } }

    /// Re-reads what only answers asynchronously.
    static func refresh() async {
        guard isBundled else { return }
        notificationStatus = switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional, .ephemeral: .allowed
        case .notDetermined: .notAsked
        default: .off
        }
    }

    /// macOS's prompt for each permission it hasn't been asked about yet, one after the other.
    static func requestAll() async {
        for permission in Permission.allCases where permission.canAsk && status(permission) == .notAsked {
            await request(permission)
        }
        await refresh()
    }

    static func request(_ permission: Permission) async {
        switch permission {
        case .camera: _ = await AVCaptureDevice.requestAccess(for: .video)
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .location: await LocationPrompt().ask()
        case .notifications:
            guard isBundled else { return }
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        case .calendars: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .bluetooth: await BluetoothPrompt().ask()
        case .screenRecording:
            UserDefaults.standard.set(true, forKey: askedScreenRecordingKey)
            // Shows macOS's prompt, which sends the user to System Settings; it answers at once.
            _ = CGRequestScreenCaptureAccess()
        case .fullDiskAccess: openSettings(.fullDiskAccess)
        }
    }

    static func openSettings(_ permission: Permission) {
        if let url = permission.settingsURL { WindowPresenter.open(url) }
    }
}

private extension SystemMediaAccess.Status {
    var access: SystemAccess.Status {
        switch self {
        case .allowed: .allowed
        case .notAsked: .notAsked
        case .off: .off
        }
    }
}

/// Asks for location while Kite is in use and waits for the answer.
@MainActor
private final class LocationPrompt: NSObject, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<Void, Never>?

    func ask() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.requestWhenInUseAuthorization()
            // With Location Services off for the whole Mac there's no prompt and no answer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in MainActor.assumeIsolated { self?.finish() } }
        }
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        // The delegate first reports the current (undetermined) state, before the user answers.
        guard manager.authorizationStatus != .notDetermined else { return }
        finish()
    }
}

/// Bluetooth has no request call: making a central manager is what shows macOS's prompt.
@MainActor
private final class BluetoothPrompt: NSObject, @preconcurrency CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var continuation: CheckedContinuation<Void, Never>?

    func ask() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager = CBCentralManager(delegate: self, queue: .main)
            DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in MainActor.assumeIsolated { self?.finish() } }
        }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard CBManager.authorization != .notDetermined else { return }
        finish()
    }

    private func finish() {
        continuation?.resume()
        continuation = nil
        manager = nil
    }
}

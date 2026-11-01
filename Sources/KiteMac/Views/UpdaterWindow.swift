import AppKit
import KiteCore
import SwiftUI

/// Kite › Check for Updates…: a small status window, like Arc's (Sparkle with its own
/// `SoftwareUpdaterClient.UpdaterWindowView`): "Checking for updates..." with Cancel, then
/// "Your browser is up to date", or the new version's notes with Remind Me Later and Download.
/// Kite asks GitHub releases (see `Updates`) and opens the release in a tab; it never installs.
@MainActor
final class UpdaterWindow {
    static let shared = UpdaterWindow()

    /// Opens a URL in a new Kite tab.
    var openURL: (URL) -> Void = { NSWorkspace.shared.open($0) }

    private var window: NSWindow?
    private let model = UpdaterModel()
    private var task: Task<Void, Never>?

    func checkForUpdates() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        check()
    }

    private func check() {
        task?.cancel()
        model.state = .checking
        let current = Self.currentVersion
        let feed = Self.feedURL
        task = Task { [model] in
            let outcome = await Self.fetch(feed: feed, currentVersion: current)
            guard !Task.isCancelled else { return }
            model.state = .done(outcome)
        }
    }

    private func close() {
        task?.cancel()
        window?.orderOut(nil)
    }

    private func open(_ url: URL) {
        openURL(url)
        close()
    }

    /// CFBundleShortVersionString. A bare `swift build` binary has no Info.plist and counts as 0.0.0.
    static var bundleVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }
    static var currentVersion: String { bundleVersion ?? "0.0.0" }
    static var runningDescription: String { bundleVersion.map { "Kite \($0)" } ?? "a development build" }

    /// GitHub's latest-release endpoint. A test run (KITE_DIAGNOSTICS=1 on a throwaway profile) may point it at a
    /// local file with KITE_UPDATE_FEED_URL to exercise the "available" state.
    static var feedURL: URL {
        if UIDiagnostics.enabledByEnvironment,
           let override = ProcessInfo.processInfo.environment["KITE_UPDATE_FEED_URL"].flatMap(URL.init(string:)) {
            return override
        }
        return Updates.latestReleaseURL
    }

    static func fetch(feed: URL, currentVersion: String) async -> Updates.Outcome {
        if feed.isFileURL {
            guard let data = try? Data(contentsOf: feed) else { return Updates.outcome(currentVersion: currentVersion, statusCode: 404, body: Data()) }
            return Updates.outcome(currentVersion: currentVersion, statusCode: 200, body: data)
        }
        var request = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Kite/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            return Updates.outcome(currentVersion: currentVersion, statusCode: status, body: data)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Software Update"
        window.isReleasedWhenClosed = false
        let view = UpdaterView(
            model: model,
            close: { [weak self] in self?.close() },
            open: { [weak self] in self?.open($0) },
            retry: { [weak self] in self?.check() }
        )
        // The window follows the view's size as the state changes.
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        window.contentViewController = host
        return window
    }
}

@MainActor
final class UpdaterModel: ObservableObject {
    enum State: Equatable {
        case checking
        case done(Updates.Outcome)
    }

    @Published var state: State = .checking
}

private struct UpdaterView: View {
    @ObservedObject var model: UpdaterModel
    let close: () -> Void
    let open: (URL) -> Void
    let retry: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
        .frame(width: 440)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .checking:
            Text("Checking for updates...").font(.headline)
            ProgressView().progressViewStyle(.linear)
            buttons { Button("Cancel", action: close).keyboardShortcut(.cancelAction) }
        case .done(.upToDate(let current)):
            Text("Your browser is up to date").font(.headline)
            Text("Kite \(current.description) is the newest version.").foregroundStyle(.secondary)
            buttons { Button("Close", action: close).keyboardShortcut(.defaultAction) }
        case .done(.noReleases):
            Text("No updates yet").font(.headline)
            Text("Kite hasn’t published a release yet. You’re running \(UpdaterWindow.runningDescription).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Open Releases Page") { open(Updates.releasesPageURL) }
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        case .done(.available(let release)):
            Text("A new version is available").font(.headline)
            Text("\(release.title) is available. You’re running \(UpdaterWindow.runningDescription).")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !release.notes.isEmpty {
                ScrollView {
                    Text(release.notes)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(height: 140)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            buttons {
                Button("Remind Me Later", action: close).keyboardShortcut(.cancelAction)
                if let download = release.download {
                    Button("View Release") { open(release.pageURL) }
                    Button("Download") { open(download) }.keyboardShortcut(.defaultAction)
                } else {
                    Button("View Release") { open(release.pageURL) }.keyboardShortcut(.defaultAction)
                }
            }
        case .done(.failed(let message)):
            Text("Couldn’t check for updates").font(.headline)
            Text(message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons {
                Button("Download manually") { open(Updates.releasesPageURL) }
                Button("Try Again", action: retry)
                Button("Close", action: close).keyboardShortcut(.defaultAction)
            }
        }
    }

    private func buttons<B: View>(@ViewBuilder _ content: () -> B) -> some View {
        HStack {
            Spacer()
            content()
        }
        .padding(.top, 4)
    }
}

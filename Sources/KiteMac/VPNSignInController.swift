import AppKit
import KiteCore

/// Quiet VPN sign-in (VPNSignIn): a sign-in page a VPN client opened on a watched host loads in a
/// hidden page of its space's profile, so the user's SSO cookies carry it through, and closes when
/// it's done. A page that needs the user becomes a background tab, with one Dock bounce.
@MainActor
final class VPNSignInController {
    static let shared = VPNSignInController()

    struct Host {
        /// The engine (the space's profile) a link to that space loads in.
        var engine: (_ spaceID: UUID?) -> WebEngine
        /// Puts the page in a tab of that space, behind the selected one, without raising the window.
        var showInBackground: (_ page: WebPage, _ url: URL?, _ title: String?, _ spaceID: UUID?, _ profileDirectory: String?) -> Void
    }

    var host: Host?
    private(set) var recentHosts: [String] = []
    private(set) var last: VPNSignIn.Outcome?
    private var running: [Running] = []
    private var waiters: [(id: UUID, since: Date, resume: CheckedContinuation<VPNSignIn.Outcome?, Never>)] = []

    private final class Running {
        var run: VPNSignIn.Run
        let page: WebPage
        let spaceID: UUID?
        var timer: Timer?
        var outcome: VPNSignIn.Outcome
        init(run: VPNSignIn.Run, page: WebPage, spaceID: UUID?) {
            self.run = run
            self.page = page
            self.spaceID = spaceID
            outcome = .init(host: run.start.host() ?? "", startedAt: run.startedAt, result: .running)
        }
    }

    var hosts: [String] {
        get { VPNSignIn.hosts(in: .standard) }
        set { VPNSignIn.setHosts(newValue, in: .standard) }
    }

    /// A link from another app: true when Kite handles it quietly (the caller opens nothing).
    func handle(_ url: URL, spaceID: UUID?) -> Bool {
        if let linkHost = url.host()?.lowercased(), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            recentHosts = VPNSignIn.remember(linkHost, in: recentHosts)
        }
        let hosts = self.hosts
        guard let host, VPNSignIn.matches(url, hosts: hosts) else { return false }
        let engine = host.engine(spaceID)
        let page = engine.makePage(url: url, restoring: nil)
        let running = Running(run: VPNSignIn.Run(start: url, hosts: hosts), page: page, spaceID: spaceID)
        self.running.append(running)
        last = running.outcome
        NSLog("Kite: quiet VPN sign-in started on %@", running.outcome.host)
        running.timer = Timer.scheduledTimer(withTimeInterval: VPNSignIn.pollInterval, repeats: true) { [weak self, weak running] _ in
            MainActor.assumeIsolated {
                guard let self, let running else { return }
                self.look(running, profileDirectory: engine.profileDirectory)
            }
        }
        return true
    }

    private func look(_ running: Running, profileDirectory: String?) {
        let page = running.page
        page.evaluateJavaScript(VPNSignIn.probeScript) { [weak self, weak running] value in
            MainActor.assumeIsolated {
                guard let self, let running, running.timer != nil else { return }
                let look = VPNSignIn.look(fromProbe: value, isLoading: page.isLoading)
                switch running.run.step(look) {
                case .wait:
                    return
                case .done:
                    page.close()
                    self.finish(running, .signedIn)
                case .needsUser(let reason):
                    self.host?.showInBackground(page, look.url ?? running.run.start, look.title, running.spaceID, profileDirectory)
                    NSApp.requestUserAttention(.informationalRequest)
                    self.finish(running, .shown(reason))
                }
            }
        }
    }

    private func finish(_ running: Running, _ result: VPNSignIn.Outcome.Result) {
        running.timer?.invalidate()
        running.timer = nil
        running.outcome.result = result
        running.outcome.finishedAt = Date()
        last = running.outcome
        self.running.removeAll { $0 === running }
        NSLog("Kite: quiet VPN sign-in on %@ ended: %@", running.outcome.host, running.outcome.summary)
        let ready = waiters.filter { $0.since <= running.outcome.startedAt }
        waiters.removeAll { $0.since <= running.outcome.startedAt }
        for waiter in ready { waiter.resume.resume(returning: running.outcome) }
    }

    /// The next sign-in that ends, one running now or started from `since` on; nil after `timeout`.
    func waitForSignIn(since: Date, timeout: TimeInterval) async -> VPNSignIn.Outcome? {
        if let last, last.result != .running, last.startedAt >= since { return last }
        let since = running.map(\.outcome.startedAt).min().map { min($0, since) } ?? since
        return await withCheckedContinuation { continuation in
            let id = UUID()
            waiters.append((id, since, continuation))
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                    self.waiters.remove(at: index).resume.resume(returning: nil)
                }
            }
        }
    }

    /// The `vpn` tool, Kite's side. `reconnect` runs the VPN client in the CLI first; here it only waits.
    func run(_ action: VPNAction) async -> String {
        switch action {
        case .status:
            return status()
        case .watch(let host):
            hosts = hosts + [host]
            return "Kite now signs in quietly on \(host) and its subdomains.\n" + status()
        case .unwatch(let host):
            let before = hosts
            hosts = before.filter { $0 != host }
            return (before.contains(host) ? "Stopped watching \(host)." : "\(host) wasn't watched.") + "\n" + status()
        case .reconnect(_, let timeout), .wait(let timeout):
            guard !hosts.isEmpty else { return status() }
            guard let outcome = await waitForSignIn(since: Date(), timeout: timeout) else {
                return "No VPN sign-in page came to Kite within \(Int(timeout)) s.\n" + status()
            }
            return outcome.summary
        }
    }

    func status() -> String {
        let report = VPNSignIn.statusReport(hosts: hosts, recent: recentHosts, last: last, isOn: host != nil)
        return UntrustedContent.wrap(report, source: "vpn")
    }
}

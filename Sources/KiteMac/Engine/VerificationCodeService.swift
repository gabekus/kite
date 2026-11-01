#if canImport(CEFBridge)
import AppKit
import KiteCore

/// Finds the code a site just emailed or texted you and offers it in the site's code
/// field (VerificationCodeScript).
///
/// Texts (iMessage and SMS) come from Messages' database on this Mac
/// (MessagesCodeReader), when Kite has Full Disk Access. Mail comes from Gmail's feed of unread inbox mail, read with your own Gmail sign-in
/// in Kite: a hidden page on mail.google.com fetches `/mail/u/N/feed/atom` for each
/// signed-in account. Kite only looks while a code field is waiting (up to three
/// minutes), and the code never leaves your Mac.
@MainActor
final class VerificationCodeService {
    static let shared = VerificationCodeService()

    private struct Waiter {
        weak var page: ChromiumPage?
        let context: Int
        let host: String
        let until: Date
        var offered: String?
    }

    private var engine: WebEngine?
    private var waiters: [Waiter] = []
    private var mailPage: ChromiumPage?
    private var mailPageReady = false
    private var timer: Timer?
    private var fetching = false
    private var readingTexts = false
    private var mail: [VerificationCodes.Message] = []
    private var texts: [VerificationCodes.Message] = []

    private static let pollInterval: TimeInterval = 3
    private static let waitLimit: TimeInterval = 180
    /// KITE_TEST_MAIL_ORIGIN (test profiles only) serves the feeds from elsewhere.
    private static var feedPage: URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let origin = environment["KITE_TEST_MAIL_ORIGIN"],
           let url = URL(string: origin + "/mail/u/0/feed/atom") { return url }
        return URL(string: "https://mail.google.com/mail/u/0/feed/atom")!
    }
    /// Each signed-in account's feed, until one is missing or repeats.
    private static let fetchFeeds = #"""
    (async () => {
      const feeds = [];
      for (let n = 0; n < 6; n++) {
        try {
          const r = await fetch(`/mail/u/${n}/feed/atom`, { credentials: 'include', cache: 'no-store' });
          if (!r.ok || !/xml/.test(r.headers.get('content-type') || '')) break;
          const text = await r.text();
          const account = (text.match(/<title>[^<]*<\/title>/) || [''])[0];
          if (feeds.some((f) => f.includes(account))) break;
          feeds.push(text);
        } catch {
          break;
        }
      }
      return JSON.stringify(feeds);
    })()
    """#

    /// The persistent profile's engine: its Gmail sign-in is the one to read with.
    func configure(engine: WebEngine) {
        self.engine = engine
    }

    /// A code field got focus in `page` (in Kite's world, execution context `context`).
    func codeWanted(by page: ChromiumPage, context: Int, host: String) {
        guard engine != nil else { return }
        waiters.removeAll { $0.page == nil || $0.page === page }
        waiters.append(Waiter(page: page, context: context, host: host, until: Date().addingTimeInterval(Self.waitLimit)))
        poll()
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    /// The code went in: stop looking for that page.
    func codeUsed(by page: ChromiumPage) {
        waiters.removeAll { $0.page == nil || $0.page === page }
        if waiters.isEmpty { stop() }
    }

    private func poll() {
        let now = Date()
        waiters.removeAll { $0.page == nil || $0.until < now }
        guard !waiters.isEmpty else { return stop() }
        readTexts()
        guard let page = mailPage ?? makeMailPage() else { return }
        guard mailPageReady, !fetching else { return }
        fetching = true
        page.evaluate(Self.fetchFeeds, userGesture: false) { [weak self] value, _ in
            guard let self else { return }
            self.fetching = false
            let feeds = ((value as? String)?.data(using: .utf8)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
            let messages = feeds.flatMap { VerificationCodes.parseGmailFeed(Data($0.utf8)) }
            self.mail = messages
            self.offer()
        }
    }

    private func readTexts() {
        guard !readingTexts else { return }
        readingTexts = true
        DispatchQueue.global(qos: .userInitiated).async {
            let texts = MessagesCodeReader.recent()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self.readingTexts = false
                    self.texts = texts
                    self.offer()
                }
            }
        }
    }

    private func offer() {
        let messages = mail + texts
        for i in waiters.indices {
            guard let page = waiters[i].page,
                  let found = VerificationCodes.best(in: messages, forHost: waiters[i].host),
                  found.code != waiters[i].offered,
                  let script = VerificationCodeScript.offer(code: found.code, sender: found.sender) else { continue }
            waiters[i].offered = found.code
            page.browser.callDevToolsMethod("Runtime.evaluate", params: ["expression": script, "contextId": waiters[i].context]) { _, _ in }
        }
    }

    private func makeMailPage() -> ChromiumPage? {
        guard let page = engine?.makePage(url: Self.feedPage, restoring: nil) as? ChromiumPage else { return nil }
        mailPage = page
        mailPageReady = false
        page.onEvent = { [weak self] event in
            guard let self, case let .navigationState(isLoading, _, _) = event, !isLoading, !self.mailPageReady else { return }
            self.mailPageReady = true
            self.poll()
        }
        return page
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        mailPage?.onEvent = nil
        mailPage?.close()
        mailPage = nil
        mailPageReady = false
        mail = []
        texts = []
    }
}
#endif

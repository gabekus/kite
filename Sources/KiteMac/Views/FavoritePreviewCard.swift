import AppKit
import EventKit
import KiteCore
import SwiftUI

/// Arc's favorite previews (`AppPreviews`, `PreviewView`, `StandardPreviewView`): hover a Gmail,
/// Google Calendar, Notion, Linear, Figma or Confluence favorite and a card next to the sidebar
/// lists unread mail, upcoming events or recent pages. The card lives in a borderless child window
/// of the browser window (Arc's preview is its own window too: its frame animates with
/// `setFrame:display:animate:`), stays while the pointer is on the tile or the card, and closes when
/// it leaves both. Sources are in docs/arc-visual-spec.md ("Favorite previews").
@MainActor
final class FavoritePreviewController {
    /// What the window controller provides.
    struct Host {
        /// The favorite's profile folder (its history and sign-ins).
        var profile: (UUID) -> String
        var history: (String) -> HistoryStore?
        var engine: (UUID) -> WebEngine?
        /// Opens `URL` in favorite `UUID` and shows it.
        var open: (UUID, URL) -> Void
    }

    private let host: Host
    private let model = FavoritePreviewModel()
    private var window: FavoritePreviewWindow?
    private var hovered: (id: UUID, anchor: NSView)?
    private var shownID: UUID?
    private var showWork: DispatchWorkItem?
    private var leaveWork: DispatchWorkItem?
    private var resignObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?
    private var favorites: () -> [BrowserTab] = { [] }
    /// Shared by every window, so two windows don't read the same mail twice.
    private let fetcher = FavoritePreviewFetcher.shared

    init(host: Host) {
        self.host = host
        model.open = { [weak self] url in self?.openFromCard(url) }
        model.signIn = { [weak self] in self?.signIn() }
    }

    isolated deinit {
        for observer in [resignObserver, activeObserver].compactMap({ $0 }) { NotificationCenter.default.removeObserver(observer) }
    }

    /// The pointer moved onto favorite `tab` (anchored at its tile), or off it (nil).
    func hover(_ tab: BrowserTab?, anchor: NSView?) {
        guard FavoritePreviews.isEnabled() else { return }
        guard let tab, let anchor, let kind = FavoritePreviews.kind(for: tab.pinnedURL ?? tab.url) else {
            hovered = nil
            showWork?.cancel()
            if shownID != nil { scheduleLeaveCheck() }
            return
        }
        hovered = (tab.id, anchor)
        leaveWork?.cancel()
        if shownID == tab.id { return }
        showWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.show(tab, kind: kind) }
        showWork = work
        // A card already up for another favorite moves over straight away.
        DispatchQueue.main.asyncAfter(deadline: .now() + (shownID == nil ? Timing.showDelay : 0), execute: work)
    }

    func dismiss(animated: Bool = true) {
        showWork?.cancel()
        leaveWork?.cancel()
        shownID = nil
        window?.close(animated: animated)
    }

    // MARK: Showing

    enum Timing {
        /// Pointer on the tile this long before the card opens (measured on Arc: about 0.39s from
        /// the pointer reaching the tile to the card's first frame).
        static let showDelay: Double = 0.38
        /// After the pointer leaves the tile or card, the card waits this long (Arc's was gone within
        /// 0.1s; the card overlaps the tile, so the pointer never crosses a gap to reach it).
        static let leaveDelay: Double = 0.05
        /// Arc's card faded in over about 0.05–0.09s and out in about 0.04s.
        static let fade: Double = 0.08
        /// A preview's data is fetched again when it's older than this.
        static let staleAfter: TimeInterval = 50
    }

    private func show(_ tab: BrowserTab, kind: FavoritePreviews.Kind) {
        guard let (id, anchor) = hovered, id == tab.id, let parent = anchor.window, parent.isVisible else { return }
        shownID = tab.id
        let profile = host.profile(tab.id)
        model.show(tab: tab, kind: kind, content: fetcher.cached(kind, profile: profile))
        refresh(kind, profile: profile, tab: tab.id)

        let card = window ?? FavoritePreviewWindow(model: model)
        if window == nil {
            window = card
            card.onSizeChange = { [weak self] in self?.layout() }
            card.onHover = { [weak self] inside in
                guard let self else { return }
                if inside { self.leaveWork?.cancel() } else { self.scheduleLeaveCheck() }
            }
        }
        if card.parent !== parent {
            card.parent?.removeChildWindow(card)
            parent.addChildWindow(card, ordered: .above)
            observeResign(of: parent)
        }
        layout()
        card.show()
    }

    /// Arc keeps its previews fetched (`PreviewsDataClient.setPeriodicUpdatesEnabled`, a refresh
    /// timer), so its Gmail card opened with the mail already in it. Kite reads Gmail favorites' mail
    /// only when a card may be wanted soon rather than every minute in the background: when Kite comes
    /// to the front, and when the pointer comes onto the favorites tray (`prefetch`), at least the
    /// card's 0.38s hover delay before it opens. Either reads only mail older than `staleAfter`, and
    /// the hidden page that reads it closes once it's idle (`GmailFeedReader.idleTimeout`).
    func startPrefetching(_ favorites: @escaping () -> [BrowserTab]) {
        guard activeObserver == nil else { return }
        self.favorites = favorites
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.prefetch() }
        }
    }

    /// Reads each Gmail favorite's mail unless it was read in the last `staleAfter`.
    func prefetch() {
        guard FavoritePreviews.isEnabled() else { return }
        for tab in favorites() {
            guard let kind = FavoritePreviews.kind(for: tab.pinnedURL ?? tab.url), case .gmail = kind else { continue }
            refresh(kind, profile: host.profile(tab.id), tab: tab.id)
        }
    }

    private func refresh(_ kind: FavoritePreviews.Kind, profile: String, tab: UUID) {
        guard fetcher.isStale(kind, profile: profile) else { return }
        let history = host.history(profile)
        fetcher.fetch(kind, profile: profile, engine: { [host] in host.engine(tab) }, history: history) { [weak self] content in
            guard let self, self.shownID == tab, self.model.kind == kind else { return }
            self.model.content = content
        }
    }

    /// Arc's card hangs off the tile's bottom-right corner, over the sidebar (measured on its Gmail
    /// favorite: tile 8–70.25 × 145–192, card from 66.5, 188, the same wherever the pointer is on the tile).
    private func layout() {
        guard let window, let anchor = hovered?.anchor ?? window.anchor, let parent = window.parent else { return }
        window.anchor = anchor
        let tile = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        let size = window.cardSize
        let top = tile.minY + M.tileOverlapY
        let y = max(top - size.height, parent.frame.minY + M.edgeMargin)
        window.place(card: NSRect(x: tile.maxX - M.tileOverlapX, y: y, width: size.width, height: size.height))
    }

    private typealias M = FavoritePreviewCardView.Metrics

    // MARK: Actions

    private func openFromCard(_ url: URL) {
        guard let id = shownID else { return }
        dismiss(animated: false)
        host.open(id, url)
    }

    /// Gmail's sign-in opens in the favorite; Calendar asks macOS for calendar access.
    private func signIn() {
        guard let id = shownID, let kind = model.kind else { return }
        switch kind {
        case .calendar:
            fetcher.requestCalendarAccess { [weak self] in
                guard let self, self.shownID == id else { return }
                self.fetcher.invalidate(.calendar)
                self.refresh(.calendar, profile: self.host.profile(id), tab: id)
            }
        case .gmail(let account):
            fetcher.invalidate(kind)
            openFromCard(URL(string: "https://mail.google.com/mail/u/\(account)/")!)
        case .recents:
            break
        }
    }

    // MARK: Closing

    private func scheduleLeaveCheck() {
        leaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.checkLeave() }
        leaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.leaveDelay, execute: work)
    }

    private func checkLeave() {
        guard shownID != nil, hovered?.id != shownID else { return }
        if let window, window.frame.contains(NSEvent.mouseLocation) { return }
        dismiss()
    }

    private func observeResign(of parent: NSWindow) {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: parent, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(animated: false) }
        }
    }
}

// MARK: - Data

/// Fetches and caches each preview's content, by profile.
@MainActor
final class FavoritePreviewFetcher {
    static let shared = FavoritePreviewFetcher()

    private struct Entry {
        var content: FavoritePreviews.Content
        var fetched: Date
    }

    private var cache: [String: Entry] = [:]
    /// Fetches under way, with everyone waiting on each: a card that opens while the tray's
    /// prefetch is out gets its answer too.
    private var inFlight: [String: [(FavoritePreviews.Content) -> Void]] = [:]
    private let eventStore = EKEventStore()

    private func key(_ kind: FavoritePreviews.Kind, _ profile: String) -> String {
        // Calendar access is the Mac's, not a profile's.
        if case .calendar = kind { return "calendar" }
        return "\(profile)|\(kind)"
    }

    func cached(_ kind: FavoritePreviews.Kind, profile: String) -> FavoritePreviews.Content {
        cache[key(kind, profile)]?.content ?? .loading
    }

    func isStale(_ kind: FavoritePreviews.Kind, profile: String) -> Bool {
        if case .recents = kind { return true }  // From history: always current.
        guard let entry = cache[key(kind, profile)] else { return true }
        return Date().timeIntervalSince(entry.fetched) > FavoritePreviewController.Timing.staleAfter
    }

    func invalidate(_ kind: FavoritePreviews.Kind) {
        if case .calendar = kind { cache["calendar"] = nil; return }
        cache = cache.filter { !$0.key.hasSuffix("|\(kind)") }
    }

    func fetch(_ kind: FavoritePreviews.Kind, profile: String, engine: @escaping () -> WebEngine?, history: HistoryStore?,
               completion: @escaping (FavoritePreviews.Content) -> Void) {
        let key = key(kind, profile)
        if inFlight[key] != nil { return inFlight[key, default: []].append(completion) }
        inFlight[key] = [completion]
        let finish: (FavoritePreviews.Content) -> Void = { [weak self] content in
            guard let self else { return }
            self.cache[key] = Entry(content: content, fetched: Date())
            for waiting in self.inFlight.removeValue(forKey: key) ?? [] { waiting(content) }
        }
        switch kind {
        case .recents(let site):
            let entries = history.map { Array($0.history.entries.values) } ?? []
            finish(.items(FavoritePreviews.recentPages(entries, site: site)))
        case .calendar:
            finish(calendarContent())
        case .gmail(let account):
            guard let engine = engine() else { return finish(.signedOut) }
            GmailFeedReader.read(account: account, engine: engine) { messages in
                finish(messages.map { .items(FavoritePreviews.emails($0)) } ?? .signedOut)
            }
        }
    }

    // MARK: Calendar

    /// Kite reads events through macOS Calendar (the accounts in System Settings › Internet Accounts),
    /// where Arc signs in to Google itself ("Connect Calendar", its own OAuth client).
    private func calendarContent(now: Date = Date()) -> FavoritePreviews.Content {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return .signedOut }
        let end = Calendar.current.date(byAdding: .day, value: 2, to: Calendar.current.startOfDay(for: now)) ?? now
        let predicate = eventStore.predicateForEvents(withStart: now.addingTimeInterval(-6 * 3600), end: end, calendars: nil)
        let events = eventStore.events(matching: predicate).map { event in
            FavoritePreviews.Event(id: event.calendarItemIdentifier + "\(event.startDate.timeIntervalSince1970)",
                                   title: event.title ?? "", start: event.startDate, end: event.endDate,
                                   isAllDay: event.isAllDay, text: [event.location, event.notes].compactMap { $0 },
                                   url: event.url)
        }
        return .items(FavoritePreviews.events(events, now: now))
    }

    func requestCalendarAccess(_ done: @escaping () -> Void) {
        eventStore.requestFullAccessToEvents { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { done() } }
        }
    }
}

/// Reads Gmail's feed of unread inbox mail (`/mail/u/N/feed/atom`, what Arc's `GmailDataFetcher`
/// reads) with the profile's own Gmail sign-in, from a hidden page on mail.google.com. nil: not
/// signed in to that account.
@MainActor
enum GmailFeedReader {
    /// KITE_TEST_MAIL_ORIGIN (test profiles only) serves the feed from elsewhere, as for codes.
    static var origin: String {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil, let origin = environment["KITE_TEST_MAIL_ORIGIN"] { return origin }
        return "https://mail.google.com"
    }

    private static func script(account: Int) -> String {
        """
        (async () => {
          try {
            const r = await fetch('/mail/u/\(account)/feed/atom', { credentials: 'include', cache: 'no-store' });
            if (!r.ok || !/xml/.test(r.headers.get('content-type') || '')) return null;
            return await r.text();
          } catch { return null; }
        })()
        """
    }

    /// A reader page with no read for this long closes, and its renderer with it; the next read opens
    /// another. Reads come in bursts (Kite coming to the front, the pointer on the tray, a card).
    static let idleTimeout: TimeInterval = 120

    #if canImport(CEFBridge)
    /// One hidden page per profile, kept for the next read until it's idle.
    private final class Reader {
        let page: ChromiumPage
        var ready = false
        var waiting: [() -> Void] = []
        /// Reads started and not yet answered.
        var reading = 0
        var idleClose: DispatchWorkItem?
        init(page: ChromiumPage) { self.page = page }
    }

    private static var readers: [ObjectIdentifier: Reader] = [:]

    static func read(account: Int, engine: WebEngine, completion: @escaping ([VerificationCodes.Message]?) -> Void) {
        guard let reader = reader(for: engine) else { return completion(nil) }
        let key = ObjectIdentifier(engine)
        reader.idleClose?.cancel()
        reader.reading += 1
        var done = false
        func finish(_ messages: [VerificationCodes.Message]?) {
            guard !done else { return }
            done = true
            reader.reading -= 1
            if reader.reading == 0 { closeWhenIdle(reader, key: key) }
            completion(messages)
        }
        let run = {
            reader.page.evaluate(script(account: account), userGesture: false) { value, _ in
                finish((value as? String).map { VerificationCodes.parseGmailFeed(Data($0.utf8)) })
            }
        }
        if reader.ready { run() } else { reader.waiting.append(run) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(nil) }
    }

    private static func closeWhenIdle(_ reader: Reader, key: ObjectIdentifier) {
        reader.idleClose?.cancel()
        let work = DispatchWorkItem { [weak reader] in
            guard let reader, reader.reading == 0, readers[key] === reader else { return }
            readers[key] = nil
            reader.page.onEvent = nil
            reader.page.close()
        }
        reader.idleClose = work
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: work)
    }

    private static func reader(for engine: WebEngine) -> Reader? {
        let key = ObjectIdentifier(engine)
        if let reader = readers[key] { return reader }
        guard let url = URL(string: origin + "/mail/u/0/feed/atom"),
              let page = engine.makePage(url: url, restoring: nil) as? ChromiumPage else { return nil }
        let reader = Reader(page: page)
        readers[key] = reader
        page.onEvent = { [weak reader] event in
            guard let reader, case let .navigationState(isLoading, _, _) = event, !isLoading, !reader.ready else { return }
            reader.ready = true
            let waiting = reader.waiting
            reader.waiting = []
            waiting.forEach { $0() }
        }
        return reader
    }
    #else
    static func read(account: Int, engine: WebEngine, completion: @escaping ([VerificationCodes.Message]?) -> Void) {
        completion(nil)
    }
    #endif
}

// MARK: - Model

@MainActor
final class FavoritePreviewModel: ObservableObject {
    @Published var kind: FavoritePreviews.Kind?
    @Published var tab: BrowserTab?
    @Published var content: FavoritePreviews.Content = .loading
    var open: (URL) -> Void = { _ in }
    var signIn: () -> Void = {}

    func show(tab: BrowserTab, kind: FavoritePreviews.Kind, content: FavoritePreviews.Content) {
        self.tab = tab
        self.kind = kind
        self.content = content
    }
}

// MARK: - Window

final class FavoritePreviewWindow: NSPanel {
    private let hosting: NSHostingView<FavoritePreviewCardView>
    private let sizing = FavoritePreviewSizing()
    var onSizeChange: (() -> Void)?
    var onHover: ((Bool) -> Void)?
    weak var anchor: NSView?
    private var trackingArea: NSTrackingArea?

    init(model: FavoritePreviewModel) {
        hosting = NSHostingView(rootView: FavoritePreviewCardView(model: model, sizing: sizing))
        super.init(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        // The window's own shadow follows the card's rounded shape (the sidebar darkened from about
        // 12pt out around Arc's card).
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        hosting.sizingOptions = []
        contentView = hosting
        sizing.changed = { [weak self] in self?.contentSizeChanged() }
        setAccessibilityIdentifier("FavoritePreviewWindow")
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    var cardSize: CGSize { sizing.size == .zero ? CGSize(width: FavoritePreviewCardView.Metrics.width, height: 120) : sizing.size }

    func place(card: NSRect) {
        setFrame(card, display: true)
        invalidateShadow()
        updateTracking()
    }

    private func updateTracking() {
        guard let view = contentView else { return }
        if let trackingArea { view.removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: view.bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways], owner: self, userInfo: nil)
        view.addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }

    private func contentSizeChanged() {
        guard isVisible else { return }
        onSizeChange?()
    }

    func show() {
        if !isVisible || alphaValue < 1 {
            alphaValue = 0
            orderFront(nil)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = FavoritePreviewController.Timing.fade
                animator().alphaValue = 1
            }
        }
    }

    func close(animated: Bool) {
        guard animated, isVisible else {
            parent?.removeChildWindow(self)
            orderOut(nil)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = FavoritePreviewController.Timing.fade
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.alphaValue == 0 else { return }
                self.parent?.removeChildWindow(self)
                self.orderOut(nil)
            }
        }
    }
}

/// The card's measured size, handed to the window.
@MainActor
final class FavoritePreviewSizing {
    var size: CGSize = .zero
    var changed: () -> Void = {}

    func report(_ size: CGSize) {
        guard abs(self.size.height - size.height) > 0.5 || abs(self.size.width - size.width) > 0.5 else { return }
        self.size = size
        changed()
    }
}

// MARK: - Card

struct FavoritePreviewCardView: View {
    /// Measured on Arc's Gmail preview (1 Nov 2026, frames and pixel colours only) and read from its
    /// binary (PreviewView, PreviewBackgroundView, StandardPreviewConfiguration).
    enum Metrics {
        /// The card is 240 wide (66.5 to 306.5 for a tile ending at 70.25).
        static let width: CGFloat = 240
        /// Gmail's card was 272 tall with more mail below (3¼ rows); the binary caps content at 300.
        static let maxHeight: CGFloat = 272
        /// ARCUI's PopoverBackgroundView: 12pt corners (`0x4028…`, matches the measured corner).
        static let cornerRadius: CGFloat = 12
        /// The card's top-left sits on the tile's bottom-right corner, 3.75 left of its right edge and
        /// 4 above its bottom, wherever the pointer is on the tile.
        static let tileOverlapX: CGFloat = 3.75
        static let tileOverlapY: CGFloat = 4
        /// Text starts 12 in from the card's left edge, and ends 12 short of the scroller.
        static let padding: CGFloat = 12
        /// An email row is 84 tall with its 1pt divider (dividers 84 apart).
        static let emailRowHeight: CGFloat = 83
        /// The row under the pointer: white at 7% (`Color.opacity(0.07)`; measured #333332 over #1B1B19).
        static let rowHoverOpacity: Double = 0.07
        /// Sign-in and Join buttons: 14pt semibold.
        static let buttonFontSize: CGFloat = 14
        /// Keeps the card this far inside the window's bottom edge (Kite's).
        static let edgeMargin: CGFloat = 8
    }

    @ObservedObject var model: FavoritePreviewModel
    let sizing: FavoritePreviewSizing
    @State private var listHeight: CGFloat = 0

    var body: some View {
        card
            .frame(width: Metrics.width)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear
                    .onAppear { sizing.report(proxy.size) }
                    .onChange(of: proxy.size) { sizing.report(proxy.size) }
            })
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let kind = model.kind { content(kind, FavoritePreviews.configuration(for: kind)) }
        }
        .frame(maxHeight: Metrics.maxHeight, alignment: .top)
        .background(Color(nsColor: .favoritePreviewFill))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous))
        // Measured: a light 1pt line just inside the edge (#4E4E51 over the fill), a black hairline outside it.
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cornerRadius + 0.5, style: .continuous)
            .stroke(Color.black.opacity(0.9), lineWidth: 0.5)
            .padding(-0.25))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("FavoritePreviewCard")
    }

    @ViewBuilder
    private func content(_ kind: FavoritePreviews.Kind, _ configuration: FavoritePreviews.Configuration) -> some View {
        switch model.content {
        case .loading:
            ProgressView().controlSize(.small)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
        case .signedOut:
            VStack(spacing: 8) {
                Text(configuration.signedOutText ?? configuration.emptyText)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = configuration.signInTitle {
                    Button(action: model.signIn) {
                        Text(title)
                            .font(.system(size: Metrics.buttonFontSize, weight: .semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.1)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(14)
        case .items(let items) where items.isEmpty:
            Text(configuration.emptyText)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(14)
        case .items(let items):
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                        if i > 0 { Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1) }
                        FavoritePreviewRow(item: item, kind: kind, icon: model.tab?.faviconURL, open: model.open)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            // As tall as the list up to the card's cap, so a longer list scrolls inside the card
            // (sized to the whole list, the scroll view had nothing to scroll and the card clipped it).
            .frame(height: min(listHeight, Metrics.maxHeight))
        }
    }
}

extension NSColor {
    /// Arc's preview fill, measured #18181C (dark; Gabe's Arc spaces are dark, so the light fill is unmeasured).
    static let favoritePreviewFill = NSColor(srgbRed: 0x18 / 255, green: 0x18 / 255, blue: 0x1C / 255, alpha: 1)
}

private struct FavoritePreviewRow: View {
    let item: FavoritePreviews.Item
    let kind: FavoritePreviews.Kind
    /// The favorite's icon: recent pages are on the same site.
    let icon: URL?
    let open: (URL) -> Void
    @State private var hovering = false

    private typealias M = FavoritePreviewCardView.Metrics

    var body: some View {
        Button { if let url = item.url { open(url) } } label: {
            Group {
                if case .gmail = kind { email } else { line }
            }
            .padding(.horizontal, M.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(hovering ? M.rowHoverOpacity : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            if let join = item.joinURL {
                Button("Copy Join Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(join.absoluteString, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("FavoritePreviewRow")
    }

    /// Measured: the sender (bright) with the time at the right, the subject under it, then two lines
    /// of the message, about 16.5pt apart; the first line's glyphs start 13 below the row's top.
    private var email: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let date = item.date {
                    Text(Self.time(date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Text(item.subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.primary.opacity(0.75))
                .lineLimit(1)
            Text(item.detail ?? "")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(.top, 10)
        .frame(height: M.emailRowHeight, alignment: .top)
    }

    /// Events and recent pages. **[unverified]**: none of Gabe's favorites has these previews, so
    /// their rows follow the email row's type and padding.
    private var line: some View {
        HStack(spacing: 8) {
            if case .recents = kind { FaviconView(page: item.url, icon: icon, size: 16).frame(width: 16, height: 16) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if !item.subtitle.isEmpty {
                    Text(item.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if let join = item.joinURL {
                Button { open(join) } label: {
                    Text(Self.joinTitle(join))
                        .font(.system(size: M.buttonFontSize, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
    }

    /// "Join <name>" ("Button to join an event video call with a particular name"), else "Join Event".
    static func joinTitle(_ url: URL) -> String {
        let host = url.host()?.lowercased() ?? ""
        let name: String? = if host.contains("meet.google") { "Meet" }
            else if host.contains("zoom.us") { "Zoom" }
            else if host.contains("teams.microsoft") { "Teams" }
            else if host.contains("webex") { "Webex" }
            else { nil }
        return name.map { "Join " + $0 } ?? "Join Event"
    }

    static func time(_ date: Date, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
        } else {
            formatter.setLocalizedDateFormatFromTemplate("MMMd")
        }
        return formatter.string(from: date)
    }
}

import AppKit
import KiteCore
import Observation
import SwiftUI

/// sign_in's prompt, floating at the bottom centre of the page, so it never covers a site's nav bar or the password manager's inline menu.
///
/// Claude *driving* a tab has no banner: the sidebar shows it on the tab's row and on the Claude › session
/// folder holding it (with Stop), and the page gets Claude's border (`ClaudeControlBorder`).
struct ClaudeControlBanner: View {
    let automation: AutomationController
    let store: BrowserStore

    var body: some View {
        if let front = store.state.selectedTab?.id, let signIn = automation.signIns[front] {
            signInBanner(signIn, tab: front)
        }
    }

    /// sign_in: Claude waits while the user signs in. The password manager reopens its popup; Done says
    /// they're signed in (for pages Kite can't tell about); Cancel hands the tab back unsigned.
    private func signInBanner(_ request: SignInRequest, tab: UUID) -> some View {
        let accent = Color(red: 0.85, green: 0.47, blue: 0.34)
        return HStack(spacing: 10) {
            Image(systemName: "key.fill")
                .foregroundStyle(accent)
            Text("Claude is waiting for you to sign in to \(request.host)")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(request.reason.map { "Claude needs you signed in \($0)." } ?? "Claude needs you signed in.")
            if automation.canOpenPasswordManager {
                Button(automation.passwordManagerName) { automation.openPasswordManager() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
                    .help("Fill this login with \(automation.passwordManagerName) (⇧⌘X). Claude never sees the password.")
            }
            Button("Cancel") { automation.answerSignIn(tab, .cancelled) }
                .buttonStyle(.borderless)
                .font(.system(size: 12))
            Button {
                automation.answerSignIn(tab, .signedIn)
            } label: {
                Text("Done").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(accent)
            .controlSize(.small)
            .help("You're signed in: give the tab back to Claude")
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .padding(.vertical, 5)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(accent.opacity(0.6), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
        .frame(maxWidth: 560)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude is waiting for you to sign in")
    }
}

extension BrowserWindowController: AutomationHost {
    func automationPage(for tab: BrowserTab) -> WebPage {
        let page = pool.page(for: tab)
        // A tab that has never been shown has no size of its own yet; lay it out like the
        // visible page area, so Claude reads and captures what the user would see.
        if page.view.superview == nil, contentFrame.bounds.width > 0, page.view.frame.size != contentFrame.bounds.size {
            page.view.frame = CGRect(origin: .zero, size: contentFrame.bounds.size)
        }
        return page
    }

    /// Every normal window's pages, so a handoff step shown in a linked window is looked at there too.
    var livePages: [UUID: WebPage] { pool.linkedLivePages }

    func closeAutomatedTab(_ id: UUID) {
        close(tab: id)
    }

    /// Pins the banner just above the sidebar's Claude button, or to the bottom centre of the page when
    /// the sidebar (and so the button) isn't showing.
    func installAutomationBanner(_ automation: AutomationController) {
        pool.onPageCreated = { [weak automation] id, page in automation?.pageCreated(id, page) }
        pool.onLoadFinished = { [weak automation] id in automation?.pageFinishedLoading(id) }
        pool.onTabOpened = { [weak automation] child, opener in automation?.tabOpened(child, by: opener) }
        claudeButton.automation = automation
        installClaudeControlBorder(automation)
        installClaudeHandoffCard(automation)
        guard let root = window?.contentView else { return }
        // A strip across the window, rather than a view sized to the banner: the banner's size changes
        // with Claude's state, and an intrinsically sized host stayed 0×0, so its buttons never got clicks.
        let host = BannerHostingView(rootView: ClaudeBannerStrip(
            banner: ClaudeControlBanner(automation: automation, store: store),
            placement: claudeBannerPlacement
        ))
        host.sizingOptions = []
        host.safeAreaRegions = []
        // In the window only while sign_in's pill shows: an empty host there still re-renders on every store change.
        let strip = DetachingContainer(host: host)
        strip.passesClicks = true
        strip.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(strip)
        let bottom = strip.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        claudeBannerBottom = bottom
        NSLayoutConstraint.activate([
            strip.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            strip.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            strip.heightAnchor.constraint(equalToConstant: 28),
            bottom,
        ])
        watchSignInBanner(strip, automation)
        claudeButton.onFrameChange = { [weak self] in self?.schedulePlaceClaudeBanner() }
        for view in [sidebarHostView, contentFrame] as [NSView] {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePlaceClaudeBanner() }
            }
        }
        schedulePlaceClaudeBanner()
    }

    private func watchSignInBanner(_ strip: DetachingContainer, _ automation: AutomationController) {
        withObservationTracking {
            strip.isHidden = store.state.selectedTab.map { automation.signIns[$0.id] == nil } ?? true
        } onChange: { [weak self, weak strip, weak automation] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let strip, let automation else { return }
                    self.watchSignInBanner(strip, automation)
                }
            }
        }
    }

    /// Frames change mid-layout; move the pill once that pass is over, not inside it.
    private func schedulePlaceClaudeBanner() {
        guard !claudeBannerPlacement.pending else { return }
        claudeBannerPlacement.pending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.claudeBannerPlacement.pending = false
                self.placeClaudeBanner()
            }
        }
    }

    /// Above the Claude button when the docked sidebar shows it; otherwise 10pt up from the page's bottom, centred.
    private func placeClaudeBanner() {
        guard let root = window?.contentView, let bottom = claudeBannerBottom else { return }
        // Distance from the root's bottom edge to a rect's top (or bottom) edge, whatever the root's flip.
        func lift(_ r: CGRect, top: Bool) -> CGFloat {
            root.isFlipped ? root.bounds.height - (top ? r.minY : r.maxY) : (top ? r.maxY : r.minY)
        }
        if isSidebarDocked, let button = claudeButton.frame, !button.isEmpty {
            let r = sidebarHostView.convert(button, to: root)
            if root.bounds.contains(CGPoint(x: r.midX, y: r.midY)) {
                bottom.constant = -(lift(r, top: true) + 6)
                claudeBannerPlacement.anchorX = r.midX
                return
            }
        }
        let page = contentFrame.convert(contentFrame.bounds, to: root)
        bottom.constant = -(lift(page, top: false) + 10)
        claudeBannerPlacement.anchorX = page.midX
    }
}

extension BrowserWindowController {
    /// Claude's orange border around the page while Claude drives the tab in front, so the tab says so
    /// with the sidebar hidden too. Above the pages, and never takes a click.
    fileprivate func installClaudeControlBorder(_ automation: AutomationController) {
        let border = ClaudeControlBorderView()
        border.frame = contentFrame.bounds
        border.autoresizingMask = [.width, .height]
        contentFrame.addSubview(border, positioned: .above, relativeTo: nil)
        watchClaudeControlBorder(border, automation)
    }

    private func watchClaudeControlBorder(_ border: ClaudeControlBorderView, _ automation: AutomationController) {
        withObservationTracking {
            border.isOn = store.state.selectedTab.map { automation.controlledTabIDs.contains($0.id) } ?? false
        } onChange: { [weak self, weak border, weak automation] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, let border, let automation else { return }
                    self.watchClaudeControlBorder(border, automation)
                }
            }
        }
    }
}

/// The page's edge in Claude's orange while Claude drives the selected tab (like Claude in Chrome's): one
/// layer's border, inside the page's rounded corners, fading in and out over 0.2s.
final class ClaudeControlBorderView: NSView {
    static let lineWidth: CGFloat = 2

    var isOn = false {
        didSet {
            guard isOn != oldValue, let layer else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = layer.presentation()?.opacity ?? layer.opacity
            fade.duration = 0.2
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.opacity = isOn ? 1 : 0
            layer.add(fade, forKey: "opacity")
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = ArcMetrics.Content.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.borderWidth = Self.lineWidth
        layer?.borderColor = NSColor(Color.claude).withAlphaComponent(0.85).cgColor
        layer?.opacity = 0
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func isAccessibilityElement() -> Bool { false }
}

/// Where the banner's centre goes across the window, in the window's points from its left edge.
@MainActor
@Observable
final class ClaudeBannerPlacement {
    var anchorX: CGFloat = 0
    @ObservationIgnored var pending = false
}

/// Centres the banner on `placement.anchorX`, kept 8pt inside the window's edges.
private struct ClaudeBannerStrip: View {
    let banner: ClaudeControlBanner
    let placement: ClaudeBannerPlacement
    @State private var stripWidth: CGFloat = 0
    @State private var bannerWidth: CGFloat = 0

    var body: some View {
        banner
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { bannerWidth = $0 }
            .padding(.leading, leading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { stripWidth = $0 }
    }

    private var leading: CGFloat {
        let margin: CGFloat = 8
        return max(margin, min(placement.anchorX - bannerWidth / 2, stripWidth - bannerWidth - margin))
    }
}

/// Lets clicks through to the page everywhere except on the banner's controls.
final class BannerHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

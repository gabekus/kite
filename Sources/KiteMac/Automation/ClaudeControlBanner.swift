import AppKit
import KiteCore
import Observation
import SwiftUI

/// Floats just above the sidebar's Claude button while Claude is driving a tab, with Stop (or at the bottom
/// of the page when the sidebar is hidden), so it never covers a site's nav bar or the password manager's
/// inline menu on a login form.
struct ClaudeControlBanner: View {
    let automation: AutomationController
    let store: BrowserStore

    var body: some View {
        let controlled = automation.controlledTabs
        let front = store.state.selectedTab?.id
        if let front, let signIn = automation.signIns[front] {
            signInBanner(signIn, tab: front)
        } else if !controlled.isEmpty {
            let frontControlled = front.map { controlled[$0] != nil } ?? false
            let latest = controlled.max { $0.value.lastActive < $1.value.lastActive }?.key
            HStack(spacing: 10) {
                Image(systemName: "sparkle")
                    .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                Text(message(controlled: controlled, frontControlled: frontControlled, latest: latest))
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !frontControlled, let latest {
                    Button("Show") { store.mutate { $0.select(tab: latest) } }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
                Button {
                    // Stop the tab in front if Claude is on it, otherwise every tab Claude holds.
                    automation.stop(tabs: frontControlled ? [front!] : Set(controlled.keys))
                } label: {
                    Text("Stop").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .controlSize(.small)
                .help("Take control back from Claude")
            }
            .padding(.leading, 12)
            .padding(.trailing, 6)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color(red: 0.85, green: 0.47, blue: 0.34).opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
            .frame(maxWidth: 520)
            .fixedSize()
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Claude is controlling the browser")
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

    private func message(controlled: [UUID: AutomationController.ControlledTab], frontControlled: Bool, latest: UUID?) -> String {
        if frontControlled { return controlled.count == 1 ? "Claude is controlling this tab" : "Claude is controlling this tab and \(controlled.count - 1) more" }
        if controlled.count > 1 { return "Claude is controlling \(controlled.count) tabs" }
        let title = latest.flatMap { store.state.tab($0)?.displayTitle } ?? "a tab"
        return "Claude is controlling “\(title.count > 40 ? title.prefix(39) + "…" : Substring(title))”"
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

    var livePages: [UUID: WebPage] { pool.livePages }

    func closeAutomatedTab(_ id: UUID) {
        close(tab: id)
    }

    /// Pins the banner just above the sidebar's Claude button, or to the bottom centre of the page when
    /// the sidebar (and so the button) isn't showing.
    func installAutomationBanner(_ automation: AutomationController) {
        pool.onPageCreated = { [weak automation] id, page in automation?.pageCreated(id, page) }
        pool.onLoadFinished = { [weak automation] id in automation?.pageFinishedLoading(id) }
        guard let root = window?.contentView else { return }
        // A strip across the window, rather than a view sized to the banner: the banner's size changes
        // with Claude's state, and an intrinsically sized host stayed 0×0, so its buttons never got clicks.
        let host = BannerHostingView(rootView: ClaudeBannerStrip(
            banner: ClaudeControlBanner(automation: automation, store: store),
            placement: claudeBannerPlacement
        ))
        host.sizingOptions = []
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        let bottom = host.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        claudeBannerBottom = bottom
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            host.heightAnchor.constraint(equalToConstant: 28),
            bottom,
        ])
        claudeButton.onFrameChange = { [weak self] in self?.schedulePlaceClaudeBanner() }
        for view in [sidebarHostView, contentFrame] as [NSView] {
            view.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: view, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.schedulePlaceClaudeBanner() }
            }
        }
        schedulePlaceClaudeBanner()
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
private final class BannerHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

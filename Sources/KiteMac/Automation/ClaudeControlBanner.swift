import AppKit
import KiteCore
import SwiftUI

/// Floats over the top of the page while Claude is driving a tab, with Stop.
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

    /// Pins the banner to the top of the page area, above the web view.
    func installAutomationBanner(_ automation: AutomationController) {
        pool.onPageCreated = { [weak automation] id, page in automation?.pageCreated(id, page) }
        pool.onLoadFinished = { [weak automation] id in automation?.pageFinishedLoading(id) }
        guard let root = window?.contentView else { return }
        // A strip across the page area, rather than a view sized to the banner: the banner's size changes
        // with Claude's state, and an intrinsically sized host stayed 0×0, so its buttons never got clicks.
        let host = BannerHostingView(rootView: ClaudeControlBanner(automation: automation, store: store)
            .frame(maxWidth: .infinity, alignment: .top))
        host.sizingOptions = []
        // The strip reaches under the titlebar; its safe area would push the banner down.
        host.safeAreaRegions = []
        host.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: contentFrame.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentFrame.trailingAnchor),
            host.topAnchor.constraint(equalTo: contentFrame.topAnchor, constant: 10),
            host.heightAnchor.constraint(equalToConstant: 28),
        ])
    }
}

/// Lets clicks through to the page everywhere except on the banner's controls.
private final class BannerHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

import AppKit
import KiteCore
import Observation
import SwiftUI

/// What Site Controls shows for the current page, read from the window when it opens and
/// again after every change. Nil rows are ones this engine or build can't offer.
@MainActor
@Observable
final class SiteControlsModel {
    struct Actions {
        var copyURL: () -> Void
        var share: (NSView) -> Void
        var toggleAdblock: () -> Void
        var clearCache: () -> Void
        var clearCookies: () -> Void
        var setPermission: (SitePermission, SitePermissionValue) -> Void
        var removeMailHandler: () -> Void
        var toggleDeveloperMode: () -> Void
        /// "All Site Settings…" and the Settings header: the site's settings page in a new tab.
        var openSiteSettings: () -> Void
        /// New Boost (the action button and the footer item): a Boost for this site, in its editor.
        var newBoost: () -> Void
        /// A Boost row's edit button: that Boost in its editor.
        var editBoost: (UUID) -> Void
        var setBoostEnabled: (UUID, Bool) -> Void
        /// The Boosts header and "Manage Boosts…": Window › View Boosts….
        var manageBoosts: () -> Void
    }

    let url: URL
    var blocksAds: Bool?
    /// True while this site is the default mail app (MailHandlers); nil hides the row.
    var isMailHandler: Bool?
    /// The site's Developer Mode switch (View › Developer, ⌃D).
    var isInDeveloperMode = false
    /// Nil on WebKit, which keeps no per-site permissions Kite can read.
    var permissions: [SitePermission: SitePermissionValue]?
    /// This site's Boosts; nil where Boosts can't run (incognito, or a page with no domain).
    var boosts: [Boost]?
    @ObservationIgnored var actions: Actions
    @ObservationIgnored var read: (SiteControlsModel) -> Void
    @ObservationIgnored var dismiss: () -> Void = {}

    init(url: URL, actions: Actions, read: @escaping (SiteControlsModel) -> Void) {
        self.url = url
        self.actions = actions
        self.read = read
        read(self)
    }

    func refresh() { read(self) }

    /// Runs a change, then re-reads the page so the rows show it.
    func perform(_ change: () -> Void) {
        change()
        refresh()
    }
}

/// Arc 1.169's Site Control Center, from its binary and the masked probe (docs/arc-visual-spec.md):
/// a 262pt popover; a row of 48.75×32.75 action buttons; a "Settings" section of 208×33 rows
/// (icon, title, and an On/Off or Allowed/Blocked subtitle; a click flips it) on a 43pt pitch;
/// and a footer with the 82×32 security button on the left and a 32×32 "…" menu (Clear Cache,
/// Clear Cookies, Manage Boosts… / New Boost…, All Site Settings…) on the right. Between the
/// actions and Settings, the Boosts section lists the site's Boosts (Enabled / Disabled). Kite
/// has no capture buttons or extensions section here.
struct SiteControlsView: View {
    let model: SiteControlsModel

    enum Metrics {
        static let popoverWidth: CGFloat = 262
        /// The hosting view sits 13pt inside the popover's frame; sections another 10pt in.
        static let popoverInset: CGFloat = 13
        static let inset: CGFloat = 10
        static var width: CGFloat { popoverWidth - 2 * popoverInset }
        static let actionSize = CGSize(width: 48.75, height: 32.75)
        static let actionPitch: CGFloat = 56
        static let headerHeight: CGFloat = 17
        static let sectionGap: CGFloat = 9.65
        static let headerToRows: CGFloat = 10
        static let rowSize = CGSize(width: 208, height: 33)
        static let rowPitch: CGFloat = 43
        static let rowsToFooter: CGFloat = 26
        static let securitySize = CGSize(width: 82, height: 32)
        static let menuSize: CGFloat = 32
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Metrics.actionPitch - Metrics.actionSize.width) {
                ActionButton(symbol: "link", help: "Copy URL") { _ in model.actions.copyURL() }
                ActionButton(symbol: "square.and.arrow.up", help: "Share") { view in model.actions.share(view) }
                if model.boosts != nil {
                    ActionButton(symbol: "wand.and.stars", help: SiteControls.newBoostTitle) { _ in
                        model.dismiss(); model.actions.newBoost()
                    }
                }
            }
            .padding(.bottom, Metrics.sectionGap)

            if let boosts = model.boosts, !boosts.isEmpty {
                ControlsSectionHeader(title: SiteControls.boostsTitle, hoverText: SiteControls.boostsHoverText,
                              hint: SiteControls.manageBoostsMenuTitle) {
                    model.dismiss(); model.actions.manageBoosts()
                }
                .padding(.bottom, Metrics.headerToRows)
                VStack(alignment: .leading, spacing: Metrics.rowPitch - Metrics.rowSize.height) {
                    ForEach(boosts) { boost in
                        SiteBoostRow(boost: boost) {
                            model.perform { model.actions.setBoostEnabled(boost.id, !boost.isEnabled) }
                        } edit: {
                            model.dismiss(); model.actions.editBoost(boost.id)
                        }
                    }
                }
                .padding(.leading, (Metrics.width - 2 * Metrics.inset - Metrics.rowSize.width) / 2)
                .padding(.bottom, Metrics.sectionGap)
            }

            ControlsSectionHeader(title: SiteControls.settingsTitle, hoverText: SiteControls.settingsHoverText,
                          hint: SiteControls.allSiteSettingsTitle) {
                model.dismiss(); model.actions.openSiteSettings()
            }
                .padding(.bottom, Metrics.headerToRows)

            VStack(alignment: .leading, spacing: Metrics.rowPitch - Metrics.rowSize.height) {
                if let blocksAds = model.blocksAds {
                    SettingRow(symbol: "shield.fill", title: SiteControls.adblockTitle, subtitle: SiteControls.onOff(blocksAds),
                               isOn: blocksAds) { model.perform(model.actions.toggleAdblock) }
                }
                SettingRow(symbol: "hammer.fill", title: SiteControls.developerModeTitle,
                           subtitle: SiteControls.onOff(model.isInDeveloperMode),
                           isOn: model.isInDeveloperMode) { model.perform(model.actions.toggleDeveloperMode) }
                if model.isMailHandler == true {
                    SettingRow(symbol: "envelope.fill", title: "Default Mail App", subtitle: SiteControls.onOff(true),
                               isOn: true) { model.perform(model.actions.removeMailHandler) }
                }
                if let permissions = model.permissions {
                    ForEach(SitePermission.allCases, id: \.self) { permission in
                        let value = permissions[permission] ?? .ask
                        SettingRow(symbol: permission.symbol, title: permission.title, subtitle: value.subtitle,
                                   isOn: value == .allow) {
                            model.perform { model.actions.setPermission(permission, value.toggled) }
                        }
                        .contextMenu {
                            Button("Allow") { model.perform { model.actions.setPermission(permission, .allow) } }
                            Button("Block") { model.perform { model.actions.setPermission(permission, .block) } }
                            Button("Ask (Default)") { model.perform { model.actions.setPermission(permission, .ask) } }
                        }
                    }
                }
                if model.permissions == nil {
                    Text("Camera, microphone, location and notification permissions need the Chromium engine.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: Metrics.rowSize.width, alignment: .leading)
                }
            }
            .padding(.leading, (Metrics.width - 2 * Metrics.inset - Metrics.rowSize.width) / 2)

            HStack(spacing: 0) {
                SecurityLabel(title: SiteControls.securityTitle(for: model.url) ?? "")
                Spacer()
                FooterMenu(model: model)
            }
            .padding(.top, Metrics.rowsToFooter)
        }
        .padding(.horizontal, Metrics.inset)
        .padding(.vertical, Metrics.inset)
        .frame(width: Metrics.width, alignment: .leading)
    }
}

private struct ActionButton: View {
    let symbol: String
    let help: String
    let action: (NSView) -> Void
    @State private var anchor: NSView?
    @State private var hovering = false

    var body: some View {
        Button { if let anchor { action(anchor) } } label: {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: SiteControlsView.Metrics.actionSize.width, height: SiteControlsView.Metrics.actionSize.height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.1 : 0.05)))
                .background(AnchorView(view: $anchor))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

private struct SettingRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let isOn: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.08)))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 4)
            .frame(width: SiteControlsView.Metrics.rowSize.width, height: SiteControlsView.Metrics.rowSize.height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(subtitle)
    }
}

/// A section's header: the title, and a word shown at its right on hover. Arc's Settings
/// header shows "More" and opens the site's settings (`onSiteSettingsTitleClick`); its Boosts
/// header shows "Manage" and manages Boosts (`onManageBoostsClick`).
private struct ControlsSectionHeader: View {
    let title: String
    let hoverText: String
    let hint: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Text(title)
                Spacer(minLength: 0)
                Text(hoverText).opacity(hovering ? 1 : 0)
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: SiteControlsView.Metrics.width - 2 * SiteControlsView.Metrics.inset,
                   height: SiteControlsView.Metrics.headerHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(title)
        .accessibilityHint(hint)
    }
}

/// A row of the Boosts section (Arc's Boost row: `onToggleClick`, `onEditClick`, hovered state):
/// the Boost's name, subtitled Enabled / Disabled; a click turns it on or off, and the pencil
/// shown on hover opens it in the editor.
private struct SiteBoostRow: View {
    let boost: Boost
    let toggle: () -> Void
    let edit: () -> Void
    @State private var hovering = false

    var body: some View {
        let subtitle = SiteControls.boostSubtitle(boost.isEnabled)
        ZStack(alignment: .trailing) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(boost.isEnabled ? Color.accentColor : Color.secondary)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.primary.opacity(0.08)))
                    VStack(alignment: .leading, spacing: 0) {
                        Text(boost.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 4)
                .padding(.trailing, 32)
                .frame(width: SiteControlsView.Metrics.rowSize.width, height: SiteControlsView.Metrics.rowSize.height)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(boost.name)
            .accessibilityValue(subtitle)

            Button(action: edit) {
                Image(systemName: "pencil")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .padding(.trailing, 4)
            .help("Edit Boost")
            .accessibilityLabel("Edit Boost")
        }
        .frame(width: SiteControlsView.Metrics.rowSize.width, height: SiteControlsView.Metrics.rowSize.height)
        .onHover { hovering = $0 }
        .help(boost.name)
    }
}

/// Arc's footer button: "Secure" with a lock, "Insecure" with a struck-through one.
private struct SecurityLabel: View {
    let title: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: title == "Secure" ? "lock.fill" : "lock.slash.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(title).font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .frame(width: SiteControlsView.Metrics.securitySize.width, height: SiteControlsView.Metrics.securitySize.height)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .combine)
    }
}

/// The footer's "…": Arc's menu has Clear Cache, Clear Cookies, Manage Boosts…, New Boost… (only
/// some of the time: `includeBoostsInContextMenu`), the extensions items, and All Site Settings…
/// last. Kite has all but the extensions items; Clear Cache and Clear Cookies are its
/// clear-and-refresh, as in the View menu.
private struct FooterMenu: View {
    let model: SiteControlsModel

    var body: some View {
        Menu {
            Button("Clear Cache") { model.dismiss(); model.actions.clearCache() }
            Button("Clear Cookies") { model.dismiss(); model.actions.clearCookies() }
            if SiteControls.includesBoostsInMenu(siteBoostCount: model.boosts?.count ?? 0,
                                                 boostsAvailable: model.boosts != nil) {
                Button(SiteControls.manageBoostsMenuTitle) { model.dismiss(); model.actions.manageBoosts() }
                Button(SiteControls.newBoostMenuTitle) { model.dismiss(); model.actions.newBoost() }
            }
            Button(SiteControls.allSiteSettingsTitle) { model.dismiss(); model.actions.openSiteSettings() }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: SiteControlsView.Metrics.menuSize, height: SiteControlsView.Metrics.menuSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: SiteControlsView.Metrics.menuSize, height: SiteControlsView.Metrics.menuSize)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
        .help("More")
        .accessibilityLabel("More")
    }
}

/// The popover itself, hanging from the button that opened it. One per app: opening it from
/// another window closes the first, and clicking its button again closes it.
@MainActor
enum SiteControlsPopover {
    private static weak var shown: NSPopover?
    private static weak var shownAnchor: NSView?
    /// A transient popover closes on the mouse-down that lands on its own button, before the
    /// button acts; that click mustn't open it again.
    private static var closed: (anchor: ObjectIdentifier, at: Date)?
    private static var observer: NSObjectProtocol?

    /// Observable, so the address field keeps its hover button while the popover hangs from it.
    @Observable final class Presence { var isShown = false }
    static let presence = Presence()
    static var isShown: Bool { presence.isShown }

    /// `overlap` raises the popover over the button's bottom edge (Arc's toolbar popover starts
    /// 4pt above the bar's bottom). The popover stays inside the window: Arc's toolbar popover
    /// ends at the window's right edge rather than centring on its button.
    static func toggle(_ model: @autoclosure () -> SiteControlsModel?, from view: NSView, overlap: CGFloat = 0) {
        if let shown, shown.isShown {
            let sameButton = shownAnchor === view
            shown.close()
            if sameButton { return }
        } else if let closed, closed.anchor == ObjectIdentifier(view), Date().timeIntervalSince(closed.at) < 0.3 {
            return
        }
        guard let model = model() else { return NSSound.beep() }
        let popover = NSPopover()
        popover.behavior = .transient
        let host = NSHostingController(rootView: SiteControlsView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        model.dismiss = { [weak popover] in popover?.close() }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        let anchor = ObjectIdentifier(view)
        observer = NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { _ in
            MainActor.assumeIsolated {
                closed = (anchor, Date())
                presence.isShown = false
            }
        }
        var rect = view.bounds
        if overlap > 0 {
            rect.size.height -= overlap
            if !view.isFlipped { rect.origin.y += overlap }
        }
        // Positioned against the window's content view, so the popover can sit off-centre
        // from a button near the window's right edge.
        var positioning = view
        if let content = view.window?.contentView {
            rect = view.convert(rect, to: content)
            let half = SiteControlsView.Metrics.popoverWidth / 2
            if rect.midX + half > content.bounds.maxX {
                rect.origin.x = content.bounds.maxX - half - rect.width / 2
            }
            positioning = content
        }
        popover.show(relativeTo: rect, of: positioning, preferredEdge: positioning.isFlipped ? .maxY : .minY)
        shown = popover
        shownAnchor = view
        presence.isShown = true
    }
}

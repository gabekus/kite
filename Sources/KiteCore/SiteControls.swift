import Foundation

/// Arc's Site Control Center (the popover from the URL field's sliders button): the words
/// and states it shows, kept engine-free so they can be tested. Titles and subtitles are
/// Arc 1.169's own strings, read from its binary (see docs/arc-visual-spec.md, "Site
/// Control Center").
public enum SiteControls {
    /// The footer's security button: "Secure" on https, "Insecure" on http, nothing for
    /// pages that aren't websites (Kite's own pages, files, about:blank).
    public static func securityTitle(for url: URL?) -> String? {
        switch url?.scheme?.lowercased() {
        case "https": "Secure"
        case "http": "Insecure"
        default: nil
        }
    }

    /// Whether the popover has anything to say about this page: it needs a site.
    public static func applies(to url: URL?) -> Bool {
        securityTitle(for: url) != nil && url?.host()?.isEmpty == false
    }

    /// The origin a per-site setting is stored under (`https://host[:port]`).
    public static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The ad blocker's row. Arc: "Block Ads & Trackers", subtitled On / Off.
    public static let adblockTitle = "Block Ads & Trackers"
    public static func onOff(_ on: Bool) -> String { on ? "On" : "Off" }

    /// The per-site Developer Mode row (`BrowserState.developerModeEnabledForHosts`). Arc:
    /// "Developer Mode", subtitled On / Off.
    public static let developerModeTitle = "Developer Mode"

    /// The Settings section's header, and the word Arc shows on it on hover; clicking it
    /// opens the site's settings, like the footer menu's "All Site Settings…".
    public static let settingsTitle = "Settings"
    public static let settingsHoverText = "More"
    public static let allSiteSettingsTitle = "All Site Settings…"

    // MARK: Boosts (Arc's `SiteControlCenterBoostsView`, the New Boost action button and footer items)

    /// The Boosts section's header, and the word shown on it on hover; clicking it manages Boosts.
    public static let boostsTitle = "Boosts"
    public static let boostsHoverText = "Manage"
    /// A Boost row's subtitle.
    public static func boostSubtitle(_ enabled: Bool) -> String { enabled ? "Enabled" : "Disabled" }
    /// The New Boost action button's tooltip.
    public static let newBoostTitle = "New Boost"
    /// The footer menu's Boost items.
    public static let manageBoostsMenuTitle = "Manage Boosts…"
    public static let newBoostMenuTitle = "New Boost…"

    /// Arc's footer menu shows Manage Boosts… and New Boost… only some of the time
    /// (`includeBoostsInContextMenu`). Kite shows them when the site has no Boosts section to
    /// offer its own "Manage" header (inferred: the flag's source wasn't traced), and never where
    /// Boosts can't run.
    public static func includesBoostsInMenu(siteBoostCount: Int, boostsAvailable: Bool) -> Bool {
        boostsAvailable && siteBoostCount == 0
    }

    // MARK: Action row (Arc's `SiteControlCenterActionButton`, g127)

    /// The row of buttons at the top, in Arc's order. Arc 1.171 builds it at 0x101388a14:
    /// Share; New Boost where Boosts are on (`boostsEnabled`), else Copy URL; then, while capture
    /// is available (`captureEnabled`), Capture and Capture Full Page, which becomes Capture in
    /// Portrait Mode while ⌥ is held (the view's `_optionKeyDown`).
    public static func actions(boostsEnabled: Bool, captureEnabled: Bool, optionKeyDown: Bool) -> [SiteControlsAction] {
        var actions: [SiteControlsAction] = [.share, boostsEnabled ? .newBoost : .copyURL]
        if captureEnabled { actions += [.capture, optionKeyDown ? .capturePortraitMode : .captureFullPage] }
        return actions
    }

    // MARK: Extensions (Arc's `SiteControlCenterExtensionsView`, g126)

    /// The Extensions section's header, and the word shown on it on hover; clicking it manages extensions.
    public static let extensionsTitle = "Extensions"
    public static let extensionsHoverText = "Manage"
    /// The plus tile after the extensions: its tooltip and accessibility label.
    public static let addExtensionTitle = "Add Extension"
    /// A tile's pin button tooltip.
    public static func pinButtonTitle(isPinned: Bool) -> String { isPinned ? "Unpin" : "Pin" }
    /// The footer menu's extension items, after the Boost items and before All Site Settings….
    public static let manageExtensionsMenuTitle = "Manage Extensions\u{2026}"
    public static let addExtensionMenuTitle = "Add Extension\u{2026}"

    /// Arc's tile shows its pin button while the extension is pinned, or while the pointer is over it.
    public static func showsPinButton(isPinned: Bool, isHovered: Bool) -> Bool { isPinned || isHovered }
}

/// One of the action row's buttons. Raw values are Arc's case order.
public enum SiteControlsAction: Int, CaseIterable, Sendable {
    case share
    case copyURL
    case newBoost
    case capture
    case captureFullPage
    case capturePortraitMode

    /// The button's tooltip and accessibility label: Arc's tooltip strings (arc-strings 73694–73699,
    /// short ones decoded at 0x101373f58).
    public var title: String {
        switch self {
        case .share: "Share"
        case .copyURL: "Copy URL"
        case .newBoost: SiteControls.newBoostTitle
        case .capture: "Capture a portion of this page"
        case .captureFullPage: "Capture the full page"
        case .capturePortraitMode: "Capture in Portrait Mode"
        }
    }

    /// Whether the button closes the popover before it acts (everything but Share, whose
    /// picker hangs from the button, and Copy URL, which only shows a toast).
    public var dismissesPopover: Bool {
        switch self {
        case .share, .copyURL: false
        case .newBoost, .capture, .captureFullPage, .capturePortraitMode: true
        }
    }
}

/// A permission the site can be given, as Chromium stores it per site (content settings).
public enum SitePermission: String, CaseIterable, Sendable {
    case camera
    case microphone
    case location
    case notifications

    /// Arc's own names for these (its permission-type display names), capitalised as a row title.
    public var title: String {
        switch self {
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .location: "Location"
        case .notifications: "Notifications"
        }
    }

    public var symbol: String {
        switch self {
        case .camera: "video.fill"
        case .microphone: "mic.fill"
        case .location: "location.fill"
        case .notifications: "bell.fill"
        }
    }
}

/// A permission's stored value. Chromium's "default" and "ask" both mean the site has to ask.
public enum SitePermissionValue: Sendable, Equatable {
    case ask
    case allow
    case block

    /// Arc's subtitles: "Allowed" and "Blocked". Arc has no subtitle for a setting that's
    /// still at "ask"; Kite says "Ask".
    public var subtitle: String {
        switch self {
        case .ask: "Ask"
        case .allow: "Allowed"
        case .block: "Blocked"
        }
    }

    /// Clicking the row: allowed sites get blocked, anything else gets allowed.
    public var toggled: SitePermissionValue {
        self == .allow ? .block : .allow
    }
}

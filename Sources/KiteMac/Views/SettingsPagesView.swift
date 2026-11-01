import AppKit
import KiteCore
import SwiftUI

/// What Kite's settings pages (kite://settings/…) read and change: the tab's own profile, as
/// Chromium's settings pages work on their tab's profile. Chromium prefs and content settings go
/// through the tab's (blank) engine page; Kite's own history and downloads list are Kite's.
@MainActor
final class ProfileDataControls {
    private let page: () -> WebPage?
    let engine: WebEngine
    private let history: HistoryStore?

    init(page: @escaping () -> WebPage?, engine: WebEngine, history: HistoryStore?) {
        self.page = page
        self.engine = engine
        self.history = history
    }

    /// The Delete browsing data checkboxes this engine can act on.
    var available: [BrowsingDataType] { engine.deletableBrowsingData }

    /// Chromium keeps per-site permissions and the dialog's choices as profile prefs; WebKit neither.
    var keepsPreferences: Bool { available.contains(.siteSettings) }

    /// False while the tab's Chromium browser is still being made (its prefs read as nil).
    var isReady: Bool { !keepsPreferences || page()?.preference(BrowsingDataPeriod.preference) != nil }

    // MARK: Delete browsing data

    /// The checkboxes as last used in this profile (Chromium's `browser.clear_data.*` prefs).
    func checkedTypes() -> Set<BrowsingDataType> {
        Set(available.filter { type in
            (page()?.preference(type.preference) as? NSNumber)?.boolValue ?? type.isCheckedByDefault
        })
    }

    func period() -> BrowsingDataPeriod {
        (page()?.preference(BrowsingDataPeriod.preference) as? NSNumber).flatMap { BrowsingDataPeriod(rawValue: $0.intValue) }
            ?? .default
    }

    /// Chromium saves the choices when Delete is pressed, not on each click.
    func remember(_ checked: Set<BrowsingDataType>, _ period: BrowsingDataPeriod) {
        guard let page = page(), keepsPreferences else { return }
        for type in available { page.setPreference(type.preference, NSNumber(value: checked.contains(type))) }
        page.setPreference(BrowsingDataPeriod.preference, NSNumber(value: period.rawValue))
    }

    /// Only after the dialog's Delete: never call this without the user's say-so.
    func delete(_ types: Set<BrowsingDataType>, period: BrowsingDataPeriod, completion: @escaping () -> Void) {
        let since = period.since(Date())
        if types.contains(.history) { history?.removeVisits(since: since) }
        if types.contains(.downloads) { DownloadsModel.shared.removeHistory(since: since) }
        if types.contains(.siteSettings), let page = page() {
            for permission in SitePermission.allCases {
                let name = Self.exceptionsPreference(permission)
                page.setPreference(name, PermissionException.removing(from: page.preference(name), since: since))
            }
        }
        engine.deleteBrowsingData(types, since: since, completion: completion)
    }

    // MARK: Permissions

    static func exceptionsPreference(_ permission: SitePermission) -> String {
        "profile.content_settings.exceptions." + permission.contentSettingsType
    }

    func defaultValue(_ permission: SitePermission) -> SitePermissionValue? {
        page()?.defaultSitePermission(permission)
    }

    func setDefault(_ permission: SitePermission, _ value: SitePermissionValue) {
        page()?.setDefaultSitePermission(permission, value)
    }

    func exceptions(_ permission: SitePermission) -> [PermissionException] {
        PermissionException.list(page()?.preference(Self.exceptionsPreference(permission)))
    }

    /// Allow or block a listed site, or (nil) remove it so it follows the default.
    func set(_ exception: PermissionException, _ value: SitePermissionValue?, for permission: SitePermission) {
        guard let page = page() else { return }
        let name = Self.exceptionsPreference(permission)
        var pref = page.preference(name) as? [String: Any] ?? [:]
        if let value, value != .ask, var entry = pref[exception.key] as? [String: Any] {
            entry["setting"] = NSNumber(value: value == .allow ? 1 : 2)
            pref[exception.key] = entry
        } else {
            pref[exception.key] = nil
        }
        page.setPreference(name, pref)
    }
}

/// kite://settings/privacy, …/clearBrowserData, …/content and …/content/<permission>: what Arc's
/// Profile settings links open (Chromium's settings pages there). Laid out like Kite's other
/// kite:// pages, with Chromium 156's sections, rows and wording.
struct SettingsPageView: View {
    let page: SettingsPage
    let controls: ProfileDataControls
    /// Goes to another settings page in this tab.
    let navigate: (SettingsPage, _ toast: String?) -> Void
    /// Shown for 5 seconds at the bottom, as Chromium's "… deleted" toast.
    @State var toast: String?

    @State private var revision = 0
    @State private var ready = false

    enum Metrics {
        static let maxWidth: CGFloat = 680
        static let rowHeight: CGFloat = 56
        static let cardRadius: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                if let parent {
                    Button { navigate(parent, nil) } label: { Image(systemName: "arrow.left") }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Back")
                        .accessibilityIdentifier("settingsBack")
                }
                Text(page.heading).font(.system(size: 20, weight: .regular))
                    .accessibilityIdentifier("settingsHeading")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    let _ = revision
                    content
                }
                .frame(maxWidth: Metrics.maxWidth)
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay {
            if page == .clearBrowserData, ready {
                DeleteBrowsingDataDialog(controls: controls) { deleted in
                    navigate(.privacy, deleted)
                }
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let toast {
                Text(toast)
                    .padding(.horizontal, 16)
                    .frame(height: 40)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .darkGray)))
                    .foregroundStyle(.white)
                    .padding(24)
                    .accessibilityIdentifier("settingsToast")
                    .transition(.opacity)
            }
        }
        .task {
            // The tab's Chromium browser may not exist yet on a brand-new tab.
            for _ in 0..<40 where !controls.isReady {
                try? await Task.sleep(for: .milliseconds(100))
            }
            ready = true
            revision += 1
        }
        .task(id: toast) {
            guard toast != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            withAnimation { toast = nil }
        }
    }

    private var parent: SettingsPage? {
        switch page {
        case .privacy, .clearBrowserData: nil
        case .siteSettings: .privacy
        case .permission: .siteSettings
        }
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .privacy, .clearBrowserData:
            card {
                linkRow("trash", "Delete browsing data", "Delete history, cookies, cache, and more", id: "clearBrowsingData") {
                    navigate(.clearBrowserData, nil)
                }
                Divider().padding(.leading, 52)
                linkRow("slider.horizontal.3", "Site settings",
                        "Control what information websites can use and what content they can show you", id: "siteSettingsLinkRow") {
                    navigate(.siteSettings, nil)
                }
            }
        case .siteSettings:
            Text("Permissions").font(.system(size: 13, weight: .semibold))
            card {
                // Chromium's order.
                let permissions: [SitePermission] = [.location, .camera, .microphone, .notifications]
                ForEach(Array(permissions.enumerated()), id: \.element) { index, permission in
                    if index > 0 { Divider().padding(.leading, 52) }
                    linkRow(permission.symbol, permission.title, defaultLine(permission), id: "permission.\(permission.rawValue)") {
                        navigate(.permission(permission), nil)
                    }
                }
            }
        case .permission(let permission):
            permissionPage(permission)
        }
    }

    private func defaultLine(_ permission: SitePermission) -> String {
        guard let value = controls.defaultValue(permission), controls.keepsPreferences else { return "Needs the Chromium engine" }
        return value == .block ? permission.blockDescription : permission.askDescription
    }

    @ViewBuilder
    private func permissionPage(_ permission: SitePermission) -> some View {
        if controls.keepsPreferences, let value = controls.defaultValue(permission) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Default behavior").font(.system(size: 13, weight: .semibold))
                Text(permission.defaultBehaviorDescription).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            card {
                Picker("Default behavior", selection: Binding(
                    get: { value == .block ? SitePermissionValue.block : .ask },
                    set: { controls.setDefault(permission, $0); revision += 1 }
                )) {
                    Text(permission.askDescription).tag(SitePermissionValue.ask)
                    Text(permission.blockDescription).tag(SitePermissionValue.block)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("defaultBehavior")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Customized behaviors").font(.system(size: 13, weight: .semibold))
                Text("Sites listed below follow a custom setting instead of the default").foregroundStyle(.secondary)
            }
            .padding(.top, 8)
            let exceptions = controls.exceptions(permission)
            exceptionList(permission.blockedHeading, exceptions.filter { $0.value == .block }, permission, id: "blocked")
            exceptionList(permission.allowedHeading, exceptions.filter { $0.value == .allow }, permission, id: "allowed")
        } else {
            Text("Camera, microphone, location and notification permissions need the Chromium engine.")
                .foregroundStyle(.secondary)
        }
    }

    private func exceptionList(_ heading: String, _ sites: [PermissionException], _ permission: SitePermission, id: String) -> some View {
        card {
            Text(heading).font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 16).frame(height: 44)
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            if sites.isEmpty {
                Text("No sites added").foregroundStyle(.secondary)
                    .padding(.horizontal, 16).frame(height: 44)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(Array(sites.enumerated()), id: \.element.key) { index, site in
                if index > 0 { Divider().padding(.leading, 52) }
                HStack(spacing: 16) {
                    FaviconView(page: URL(string: site.site), size: 20)
                    Text(site.site).textSelection(.enabled)
                    Spacer(minLength: 0)
                    Menu {
                        Button("Allow") { controls.set(site, .allow, for: permission); revision += 1 }
                            .disabled(site.value == .allow)
                        Button("Block") { controls.set(site, .block, for: permission); revision += 1 }
                            .disabled(site.value == .block)
                        Button("Remove") { controls.set(site, nil, for: permission); revision += 1 }
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .fixedSize()
                        .accessibilityLabel("More actions for \(site.site)")
                }
                .padding(.horizontal, 16)
                .frame(height: 48)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("exceptions.\(id)")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08)))
    }

    private func linkRow(_ symbol: String, _ title: String, _ detail: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: Metrics.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }
}

/// Chromium 156's Delete browsing data dialog: time-range chips (More ▾ for the rest), the
/// checkboxes (default three, Show more for the others), Cancel and "Delete from this device"
/// (Chromium's label when not signed in to Google, as Arc always is). Nothing is deleted
/// until that button is pressed.
struct DeleteBrowsingDataDialog: View {
    let controls: ProfileDataControls
    /// Called when the dialog closes: the toast text after deleting, nil after Cancel.
    let close: (String?) -> Void

    @State private var period: BrowsingDataPeriod = .default
    @State private var checked: Set<BrowsingDataType> = []
    @State private var expanded = false
    @State private var initialShown: [BrowsingDataType] = []
    @State private var deleting = false
    @State private var loaded = false

    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .contentShape(Rectangle())
                .onTapGesture {}
            VStack(alignment: .leading, spacing: 0) {
                Text("Delete browsing data").font(.system(size: 15, weight: .semibold))
                    .padding(.bottom, 16)
                chips.padding(.bottom, 12)
                ForEach(rows, id: \.self) { type in
                    Toggle(type.title, isOn: Binding(
                        get: { checked.contains(type) },
                        set: { if $0 { checked.insert(type) } else { checked.remove(type) } }
                    ))
                    .toggleStyle(.checkbox)
                    .disabled(deleting)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("browsingData.\(type.rawValue)")
                }
                if !expanded, rows.count < controls.available.count {
                    Button { expanded = true } label: {
                        HStack(spacing: 4) { Text("Show more"); Image(systemName: "chevron.down") }
                    }
                    .buttonStyle(.borderless)
                    .padding(.top, 6)
                    .accessibilityIdentifier("showMoreButton")
                }
                HStack(spacing: 8) {
                    Spacer()
                    if deleting { ProgressView().controlSize(.small) }
                    Button("Cancel") { close(nil) }
                        .keyboardShortcut(.cancelAction)
                        .disabled(deleting)
                        .accessibilityIdentifier("cancelButton")
                    Button("Delete from this device", action: delete)
                        .buttonStyle(.borderedProminent)
                        .disabled(deleting || checked.intersection(rows).isEmpty)
                        .accessibilityIdentifier("deleteButton")
                }
                .padding(.top, 20)
            }
            .padding(20)
            .frame(width: 512, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.3), radius: 16, y: 4))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("deleteBrowsingDataDialog")
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            period = controls.period()
            checked = controls.checkedTypes()
            initialShown = BrowsingDataType.split(controls.available, checked: checked).shown
        }
    }

    /// The default three and whatever was checked when the dialog opened; Show more adds the rest.
    private var rows: [BrowsingDataType] { expanded ? controls.available : initialShown }

    private var chips: some View {
        let (shown, more) = BrowsingDataPeriod.chips(selected: period)
        return HStack(spacing: 8) {
            ForEach(shown, id: \.self) { option in
                Button { period = option } label: {
                    HStack(spacing: 4) {
                        if option == period { Image(systemName: "checkmark") }
                        Text(option.title()).lineLimit(1)
                    }
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Capsule().fill(option == period ? Color.accentColor.opacity(0.2) : .clear))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(option == period ? 0 : 0.2)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(deleting)
                .accessibilityAddTraits(option == period ? .isSelected : [])
                .accessibilityIdentifier("timePeriod.\(option.rawValue)")
            }
            if !more.isEmpty {
                Menu {
                    ForEach(more, id: \.self) { option in Button(option.title()) { period = option } }
                } label: { Text("More") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .disabled(deleting)
                    .accessibilityIdentifier("moreButton")
            }
        }
    }

    private func delete() {
        let types = checked.intersection(rows)
        deleting = true
        controls.remember(checked, period)
        let period = period
        controls.delete(types, period: period) {
            deleting = false
            close(period.deletedMessage)
        }
    }
}

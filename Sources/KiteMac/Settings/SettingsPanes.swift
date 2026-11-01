import AppKit
import KiteCore
import SwiftUI

// The panes other than Shortcuts, laid out from Arc 1.169's (AX tree and captures of each pane,
// ~/rea-arc/settings/pane-N), with Arc renamed Kite. Arc options Kite doesn't have are shown in
// place but disabled. Kite-only settings come after Arc's, under their own headers.

/// Arc's account, sync and membership card (not recorded: it's the signed-in user's data). Kite has no account.
struct AccountPane: View {
    var body: some View {
        SettingsPaneContainer {
            SettingsSection {
                SettingsRow(title: "Kite doesn’t have accounts. Everything stays on this Mac.") { EmptyView() }
                SettingsSeparator()
                UnsupportedToggle("Sync Sidebar")
            }
        }
    }
}

/// Arc: two sections, "Automatically update my Arc ⓘ" and "Warn before quitting", then
/// "Previews" and the Profile Settings pointer.
struct GeneralPane: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        let _ = model.revision
        SettingsPaneContainer {
            SettingsSection {
                // Kite updates when you ask it to (Check for Updates…, below).
                UnsupportedToggle("Automatically update my Kite")
                SettingsSeparator()
                CommandToggle("Warn before quitting", #selector(AppDelegate.toggleQuitWarning(_:)))
            }
            SettingsSection {
                SettingsRow(title: "Previews") { Button("Previews Settings…") {}.disabled(true) }
                SettingsSeparator()
                SettingsRow(title: "Manage your default search engine, Auto-Archive, and downloads in Profile Settings.") {
                    Button("Profile Settings…") { SettingsWindowController.shared.show(.profiles) }
                }
            }
            // Kite's own, below Arc's.
            SettingsSection(header: "Kite") {
                CommandToggle(
                    "Block Ads and Trackers",
                    detail: "Use Kite’s built-in protection against ads, pop-ups, and trackers.",
                    #selector(BrowserWindowController.toggleAdblock(_:))
                )
                SettingsSeparator()
                PasswordManagerPicker()
                SettingsSeparator()
                SettingsRow(title: "Updates") {
                    CommandButton("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
                }
                if !BrowserWindowController.isDefaultBrowser {
                    SettingsSeparator()
                    SettingsRow(title: "Kite is not your default web browser.") {
                        CommandButton("Set as Default Browser", #selector(BrowserWindowController.setAsDefaultBrowser(_:)))
                    }
                }
            }
        }
    }
}

/// Arc: the blurb, then a 205pt profile list (with + − and autofill buttons under it) beside the
/// selected profile's settings, 20pt to its right.
struct ProfilesPane: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        let _ = model.revision
        VStack(alignment: .leading, spacing: 20) {
            Text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. Kite has one Profile for now.")
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 530, alignment: .leading)
            HStack(alignment: .top, spacing: 20) {
                ProfileList(spaces: model.spaceCount)
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSection {
                        SettingsRow(title: "Search engine") {
                            Picker("", selection: Binding(get: { model.searchEngine }, set: { model.searchEngine = $0 })) {
                                ForEach(SearchEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                            .labelsHidden().frame(width: 180)
                        }
                        SettingsSeparator()
                        SettingsRow(title: "Manage search") { Button("Search Settings…") {}.disabled(true) }
                        SettingsSeparator()
                        UnsupportedToggle("Include search engine suggestions")
                    }
                    SettingsSection {
                        SettingsRow(title: "Archive tabs after") {
                            Picker("", selection: Binding(
                                get: { model.archiveAfter },
                                set: { model.perform(.init(action: #selector(AppDelegate.setArchiveInterval(_:)), tag: ArchiveInterval.allCases.firstIndex(of: $0) ?? 0)) }
                            )) {
                                ForEach(ArchiveInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                            }
                            .labelsHidden().frame(width: 180)
                        }
                        SettingsSeparator()
                        SettingsRow(title: "New documents") {
                            Picker("", selection: .constant(0)) { Text("——").tag(0) }.labelsHidden().frame(width: 180).disabled(true)
                        }
                        SettingsSeparator()
                        SettingsRow(title: "Download location") {
                            Picker("", selection: .constant(0)) { Text("Downloads").tag(0) }.labelsHidden().frame(width: 180).disabled(true)
                        }
                    }
                    SettingsSection(header: "Your Data and Settings") {
                        DataLink("Privacy and Security", SettingsIcon(symbol: "lock.fill", color: .blue))
                        DataLink("Passwords", SettingsIcon(symbol: "key.fill", color: .green))
                        DataLink("Credit Cards", SettingsIcon(symbol: "creditcard.and.123", color: .yellow))
                        DataLink("Notifications", SettingsIcon(symbol: "bell.fill", color: .orange))
                        DataLink("Clear Browsing Data", SettingsIcon(symbol: "trash.fill", color: .red))
                    }
                }
                .frame(width: 331)
            }
        }
        .padding(.top, SettingsMetrics.topMargin)
        .frame(width: SettingsMetrics.sectionWidth, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// Arc's profile list: "Your Profiles", a 40pt row per profile with its Space count, and
/// + − and autofill buttons along the bottom.
private struct ProfileList: View {
    let spaces: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Your Profiles").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.leading, 16).frame(height: 28)
            SettingsMetrics.line.frame(height: 1)
            HStack {
                Text("Default")
                Spacer()
                Text(spaces == 1 ? "1 Space" : "\(spaces) Spaces").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.25)).padding(.horizontal, 6))
            Spacer()
            SettingsMetrics.line.frame(height: 1)
            HStack(spacing: 0) {
                ForEach(["plus", "minus", "rectangle.and.pencil.and.ellipsis"], id: \.self) { symbol in
                    Button {} label: { Image(systemName: symbol).frame(width: 29, height: 28) }
                        .buttonStyle(.plain).disabled(true)
                }
                Spacer()
            }
            .frame(height: 30)
        }
        .frame(width: 205, height: 458)
        .background(RoundedRectangle(cornerRadius: SettingsMetrics.cornerRadius).fill(Color.black.opacity(0.15)))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cornerRadius).strokeBorder(SettingsMetrics.line, lineWidth: 1))
    }
}

/// A row in Arc's "Your Data and Settings": coloured icon, label, and an arrow on the right.
private struct DataLink: View {
    let title: String
    let icon: SettingsIcon

    init(_ title: String, _ icon: SettingsIcon) {
        self.title = title
        self.icon = icon
    }

    var body: some View {
        SettingsRow(title: title, icon: icon) {
            Image(systemName: "arrow.right").foregroundStyle(Color.accentColor)
        }
        .padding(.vertical, -2.5)
        .disabled(true)
    }
}

/// Arc Max: a 128pt banner, the blurb, "Enable Max" with Turn On All, then one row per feature
/// with an 88×56 preview, title, description and switch. Kite's features run on Claude.
struct MaxPane: View {
    @EnvironmentObject private var model: SettingsModel

    private var features: [(title: String, detail: String, symbol: String, toggle: AnyView)] {
        [
            ("Tidy Tabs", "Press the broom icon to let your Sidebar organize itself whenever you have more than six Today Tabs.",
             "wand.and.stars", AnyView(FeatureSwitch(command: .init(action: #selector(AppDelegate.toggleTidyTabs(_:)))))),
            ("Instant Links", "Press Shift + Enter for any web search to instantly open the top result.",
             "bolt.fill", AnyView(FeatureDefaultsSwitch(key: InstantLinksController.enabledKey, default: true))),
            ("5-Second Previews", "Hold Shift while hovering over a link to preview it.",
             "rectangle.and.text.magnifyingglass", AnyView(FeatureSwitch(command: .init(action: #selector(AppDelegate.toggleLinkPreviews(_:)))))),
            ("Tidy Tab Titles", "Have your tabs automatically renamed with tidier, shorter titles when you Pin them.",
             "textformat", AnyView(FeatureSwitch(command: .init(action: #selector(AppDelegate.toggleTidyTabTitles(_:)))))),
            ("Tidy Downloads", "Keep your many files more organized with smartly renamed downloads — and make them a little easier to find later.",
             "arrow.down.doc", AnyView(FeatureSwitch(command: .init(action: #selector(AppDelegate.toggleTidyDownloads(_:)))))),
            ("Ask on Page", "Press Command + F on any page to ask a question and get an answer in seconds.",
             "questionmark.bubble", AnyView(FeatureSwitch(command: .init(action: #selector(AppDelegate.toggleAskOnPage(_:)))))),
            ("ChatGPT in the Command Bar", "Not in Kite: ask Claude from the Command Bar instead.",
             "text.bubble", AnyView(Toggle("", isOn: .constant(false)).toggleStyle(.switch).labelsHidden().controlSize(.mini).disabled(true))),
        ]
    }

    /// Commands Turn On All switches on.
    private let commands: [Selector] = [
        #selector(AppDelegate.toggleTidyTabs(_:)), #selector(AppDelegate.toggleLinkPreviews(_:)),
        #selector(AppDelegate.toggleTidyTabTitles(_:)), #selector(AppDelegate.toggleTidyDownloads(_:)),
        #selector(AppDelegate.toggleAskOnPage(_:)),
    ]

    var body: some View {
        let _ = model.revision
        ScrollView {
            VStack(spacing: 0) {
                // Arc's MaxBannerColor asset (#484FFF in both appearances).
                SettingsBanner(color: Color(nsColor: SettingsMetrics.srgb(0x484FFF)), symbol: "sparkles", height: 128)
                VStack(alignment: .leading, spacing: 18) {
                    Text("Let Kite do more for you with Max, so you can do less. Kite’s AI features run on Claude.")
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 5)
                    SettingsSection {
                        SettingsRow(title: "Enable Max", icon: SettingsIcon(symbol: "sparkles", color: .indigo)) {
                            Button("Turn On All") {
                                for action in commands where !model.state(.init(action: action)).on { model.perform(.init(action: action)) }
                                UserDefaults.standard.set(true, forKey: InstantLinksController.enabledKey)
                            }
                            .buttonStyle(.borderedProminent).controlSize(.large).frame(width: 117)
                        }
                        SettingsSeparator()
                        UnsupportedToggle("Automatically enable future Kite Max features")
                    }
                    SettingsSection {
                        ForEach(Array(features.enumerated()), id: \.offset) { i, feature in
                            if i > 0 { SettingsSeparator() }
                            HStack(alignment: .center, spacing: 19) {
                                RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.18))
                                    .overlay(Image(systemName: feature.symbol).font(.system(size: 20)).foregroundStyle(Color.accentColor))
                                    .frame(width: 88, height: 56)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(feature.title)
                                    Text(feature.detail).font(.system(size: 12)).foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 8)
                                feature.toggle
                            }
                            .padding(.horizontal, SettingsMetrics.rowInset)
                            .padding(.vertical, 12.5)
                        }
                    }
                    Text("Max features send what they work on to Claude.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                .frame(width: SettingsMetrics.sectionWidth)
                .padding(.top, 24)
                .padding(.bottom, SettingsMetrics.topMargin)
            }
        }
    }
}

private struct FeatureSwitch: View {
    @EnvironmentObject private var model: SettingsModel
    let command: SettingsModel.Command

    var body: some View {
        let _ = model.revision
        let state = model.state(command)
        Toggle("", isOn: Binding(get: { state.on }, set: { _ in model.perform(command) }))
            .toggleStyle(.switch).labelsHidden().controlSize(.mini).disabled(!state.enabled)
    }
}

private struct FeatureDefaultsSwitch: View {
    @AppStorage private var isOn: Bool

    init(key: String, default value: Bool) {
        _isOn = AppStorage(wrappedValue: value, key)
    }

    var body: some View {
        Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.mini)
    }
}

/// The coloured band across the top of Max (128pt) and Links (135pt). Arc's are illustrations;
/// Kite draws a plain band with a symbol.
private struct SettingsBanner: View {
    let color: Color
    let symbol: String
    let height: CGFloat

    var body: some View {
        color
            .overlay(Image(systemName: symbol).font(.system(size: 44, weight: .semibold)).foregroundStyle(.white))
            .frame(height: height)
            .frame(maxWidth: .infinity)
    }
}

/// Arc: a 135pt Little Arc banner, the Little Arc blurb and section, a rule, the Peek blurb and
/// section, then Air Traffic Control.
struct LinksPane: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                SettingsBanner(color: Color(red: 0.88, green: 0.50, blue: 0.52), symbol: "macwindow", height: 135)
                VStack(alignment: .leading, spacing: 18) {
                    SettingsBlurb("Little Kite is a smaller, simpler Kite window. It’s perfect for quick lookups and reading funny tweets your friends send you.")
                    SettingsSection {
                        UnsupportedToggle("Open Little Kite when I press ⌥⌘N in any app")
                        SettingsSeparator()
                        UnsupportedToggle("Open Little Kite when clicking on links with ⌥⌘ held")
                        SettingsSeparator()
                        CommandToggle("Links from other apps open in Little Kite", #selector(AppDelegate.toggleLittleKiteLinks(_:)))
                        SettingsSeparator()
                        SettingsRow(title: "Archive Little Kites after:") {
                            Picker("", selection: .constant(0)) { Text("6 hours (default)").tag(0) }
                                .labelsHidden().frame(width: 200).disabled(true)
                        }
                    }
                    SettingsMetrics.line.frame(height: 1).padding(.vertical, 6)
                    SettingsBlurb("Peek is a way to preview a link without opening a new tab. It’s perfect for quickly looking at a link from an email, news article, or tweet.")
                    SettingsSection {
                        UnsupportedToggle("Open a Peek window when clicking on links with Shift held")
                        SettingsSeparator()
                        UnsupportedToggle("Open a Peek window when clicking on links to other sites", detail: "Note: This only affects Favorites and Pinned tabs")
                    }
                    SettingsSection {
                        SettingsRow(title: "Choose where links open inside Kite.") {
                            CommandButton("Air Traffic Control…", #selector(AppDelegate.showAirTrafficControl(_:)))
                        }
                    }
                }
                .frame(width: SettingsMetrics.sectionWidth)
                .padding(.top, 24)
                .padding(.bottom, SettingsMetrics.topMargin)
            }
        }
    }
}

/// Arc's alternate app icons: one 556×515 list, a row per icon with a radio button, a 64pt icon
/// and its name ("CURRENT ICON" under the chosen one). Kite has one icon.
struct IconPane: View {
    var body: some View {
        SettingsPaneContainer {
            // Arc: radio at x 80, icon at 122, name at 194; the first row 10pt down, its icon 8pt below that.
            SettingsSection {
                HStack(spacing: 0) {
                    Image(systemName: "largecircle.fill.circle").font(.system(size: 20)).foregroundStyle(Color.accentColor)
                        .frame(width: 22, height: 22)
                        .padding(.trailing, 20)
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                        .padding(.trailing, 8)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kite").font(.system(size: 14, weight: .semibold))
                        Text("CURRENT ICON").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.accentColor)
                    }
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.top, 18)
                .frame(height: 515, alignment: .top)
            }
        }
    }
}

/// Arc: three sections of rows with coloured icons (sound and haptics; windows, toolbar and
/// quotes; picture in picture, theme data and Boosts), then More Settings…, Reset Translated-site
/// Prompts and Export Data. Kite's Toolbar buttons and own settings follow.
struct AdvancedPane: View {
    var body: some View {
        SettingsPaneContainer {
            SettingsSection {
                CommandToggle("Play Kite sound effects", icon: SettingsIcon(symbol: "speaker.wave.2.fill", color: .blue), #selector(AppDelegate.toggleSoundEffects(_:)))
                SettingsSeparator()
                UnsupportedToggle("Haptic feedback when reordering tabs", icon: SettingsIcon(symbol: "hand.tap.fill", color: .blue))
            }
            SettingsSection {
                UnsupportedToggle("When opening Kite, restore windows from previous session", icon: SettingsIcon(symbol: "macwindow", color: .green))
                SettingsSeparator()
                UnsupportedToggle("Allow window dragging from the top of webpages", icon: SettingsIcon(symbol: "rectangle.topthird.inset.filled", color: .green))
                SettingsSeparator()
                CommandToggle("Show full URL when Toolbar is enabled", icon: SettingsIcon(symbol: "ellipsis.rectangle", color: .red), #selector(AppDelegate.toggleToolbarFullURLs(_:)))
                SettingsSeparator()
                UnsupportedToggle(
                    "Enable Shared Quotes when highlighting text.",
                    detail: "If disabled, you can still copy URL as a quote using ⌃⇧⌘C.",
                    icon: SettingsIcon(symbol: "quote.opening", color: .red)
                )
            }
            SettingsSection {
                UnsupportedToggle("Enable Picture in Picture when you leave a video tab", icon: SettingsIcon(symbol: "play.square", color: .purple))
                SettingsSeparator()
                UnsupportedToggle("Allow websites to get your theme data", icon: SettingsIcon(symbol: "paintpalette.fill", color: .purple))
                SettingsSeparator()
                UnsupportedToggle("Enable Boosts on websites you visit", icon: SettingsIcon(symbol: "paintbrush.fill", color: .purple))
            }
            HStack(spacing: 8) {
                Button("More Settings…") {}.disabled(true)
                Button("Reset Translated-site Prompts") {}.disabled(true)
                Spacer()
                Button("Export Data") {}.disabled(true)
            }
            .padding(.top, 4)
            // Kite's own: a switch for each address field and toolbar button, then settings Arc doesn't have.
            SettingsSection(header: "Toolbar") {
                ToolbarButtonsList()
            }
            SettingsSection(header: "Kite") {
                CommandToggle("Low Battery Energy Saver (30 fps)", #selector(AppDelegate.toggleEnergySaver(_:)))
                SettingsSeparator()
                DarkPagesRow()
                SettingsSeparator()
                CommandToggle("Allow Claude to Control the Browser", #selector(AppDelegate.toggleClaudeControl(_:)))
                SettingsSeparator()
                CommandToggle("Open Claude’s Tabs in a Claude Space", #selector(AppDelegate.toggleClaudeSpace(_:)))
                SettingsSeparator()
                CommandToggle("Record Network for Claude", #selector(AppDelegate.toggleRecordNetwork(_:)))
                SettingsSeparator()
                CommandToggle("Ask Claude in the Claude App", #selector(AppDelegate.toggleClaudeRunsInDesktop(_:)))
                SettingsSeparator()
                CommandToggle("Diagnostics for Claude", #selector(AppDelegate.toggleClaudeDiagnostics(_:)))
            }
        }
    }
}

/// View → Dark Pages, whose items are tagged with DarkPagesMode's index.
private struct DarkPagesRow: View {
    @EnvironmentObject private var model: SettingsModel
    private let titles: [DarkPagesMode: String] = [.off: "Off", .matchSystem: "Match System", .always: "Always"]

    var body: some View {
        let _ = model.revision
        let modes = DarkPagesMode.allCases
        let command = { (i: Int) in SettingsModel.Command(action: #selector(BrowserWindowController.setDarkPagesMode(_:)), tag: i) }
        let current = modes.indices.first { model.state(command($0)).on } ?? 0
        SettingsRow(title: "Dark Pages") {
            Picker("", selection: Binding(get: { current }, set: { model.perform(command($0)) })) {
                ForEach(modes.indices, id: \.self) { Text(titles[modes[$0]] ?? "").tag($0) }
            }
            .labelsHidden().frame(width: 180)
        }
    }
}

/// Settings → Advanced → Toolbar: a checkbox per button. Hidden buttons' commands still work.
private struct ToolbarButtonsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Show these buttons:")
            ForEach(ChromeButton.allCases, id: \.self) { button in
                ToolbarButtonCheckbox(button: button)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowInset)
        .padding(.vertical, SettingsMetrics.rowVerticalPadding)
    }
}

private struct ToolbarButtonCheckbox: View {
    let button: ChromeButton
    @AppStorage private var hidden: Bool

    init(button: ChromeButton) {
        self.button = button
        _hidden = AppStorage(wrappedValue: false, button.hiddenKey)
    }

    var body: some View {
        Toggle(isOn: Binding(get: { !hidden }, set: { button.setShown($0) })) {
            HStack(spacing: 6) {
                Text(button.title)
                Text(button.location).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
    }
}

/// Settings → General → Password manager: which one the address field's key button opens.
/// No value means automatic (1Password if it's installed, else Bitwarden).
// TODO: use PasswordManager.allCases and .name once claude/password-manager-setting merges.
private struct PasswordManagerPicker: View {
    @AppStorage("passwordManager") private var choice = ""
    private let options: [(value: String, title: String)] = [
        ("", "Automatic"), ("1password", "1Password"), ("bitwarden", "Bitwarden"), ("none", "None"),
    ]

    var body: some View {
        SettingsRow(title: "Password manager") {
            Picker("", selection: Binding(
                get: { choice },
                set: { value in
                    if value.isEmpty { UserDefaults.standard.removeObject(forKey: "passwordManager") } else { choice = value }
                }
            )) {
                ForEach(options, id: \.value) { Text($0.title).tag($0.value) }
            }
            .labelsHidden().frame(width: 180)
        }
    }
}

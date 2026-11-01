import AppKit
import KiteCore
import SwiftUI

// The panes other than Shortcuts. Their wording is Arc 1.169's (from its binary), with Arc
// renamed Kite; their layout hasn't been measured yet, except Account's frame. Arc options
// Kite doesn't have are shown in place but disabled (UnsupportedToggle).

/// Arc's account, sync and membership card. Kite has no account.
struct AccountPane: View {
    var body: some View {
        SettingsPaneContainer {
            SettingsSection(header: "Account") {
                Text("Kite doesn’t have accounts. Everything stays on this Mac.")
                    .foregroundStyle(.secondary)
            }
            SettingsSection(header: "Sync") {
                UnsupportedToggle("Sync Sidebar")
            }
        }
    }
}

struct GeneralPane: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        let _ = model.revision
        SettingsPaneContainer {
            if !BrowserWindowController.isDefaultBrowser {
                SettingsSection {
                    SettingsRow(title: "Kite is not your default web browser.") {
                        CommandButton("Set as Default Browser", #selector(BrowserWindowController.setAsDefaultBrowser(_:)))
                    }
                }
            }
            SettingsSection {
                SettingsRow(title: "Manage your default search engine, Auto-Archive, and downloads in Profile Settings.") {
                    Button("Profile Settings…") { SettingsWindowController.shared.show(.profiles) }
                }
            }
            SettingsSection(header: "Ad Blocker") {
                CommandToggle(
                    "Block Ads and Trackers",
                    detail: "Use Kite’s built-in protection against ads, pop-ups, and trackers.",
                    #selector(BrowserWindowController.toggleAdblock(_:))
                )
                UnsupportedToggle("Block Cookie Banners", detail: "Blocking cookie banners may cause pages to load incorrectly.")
            }
            SettingsSection {
                CommandToggle("Warn before quitting", #selector(AppDelegate.toggleQuitWarning(_:)))
                SettingsRow(title: "Automatically update my Kite") {
                    CommandButton("Check for Updates…", #selector(AppDelegate.checkForUpdates(_:)))
                }
            }
        }
    }
}

struct ProfilesPane: View {
    @EnvironmentObject private var model: SettingsModel

    var body: some View {
        let _ = model.revision
        SettingsPaneContainer {
            Text("Profiles help keep your data separate across Spaces — like history, logins, cookies, and extensions. Kite has one Profile for now.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsSection(header: "Default Profile") {
                SettingsRow(title: "Default Search Engine") {
                    Picker("", selection: Binding(get: { model.searchEngine }, set: { model.searchEngine = $0 })) {
                        ForEach(SearchEngine.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                UnsupportedToggle("Include search engine suggestions")
                SettingsRow(title: "Archive tabs after") {
                    Picker("", selection: Binding(
                        get: { model.archiveAfter },
                        set: { model.perform(.init(action: #selector(AppDelegate.setArchiveInterval(_:)), tag: ArchiveInterval.allCases.firstIndex(of: $0) ?? 0)) }
                    )) {
                        ForEach(ArchiveInterval.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow(title: "Download location") {
                    Text("Downloads").foregroundStyle(.secondary)
                }
            }
            SettingsSection(header: "Privacy and Security") {
                SettingsRow(title: "Clear Browsing Data") { Button("Clear…") {}.disabled(true) }
            }
        }
    }
}

/// Arc Max's AI features. Kite's run on Claude.
struct MaxPane: View {
    var body: some View {
        SettingsPaneContainer {
            Text("Let Kite do more for you, so you can do less. Kite’s AI features run on Claude.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SettingsSection {
                UnsupportedToggle("ChatGPT in the Command Bar")
                CommandToggle("Tidy Tabs", #selector(AppDelegate.toggleTidyTabs(_:)))
                CommandToggle(
                    "Tidy Downloads",
                    detail: "Keep your many files more organized with smartly renamed downloads — and make them a little easier to find later.",
                    #selector(AppDelegate.toggleTidyDownloads(_:))
                )
                CommandToggle(
                    "Tidy Tab Titles",
                    detail: "Have your tabs automatically renamed with tidier, shorter titles when you Pin them.",
                    #selector(AppDelegate.toggleTidyTabTitles(_:))
                )
                CommandToggle("5-Second Previews", detail: "Hold Shift while hovering to preview any link.", #selector(AppDelegate.toggleLinkPreviews(_:)))
                CommandToggle(
                    "Ask on Page",
                    detail: "Press Command + F on any page to ask a question and get an answer in seconds.",
                    #selector(AppDelegate.toggleAskOnPage(_:))
                )
            }
            SettingsSection {
                UnsupportedToggle("Automatically enable future AI features")
            }
        }
    }
}

struct LinksPane: View {
    var body: some View {
        SettingsPaneContainer {
            SettingsSection(header: "Air Traffic Control") {
                SettingsRow(title: "Choose where links open inside Kite.") {
                    CommandButton("Air Traffic Control…", #selector(AppDelegate.showAirTrafficControl(_:)))
                }
            }
            SettingsSection(header: "Peek") {
                UnsupportedToggle("Open a Peek window when clicking on links to other sites", detail: "Note: This only affects Favorites and Pinned tabs")
                UnsupportedToggle("Open a Peek window when clicking on links with Shift held")
            }
            SettingsSection(header: "Little Kite") {
                Text("Little Kite is a smaller, simpler Kite window. It’s perfect for quick lookups.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CommandToggle("Links from other apps open in Little Kite", #selector(AppDelegate.toggleLittleKiteLinks(_:)))
                UnsupportedToggle("Open Little Kite when clicking on links with ⌥⌘ held")
            }
        }
    }
}

/// Arc's alternate app icons. Kite has one.
struct IconPane: View {
    var body: some View {
        SettingsPaneContainer {
            SettingsSection {
                HStack(spacing: 16) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Kite").font(.system(size: 13, weight: .semibold))
                        Text("Kite has one app icon for now.").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct AdvancedPane: View {
    var body: some View {
        SettingsPaneContainer {
            SettingsSection {
                UnsupportedToggle("Enable Boosts on websites you visit")
                UnsupportedToggle("Allow websites to get your theme data")
                UnsupportedToggle("Enable Picture in Picture when you leave a video tab")
                UnsupportedToggle("Allow window dragging from the top of webpages")
                UnsupportedToggle("Enable Shared Quotes when highlighting text.")
                CommandToggle("Show full URL when Toolbar is enabled", #selector(AppDelegate.toggleToolbarFullURLs(_:)))
                UnsupportedToggle("When opening Kite, restore windows from previous session")
                UnsupportedToggle("Haptic feedback when reordering tabs")
                CommandToggle("Play Kite sound effects", #selector(AppDelegate.toggleSoundEffects(_:)))
            }
            // Kite's own settings, which Arc doesn't have. Also in the Kite menu.
            SettingsSection(header: "Kite") {
                CommandToggle("Low Battery Energy Saver (30 fps)", #selector(AppDelegate.toggleEnergySaver(_:)))
                DarkPagesRow()
                CommandToggle("Allow Claude to Control the Browser", #selector(AppDelegate.toggleClaudeControl(_:)))
                CommandToggle("Open Claude’s Tabs in a Claude Space", #selector(AppDelegate.toggleClaudeSpace(_:)))
                CommandToggle("Record Network for Claude", #selector(AppDelegate.toggleRecordNetwork(_:)))
                CommandToggle("Ask Claude in the Claude App", #selector(AppDelegate.toggleClaudeRunsInDesktop(_:)))
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
            .labelsHidden().fixedSize()
        }
    }
}

import AppKit
import KiteCore
import SwiftUI

/// Settings → Shortcuts, measured from Arc 1.169's (AX tree and capture, ~/rea-arc/settings/pane-5):
/// a "Start with the basics" pill centred at the top, a 340pt list on the left (search field over
/// "Customized Shortcuts" and "Default Shortcuts", 48pt rows with a 64×24 keycap), and on the
/// right "Custom Shortcuts" with Reset All Shortcuts at the bottom, which stays as it is whatever's
/// picked (selecting a row in Arc by AX left it unchanged). Click a keycap to record; a clash shows
/// under the row; reset and remove are the row's context menu (Arc's per-row actions are menu
/// items). Changes go straight to KeyBindingsStore (keybindings.json) and the menu bar.
struct ShortcutsPane: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var query = ""
    /// The command being recorded, if any.
    @State private var recording: String?
    /// A recorded shortcut that another command already has, waiting for the user to choose.
    @State private var pending: (id: String, shortcut: KeyShortcut)?

    enum M {
        static let pillSize = CGSize(width: 372, height: 36)
        static let listWidth: CGFloat = 340
        static let listTop: CGFloat = 30
        static let columnGap: CGFloat = 16
        static let searchHeight: CGFloat = 41
        static let headerHeight: CGFloat = 28
        static let rowHeight: CGFloat = 48
        static let keycap = CGSize(width: 64, height: 24)
        // Dark: captured from Arc (list #222220, search bar #40403E, pill #656068, keycaps and rules
        // #383836). Light: the pill is Arc's MakeDefaultViewBackgroundColor asset (#656068 dark, white
        // light); the others take the light value of Arc's grey-scale step nearest their dark value
        // (ARCUI Gray3, Gray7, Gray6). Light mode wasn't captured live.
        static let listFill = SettingsMetrics.dynamic(dark: 0x222220, light: 0xF3F3F3)
        static let searchFill = SettingsMetrics.dynamic(dark: 0x40403E, light: 0xDBDBDB)
        static let pillFill = SettingsMetrics.dynamic(dark: 0x656068, light: 0xFFFFFF)
        static let keycapFill = SettingsMetrics.dynamic(dark: 0x383836, light: 0xE2E2E2)
    }

    var body: some View {
        let entries = model.shortcutEntries
        let sections = ShortcutsList.sections(entries, query: query)
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("Start with the basics")
                Button {
                    EssentialShortcutsWindow.show(menu: NSApp.mainMenu, overrides: (NSApp.delegate as? AppDelegate)?.keyBindings.bindings)
                } label: {
                    Label("Learn the Essential Shortcuts", systemImage: "command.circle.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(width: M.pillSize.width, height: M.pillSize.height)
            .background(RoundedRectangle(cornerRadius: 8).fill(M.pillFill))
            .padding(.top, SettingsMetrics.topMargin)
            HStack(alignment: .top, spacing: M.columnGap) {
                list(sections, all: entries)
                intro
            }
            .frame(width: SettingsMetrics.sectionWidth, alignment: .topLeading)
            .padding(.top, M.listTop)
            .padding(.bottom, 27)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func list(_ sections: (customized: [ShortcutEntry], defaults: [ShortcutEntry]), all: [ShortcutEntry]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Type a feature name or shortcut (like “Command E”)", text: $query)
                    .textFieldStyle(.plain)
            }
            .padding(.horizontal, 17)
            .frame(height: M.searchHeight)
            .background(M.searchFill)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !sections.customized.isEmpty { rows("Customized Shortcuts", sections.customized, all: all) }
                    if !sections.defaults.isEmpty { rows("Default Shortcuts", sections.defaults, all: all) }
                }
                .padding(.bottom, 10)
            }
        }
        .frame(width: M.listWidth)
        .frame(maxHeight: .infinity)
        .background(M.listFill)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: SettingsMetrics.cornerRadius).strokeBorder(SettingsMetrics.line, lineWidth: 1))
    }

    @ViewBuilder
    private func rows(_ title: String, _ rows: [ShortcutEntry], all: [ShortcutEntry]) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.leading, 16)
            .frame(height: M.headerHeight)
        ForEach(rows) { entry in
            ShortcutRow(
                entry: entry,
                isRecording: recording == entry.id,
                pending: pending?.id == entry.id ? pending?.shortcut : nil,
                conflicts: pending?.id == entry.id ? ShortcutsList.conflicts(for: pending?.shortcut, excluding: entry.id, in: all) : [],
                startRecording: { recording = entry.id; pending = nil },
                finishRecording: { shortcut in
                    recording = nil
                    guard let shortcut else { return }
                    if ShortcutsList.conflicts(for: shortcut, excluding: entry.id, in: all).isEmpty {
                        model.setShortcut(shortcut, for: entry.id)
                    } else {
                        pending = (entry.id, shortcut)
                    }
                },
                resolveConflict: { keep in
                    if keep, let pending {
                        model.removeConflicts(with: pending.shortcut, keeping: entry.id)
                        model.setShortcut(pending.shortcut, for: entry.id)
                    }
                    pending = nil
                }
            )
            if entry.id != rows.last?.id {
                M.keycapFill.frame(height: 1).padding(.leading, 24).padding(.trailing, 16)
            }
        }
        Spacer().frame(height: 20)
    }

    /// The right-hand column, as Arc's: keycap artwork, "Custom Shortcuts", its description, and
    /// Reset All Shortcuts with a "…" menu at the bottom.
    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                ArtKey(symbol: "command")
                ArtKey(symbol: "face.smiling")
            }
            Text("Custom Shortcuts").font(.system(size: 15, weight: .semibold)).padding(.top, 16)
            Text("Change shortcuts for your favorite actions, and even choose whether Kite or a website takes priority.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            HStack(spacing: 8) {
                Button("Reset All Shortcuts") { model.resetAllShortcuts() }
                Menu {
                    Button("Extension Shortcuts…") {}.disabled(true)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .frame(width: 24, height: 24)
                .background(Circle().fill(M.keycapFill))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The illustration over "Custom Shortcuts": two blue keycaps (Arc's is artwork; Kite draws its own).
private struct ArtKey: View {
    let symbol: String

    var body: some View {
        RoundedRectangle(cornerRadius: 10).fill(Color.accentColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.75)).padding(5)
                    .overlay(Image(systemName: symbol).font(.system(size: 24, weight: .bold)).foregroundStyle(Color.accentColor))
            )
            .frame(width: 64, height: 64)
    }
}

/// A 48pt list row: the command's name and its keycap (click to record). A recorded shortcut that
/// another command has shows Arc's note under the row, with Remove Conflicting Shortcut and Cancel.
/// Right-click for reset and remove.
private struct ShortcutRow: View {
    @EnvironmentObject private var model: SettingsModel
    let entry: ShortcutEntry
    let isRecording: Bool
    let pending: KeyShortcut?
    let conflicts: [ShortcutEntry]
    let startRecording: () -> Void
    let finishRecording: (KeyShortcut?) -> Void
    let resolveConflict: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(entry.title).lineLimit(1)
                Spacer(minLength: 8)
                ShortcutRecorder(shortcut: pending ?? entry.shortcut, isRecording: isRecording, start: startRecording, finish: finishRecording)
            }
            .frame(height: ShortcutsPane.M.rowHeight)
            if let pending, let note = ShortcutsList.conflictDescription(conflicts) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text("\(pending.displayString) \(note)").font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 8) {
                        Button(conflicts.count == 1 ? "Remove Conflicting Shortcut" : "Remove Conflicting Shortcuts") { resolveConflict(true) }
                        Button("Cancel") { resolveConflict(false) }
                    }
                    .controlSize(.small)
                }
                .padding(.bottom, 12)
            }
        }
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .contentShape(Rectangle())
        // Arc's per-row actions are menu items (its binary), not a detail view.
        .contextMenu {
            Button("Reset Shortcut to Default") { model.resetShortcut(entry.id) }
                .disabled(!entry.isCustomized)
            Button("Remove Shortcut") { model.setShortcut(nil, for: entry.id) }
                .disabled(entry.shortcut == nil)
            let clashes = ShortcutsList.conflicts(for: entry.shortcut, excluding: entry.id, in: model.shortcutEntries)
            if !clashes.isEmpty, let shortcut = entry.shortcut {
                Button(clashes.count == 1 ? "Remove Conflicting Shortcut" : "Remove Conflicting Shortcuts") {
                    model.removeConflicts(with: shortcut, keeping: entry.id)
                }
            }
            Divider()
            // Arc lets a website take priority over a shortcut; Kite's key routing has no priority yet.
            Button("When shortcuts conflict, Kite wins.") {}.disabled(true)
            Button("When shortcuts conflict, the website wins.") {}.disabled(true)
            Divider()
            Button("Reset All Shortcuts") { model.resetAllShortcuts() }
        }
    }
}

/// The shortcut as keycaps; click to record. Esc cancels; a key with no ⌘, ⌥ or ⌃ is ignored,
/// since it would fire while typing.
private struct ShortcutRecorder: View {
    let shortcut: KeyShortcut?
    let isRecording: Bool
    let start: () -> Void
    let finish: (KeyShortcut?) -> Void

    var body: some View {
        Button(action: start) {
            // Arc's keycap: 64×24, "---" when there's no shortcut.
            Text(isRecording ? "Type…" : shortcut?.displayString ?? "---")
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .frame(minWidth: ShortcutsPane.M.keycap.width, minHeight: ShortcutsPane.M.keycap.height)
                .padding(.horizontal, shortcut.map { $0.displayString.count > 4 ? 6 : 0 } ?? 0)
                .background(RoundedRectangle(cornerRadius: 6).fill(isRecording ? Color.accentColor.opacity(0.35) : ShortcutsPane.M.keycapFill))
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, now in now ? install() : remove() }
        .onAppear { if isRecording { install() } }
        .onDisappear(perform: remove)
    }

    private func install() {
        remove()
        ShortcutRecording.begin { event in
            if event.keyCode == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty {
                remove()
                finish(nil)
                return
            }
            guard let shortcut = KeyShortcut(event: event), shortcut.isSafeKeyEquivalent else { return }
            remove()
            finish(shortcut)
        }
    }

    private func remove() {
        ShortcutRecording.end()
    }
}

/// While a shortcut is being recorded, every key press goes to the recorder instead of the menu
/// bar. Real presses arrive through a local monitor (before menu key equivalents); presses from
/// `kite ui input` arrive through SettingsWindow.sendEvent, which monitors never see.
@MainActor
enum ShortcutRecording {
    private static var handler: ((NSEvent) -> Void)?
    private static var monitor: Any?

    static var isActive: Bool { handler != nil }

    static func begin(_ handle: @escaping (NSEvent) -> Void) {
        end()
        handler = handle
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isActive else { return event }
            handle(event)
            return nil
        }
    }

    static func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        handler = nil
    }

    /// Returns true if the recorder took the key.
    static func take(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, let handler else { return false }
        handler(event)
        return true
    }
}

extension KeyShortcut {
    /// The shortcut a key press makes, as a menu key equivalent.
    init?(event: NSEvent) {
        let named: [UInt16: String] = [
            123: "left", 124: "right", 125: "down", 126: "up",
            48: "tab", 36: "return", 51: "delete", 53: "escape", 49: "space",
        ]
        let key: String
        if let name = named[event.keyCode] {
            key = name
        } else if let base = event.characters(byApplyingModifiers: []), base.count == 1 {
            key = base
        } else {
            return nil
        }
        var modifiers = Set<Modifier>()
        let flags = event.modifierFlags
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.command) { modifiers.insert(.command) }
        self.init(key, modifiers)
    }
}

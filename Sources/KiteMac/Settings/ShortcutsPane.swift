import AppKit
import KiteCore
import SwiftUI

/// Settings → Shortcuts, measured from Arc 1.169's (AX tree and capture, ~/rea-arc/settings/pane-5):
/// a "Start with the basics" pill centred at the top, a 340pt list on the left (search field over
/// "Customized Shortcuts" and "Default Shortcuts", 48pt rows with a 64×24 keycap), and on the
/// right "Custom Shortcuts" with Reset All Shortcuts at the bottom. Picking a row shows it on the
/// right (Arc's detail side wasn't recorded: it needs a click inside the pane). Click a keycap to
/// record; changes go straight to KeyBindingsStore (keybindings.json) and the menu bar.
struct ShortcutsPane: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var query = ""
    @State private var selection: String?
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
        // Captured from Arc (dark): list #222220, search bar #40403E, pill #656068, keycaps and rules #383836.
        static let listFill = Color(red: 0x22 / 255, green: 0x22 / 255, blue: 0x20 / 255)
        static let searchFill = Color(red: 0x40 / 255, green: 0x40 / 255, blue: 0x3E / 255)
        static let pillFill = Color(red: 0x65 / 255, green: 0x60 / 255, blue: 0x68 / 255)
        static let keycapFill = Color(red: 0x38 / 255, green: 0x38 / 255, blue: 0x36 / 255)
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
                detail(entries.first { $0.id == selection }, all: entries)
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
                isSelected: selection == entry.id,
                isRecording: recording == entry.id,
                pending: pending?.id == entry.id ? pending?.shortcut : nil,
                select: { selection = entry.id },
                startRecording: { recording = entry.id; pending = nil },
                finishRecording: { shortcut in
                    recording = nil
                    guard let shortcut else { return }
                    if ShortcutsList.conflicts(for: shortcut, excluding: entry.id, in: all).isEmpty {
                        model.setShortcut(shortcut, for: entry.id)
                    } else {
                        // The conflict and its choices are on the right, with the picked row.
                        selection = entry.id
                        pending = (entry.id, shortcut)
                    }
                }
            )
            if entry.id != rows.last?.id {
                M.keycapFill.frame(height: 1).padding(.leading, 24).padding(.trailing, 16)
            }
        }
        Spacer().frame(height: 20)
    }

    /// The right-hand column: "Custom Shortcuts" until a row is picked, then that command.
    @ViewBuilder
    private func detail(_ entry: ShortcutEntry?, all: [ShortcutEntry]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let entry {
                Text(entry.title).font(.system(size: 15, weight: .semibold))
                Text(entry.menuPath.joined(separator: " › ")).foregroundStyle(.secondary)
                ShortcutRecorder(
                    shortcut: pending?.id == entry.id ? pending?.shortcut : entry.shortcut,
                    isRecording: recording == entry.id,
                    start: { recording = entry.id; pending = nil },
                    finish: { shortcut in
                        recording = nil
                        guard let shortcut else { return }
                        if ShortcutsList.conflicts(for: shortcut, excluding: entry.id, in: all).isEmpty {
                            model.setShortcut(shortcut, for: entry.id)
                        } else {
                            pending = (entry.id, shortcut)
                        }
                    }
                )
                if let pending, pending.id == entry.id {
                    let conflicts = ShortcutsList.conflicts(for: pending.shortcut, excluding: entry.id, in: all)
                    if let note = ShortcutsList.conflictDescription(conflicts) {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                            Text("\(pending.shortcut.displayString) \(note)").font(.system(size: 12))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Button(conflicts.count == 1 ? "Remove Conflicting Shortcut" : "Remove Conflicting Shortcuts") {
                            model.removeConflicts(with: pending.shortcut, keeping: entry.id)
                            model.setShortcut(pending.shortcut, for: entry.id)
                            self.pending = nil
                        }
                        Button("Cancel") { self.pending = nil }
                    }
                }
                Button("Reset Shortcut to Default") { model.resetShortcut(entry.id) }
                    .disabled(!entry.isCustomized)
                Button("Remove Shortcut") { model.setShortcut(nil, for: entry.id) }
                    .disabled(entry.shortcut == nil)
            } else {
                HStack(spacing: 4) {
                    ArtKey(symbol: "command")
                    ArtKey(symbol: "face.smiling")
                }
                Text("Custom Shortcuts").font(.system(size: 15, weight: .semibold)).padding(.top, 16)
                Text("Change shortcuts for your favorite actions.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

/// A 48pt list row: the command's name and its keycap. Click the row to pick it, the keycap to record.
private struct ShortcutRow: View {
    let entry: ShortcutEntry
    let isSelected: Bool
    let isRecording: Bool
    let pending: KeyShortcut?
    let select: () -> Void
    let startRecording: () -> Void
    let finishRecording: (KeyShortcut?) -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Only the name picks the row, so a click on the keycap records instead.
            HStack {
                Text(entry.title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture(perform: select)
            ShortcutRecorder(shortcut: pending ?? entry.shortcut, isRecording: isRecording, start: startRecording, finish: finishRecording)
        }
        .padding(.leading, 24)
        .padding(.trailing, 24)
        .frame(height: ShortcutsPane.M.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(0.25) : .clear)
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

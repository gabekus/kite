import AppKit
import KiteCore
import SwiftUI

/// Settings → Shortcuts, after Arc 1.169's (wording and structure from its binary; layout not
/// yet measured): an Essential Shortcuts callout, "Custom Shortcuts" with a search field, then
/// Customized and Default sections listing every menu command. Click a shortcut to record a
/// new one; each row's menu resets or removes it. Changes go straight to KeyBindingsStore
/// (keybindings.json) and the menu bar.
struct ShortcutsPane: View {
    @EnvironmentObject private var model: SettingsModel
    @State private var query = ""
    /// The command being recorded, if any.
    @State private var recording: String?
    /// A recorded shortcut that another command already has, waiting for the user to choose.
    @State private var pending: (id: String, shortcut: KeyShortcut)?

    var body: some View {
        let entries = model.shortcutEntries
        let sections = ShortcutsList.sections(entries, query: query)
        SettingsPaneContainer {
            SettingsSection {
                SettingsRow(title: "Start with the basics") {
                    Button("Learn the Essential Shortcuts") {
                        EssentialShortcutsWindow.show(menu: NSApp.mainMenu, overrides: (NSApp.delegate as? AppDelegate)?.keyBindings.bindings)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Custom Shortcuts").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Menu {
                        Button("Reset All Shortcuts") { model.resetAllShortcuts() }
                        Button("Extension Shortcuts…") {}.disabled(true)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Text("Change shortcuts for your favorite actions.")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextField("Type a feature name or shortcut (like “Command E”)", text: $query)
                .textFieldStyle(.roundedBorder)
            if !sections.customized.isEmpty {
                section("Customized Shortcuts", sections.customized, all: entries)
            }
            if !sections.defaults.isEmpty {
                section("Default Shortcuts", sections.defaults, all: entries)
            }
        }
    }

    private func section(_ title: String, _ rows: [ShortcutEntry], all: [ShortcutEntry]) -> some View {
        SettingsSection(header: title) {
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
                if entry.id != rows.last?.id { Divider() }
            }
        }
    }
}

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
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.system(size: 13))
                    Text(entry.menuPath.joined(separator: " › ")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                ShortcutRecorder(shortcut: pending ?? entry.shortcut, isRecording: isRecording, start: startRecording, finish: finishRecording)
                Menu {
                    Button("Reset Shortcut to Default") { model.resetShortcut(entry.id) }
                        .disabled(!entry.isCustomized)
                    Button("Remove Shortcut") { model.setShortcut(nil, for: entry.id) }
                        .disabled(entry.shortcut == nil)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            if let pending, let note = ShortcutsList.conflictDescription(conflicts) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text("\(pending.displayString) \(note)").font(.system(size: 11))
                    Spacer()
                    Button("Cancel") { resolveConflict(false) }.controlSize(.small)
                    Button(conflicts.count == 1 ? "Remove Conflicting Shortcut" : "Remove Conflicting Shortcuts") { resolveConflict(true) }
                        .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 2)
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
            Text(isRecording ? "Type shortcut…" : shortcut?.displayString ?? "—")
                .font(.system(size: 12, weight: .medium))
                .frame(minWidth: 64)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 5).fill(isRecording ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .onChange(of: isRecording) { _, now in now ? install() : remove() }
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

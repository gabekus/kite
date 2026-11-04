import AppKit
import KiteCore

/// Help › Restore Data (Arc's RestoreDataWindowController and RestoreSidebarDataFlow): pick one of
/// session.json's backups, see whether it can be restored, and Restore swaps it in. Arc's window is
/// titled "Restore Data", says "Backup can be restored" or "Backup cannot be restored" for the
/// picked file and finishes with a Restore button. Arc also picks which data to restore; Kite has
/// one session, so that choice is left out. The state being replaced is kept as a backup first.
@MainActor
final class RestoreDataWindow: NSObject, NSWindowDelegate {
    private static var shared: RestoreDataWindow?

    static func show(store: BrowserStore, backups: SessionBackups) {
        let restore = shared ?? RestoreDataWindow(store: store, backups: backups)
        shared = restore
        restore.reload()
        if UIDiagnostics.enabledByEnvironment {
            // Test runs stay behind the user's windows.
            restore.window.orderBack(nil)
        } else {
            restore.window.makeKeyAndOrderFront(nil)
        }
    }

    private let window: NSWindow
    private let store: BrowserStore
    private let backups: SessionBackups
    private let filePopUp = NSPopUpButton()
    private let statusLabel = NSTextField(labelWithString: "")
    private let restoreButton = NSButton(title: "Restore", target: nil, action: nil)
    private var summaries: [SessionBackups.Summary] = []

    private init(store: BrowserStore, backups: SessionBackups) {
        self.store = store
        self.backups = backups
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        super.init()
        window.title = "Restore Data"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        filePopUp.target = self
        filePopUp.action = #selector(fileChanged(_:))
        filePopUp.setAccessibilityIdentifier("restoreDataBackup")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.setAccessibilityIdentifier("restoreDataStatus")
        restoreButton.target = self
        restoreButton.action = #selector(restore(_:))
        restoreButton.keyEquivalent = "\r"
        restoreButton.bezelStyle = .push
        restoreButton.setAccessibilityIdentifier("restoreDataRestore")

        let stack = NSStackView(views: [filePopUp, statusLabel, restoreButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.setCustomSpacing(16, after: statusLabel)
        filePopUp.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        window.contentView = stack
    }

    private func reload() {
        summaries = backups.all().map(backups.summary(of:))
        filePopUp.removeAllItems()
        let dates = DateFormatter()
        dates.dateStyle = .medium
        dates.timeStyle = .short
        for summary in summaries {
            // Through the menu: addItem(withTitle:) drops a title already there, and two backups can share a minute.
            filePopUp.menu?.addItem(NSMenuItem(title: Self.title(summary, dates: dates), action: nil, keyEquivalent: ""))
        }
        if summaries.isEmpty { filePopUp.addItem(withTitle: "No Backups") }
        update()
    }

    /// "Nov 4, 2026 at 10:20 AM — 3 spaces, 12 tabs".
    private static func title(_ summary: SessionBackups.Summary, dates: DateFormatter) -> String {
        let date = dates.string(from: summary.backup.date)
        guard let spaces = summary.spaceCount, let tabs = summary.tabCount else { return "\(date) — unreadable" }
        return "\(date) — \(spaces) \(spaces == 1 ? "space" : "spaces"), \(tabs) \(tabs == 1 ? "tab" : "tabs")"
    }

    private var selected: SessionBackups.Summary? {
        let index = filePopUp.indexOfSelectedItem
        return summaries.indices.contains(index) ? summaries[index] : nil
    }

    private func update() {
        filePopUp.isEnabled = !summaries.isEmpty
        guard let selected else {
            statusLabel.stringValue = ""
            restoreButton.isEnabled = false
            return
        }
        // Arc's wording, for the file picked.
        statusLabel.stringValue = selected.isRestorable ? "Backup can be restored" : "Backup cannot be restored"
        restoreButton.isEnabled = selected.isRestorable
    }

    @objc private func fileChanged(_ sender: Any?) { update() }

    @objc private func restore(_ sender: Any?) {
        guard let selected, selected.isRestorable else { return }
        do {
            try store.restoreSession(from: selected.backup)
            window.close()
        } catch {
            NSLog("Kite: couldn't restore backup: \(error)")
            statusLabel.stringValue = "Backup cannot be restored"
            restoreButton.isEnabled = false
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.shared = nil
    }
}

import AppKit
import KiteCore

/// Spool: Gabe's Mac app that runs a Claude Code session per Linear ticket, at `spool://ticket/<KEY-123>`.
enum Spool {
    /// Only while an app handles the spool scheme.
    static var isInstalled: Bool {
        NSWorkspace.shared.urlForApplication(toOpen: LinearTicket(key: "PRO-1").spoolURL) != nil
    }

    static func open(_ ticket: LinearTicket) {
        NSWorkspace.shared.open(ticket.spoolURL)
    }
}

extension BrowserWindowController {
    /// The Linear issue in the front tab, if it shows one.
    var frontTicket: LinearTicket? { LinearTicket(url: store.state.selectedTab?.url) }

    /// Kite menu → Test This Ticket (and the ⌘J bar's button): Claude tests the front tab's Linear ticket.
    @objc func testThisTicket(_ sender: Any?) {
        guard let ticket = frontTicket, let tasks = claudeBubble.tasks else { return }
        guard tasks.isSetUp else { return claudeButton.open() }
        claudeBubble.testTicket(ticket, tasks: tasks)
    }

    /// Kite menu → Open in Spool (and the ⌘J bar's button): the front tab's ticket in Spool.
    @objc func openInSpool(_ sender: Any?) {
        guard let ticket = frontTicket else { return }
        Spool.open(ticket)
    }

    /// Both show only on a Linear issue; Open in Spool also only while Spool is installed.
    func validateTicketItem(_ item: NSMenuItem) -> Bool? {
        switch item.action {
        case #selector(testThisTicket(_:)):
            item.isHidden = frontTicket == nil || claudeBubble.tasks == nil
        case #selector(openInSpool(_:)):
            item.isHidden = frontTicket == nil || !Spool.isInstalled
        default:
            return nil
        }
        return !item.isHidden
    }
}

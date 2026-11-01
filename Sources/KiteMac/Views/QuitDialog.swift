import AppKit
import SwiftUI

/// Arc 1.169's quit dialogs, both its own SwiftUI windows on a clear background (not NSAlerts).
///
/// - "Quit Kite?", the warn-before-quitting dialog: the title "Quit <app>?" with no message,
///   and three buttons: Quit, "Quit, and don’t ask again" and Cancel.
/// - "Downloads in progress", shown when quitting with downloads still running: the message
///   "There are downloads in progress. Closing the application will cancel them." and two
///   buttons, "Close <app>" and "Keep browsing" (docs/arc-visual-spec.md, "Downloads in progress").
///
/// Arc's look hasn't been measured yet (its warning is off on the dev Mac), so the layout
/// follows a macOS alert: icon, bold title, optional message, stacked buttons.
@MainActor
enum QuitDialog {
    enum Choice { case quit, quitAndDontAskAgain, cancel }

    /// The warn-before-quitting dialog over `window` (or mid-screen); waits for a choice.
    static func run(over window: NSWindow?) -> Choice {
        present(title: "Quit \(appName)?", message: nil, buttons: [
            Button(title: "Quit", choice: .quit, shortcut: .defaultAction),
            Button(title: "Quit, and don’t ask again", choice: .quitAndDontAskAgain, shortcut: nil),
            Button(title: "Cancel", choice: .cancel, shortcut: .cancelAction),
        ], over: window)
    }

    /// "Downloads in progress": true when the user picks Close Kite, false for Keep browsing.
    static func runDownloadsInProgress(over window: NSWindow?) -> Bool {
        present(title: "Downloads in progress",
                message: "There are downloads in progress. Closing the application will cancel them.",
                buttons: [
                    Button(title: "Close \(appName)", choice: .quit, shortcut: .defaultAction),
                    Button(title: "Keep browsing", choice: .cancel, shortcut: .cancelAction),
                ], over: window) == .quit
    }

    static var appName: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Kite" }

    struct Button: Identifiable {
        let title: String
        let choice: Choice
        let shortcut: KeyboardShortcut?
        var id: String { title }
    }

    private static func present(title: String, message: String?, buttons: [Button], over window: NSWindow?) -> Choice {
        let panel = DialogWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: M.width, height: 200)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.isReleasedWhenClosed = false
        var choice = Choice.cancel
        let host = NSHostingView(rootView: QuitDialogView(title: title, message: message, buttons: buttons) { picked in
            choice = picked
            NSApp.stopModal()
        })
        let size = NSSize(width: M.width, height: ceil(host.fittingSize.height))
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(size)
        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return choice
    }

    /// Borderless windows can't become key unless they say so, and the buttons need key. A window, not
    /// an NSPanel: a panel hides while Kite isn't active, and a quit from the Dock or a logout reaches
    /// "Downloads in progress" with Kite in the background.
    private final class DialogWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }
}

private enum M {
    static let width: CGFloat = 260
    static let cornerRadius: CGFloat = 12
    static let iconSize: CGFloat = 64
    static let buttonHeight: CGFloat = 28
}

private struct QuitDialogView: View {
    let title: String
    let message: String?
    let buttons: [QuitDialog.Button]
    let choose: (QuitDialog.Choice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: M.iconSize, height: M.iconSize)
                .padding(.top, 20)
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .multilineTextAlignment(.center)
                .padding(.top, 10)
            if let message {
                Text(message)
                    .font(.system(size: 11))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                    .padding(.horizontal, 16)
            }
            VStack(spacing: 8) {
                ForEach(buttons) { button in
                    row(button)
                }
            }
            .padding(.top, 16)
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: M.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
    }

    @ViewBuilder
    private func row(_ button: QuitDialog.Button) -> some View {
        let base = SwiftUI.Button { choose(button.choice) } label: {
            Text(button.title).frame(maxWidth: .infinity, minHeight: M.buttonHeight - 8)
        }
        .controlSize(.large)
        if let shortcut = button.shortcut { base.keyboardShortcut(shortcut) } else { base }
    }
}

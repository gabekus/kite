import AppKit
import SwiftUI

/// "Quit Kite?", Arc 1.169's warn-before-quitting dialog. From Arc's binary: its own
/// SwiftUI window on a clear background (not an NSAlert), the title "Quit <app>?" with
/// no message, and three buttons: Quit, "Quit, and don’t ask again" and Cancel.
/// Arc's look hasn't been measured yet (its warning is off on the dev Mac), so the
/// layout follows a macOS alert: icon, bold title, stacked buttons.
@MainActor
enum QuitDialog {
    enum Choice { case quit, quitAndDontAskAgain, cancel }

    /// Shows the dialog over `window` (or mid-screen) and waits for a choice.
    static func run(over window: NSWindow?) -> Choice {
        let panel = Panel(
            contentRect: NSRect(origin: .zero, size: M.size),
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
        let host = NSHostingView(rootView: QuitDialogView { picked in
            choice = picked
            NSApp.stopModal()
        })
        host.sizingOptions = []
        panel.contentView = host
        panel.setContentSize(M.size)
        let area = window?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(NSPoint(x: area.midX - M.size.width / 2, y: area.midY - M.size.height / 2))
        panel.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: panel)
        panel.orderOut(nil)
        return choice
    }

    /// Borderless windows can't become key unless they say so, and the buttons need key.
    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
    }
}

private enum M {
    static let size = NSSize(width: 260, height: 252)
    static let cornerRadius: CGFloat = 12
    static let iconSize: CGFloat = 64
    static let buttonHeight: CGFloat = 28
}

private struct QuitDialogView: View {
    let choose: (QuitDialog.Choice) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: M.iconSize, height: M.iconSize)
                .padding(.top, 20)
            Text("Quit \(Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "Kite")?")
                .font(.system(size: 13, weight: .bold))
                .padding(.top, 10)
            Spacer(minLength: 16)
            VStack(spacing: 8) {
                button("Quit", .quit)
                    .keyboardShortcut(.defaultAction)
                button("Quit, and don’t ask again", .quitAndDontAskAgain)
                button("Cancel", .cancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding([.horizontal, .bottom], 16)
        }
        .frame(width: M.size.width, height: M.size.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous))
    }

    private func button(_ title: String, _ choice: QuitDialog.Choice) -> some View {
        Button { choose(choice) } label: {
            Text(title).frame(maxWidth: .infinity, minHeight: M.buttonHeight - 8)
        }
        .controlSize(.large)
    }
}

import AppKit
import KiteCore
import SwiftUI

/// Help → Essential Keyboard Shortcuts, matching Arc 1.169's floating cheat sheet
/// (measured on the Mac): five fixed commands with their current shortcuts as
/// blue keycaps, and "View All" for the full list.
@MainActor
enum EssentialShortcutsWindow {
    private static var window: NSWindow?

    /// Arc's fixed list. `action` is the menu item's ID, so remapped shortcuts show as remapped.
    static let rows: [(action: String, title: String, subtitle: String)] = [
        ("newTab", "Open a New Tab", "Open the Command Bar to create a new tab"),
        ("nextRecentTabItem", "Switch to a Recent Tab", "Hold this to quickly switch between recent tabs"),
        ("copyCurrentURL", "Copy Page URL", "Copy the current tab's URL without trackers"),
        ("addSplitView", "Add Split View", "View multiple websites side-by-side"),
        ("openLittleArc", "Open Little Arc", "Use a smaller browser window for quick searches"),
    ]

    static func show(menu: NSMenu?, overrides: KeyBindings?) {
        let window = window ?? makeWindow()
        self.window = window
        let keys = rows.map { shortcut(for: $0.action, menu: menu, overrides: overrides) }
        window.contentView = NSHostingView(rootView: EssentialShortcutsView(keys: keys) {
            ShortcutsWindow.show(for: NSApp.mainMenu)
        })
        if let screen = NSScreen.main {
            // Top-right of the screen, just under the menu bar.
            let visible = screen.visibleFrame
            window.setFrameTopLeftPoint(NSPoint(x: visible.maxX - M.size.width, y: visible.maxY))
        }
        window.makeKeyAndOrderFront(nil)
    }

    /// The command's shortcut now: its menu item's, or an override for a command Kite doesn't have yet.
    private static func shortcut(for action: String, menu: NSMenu?, overrides: KeyBindings?) -> KeyShortcut? {
        if let item = menu.flatMap({ find(action, in: $0) }) { return item.shortcut }
        return overrides?.override(for: action)?.shortcut
    }

    private static func find(_ action: String, in menu: NSMenu) -> NSMenuItem? {
        for item in menu.items {
            if item.identifier?.rawValue == action { return item }
            if let found = item.submenu.flatMap({ find(action, in: $0) }) { return found }
        }
        return nil
    }

    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: M.size),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Essential Keyboard Shortcuts"
        window.standardWindowButton(.zoomButton)?.isEnabled = false
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(srgbRed: 0x1E / 255, green: 0x26 / 255, blue: 0x3D / 255, alpha: 1)
        return window
    }
}

/// Arc 1.169's measurements, in points from the window's top-left.
private enum M {
    static let size = NSSize(width: 475, height: 458)
    static let leading: CGFloat = 31
    static let trailing: CGFloat = 30
    static let headingTop: CGFloat = 56
    static let headingSize: CGFloat = 23
    static let buttonSize = CGSize(width: 87, height: 22)
    static let buttonTrailing: CGFloat = 31
    static let buttonFill = Color(red: 0x63 / 255, green: 0x68 / 255, blue: 0x76 / 255)
    static let buttonHighlight = Color(red: 0x9D / 255, green: 0xA0 / 255, blue: 0xA9 / 255)
    // Not measured yet: where the first row starts.
    static let firstRowTop: CGFloat = 92
    static let rowPitch: CGFloat = 73
    static let titleSize: CGFloat = 16
    static let subtitleSize: CGFloat = 13
    static let titleToSubtitle: CGFloat = 22
    static let subtitleColor = Color(red: 0xC4 / 255, green: 0xC5 / 255, blue: 0xCD / 255)
    static let separator = Color(red: 0x2D / 255, green: 0x34 / 255, blue: 0x48 / 255)
    static let separatorWidth: CGFloat = 413
    static let keySize = CGSize(width: 27.5, height: 28)
    static let keySpacing: CGFloat = 3.5
    static let keyCornerRadius: CGFloat = 5
    static let keyLip: CGFloat = 3.5
    static let keyFontSize: CGFloat = 14
    static let keyTop = Color(red: 0xC2 / 255, green: 0xD4 / 255, blue: 0xF4 / 255)
    static let keyBottom = Color(red: 0xAC / 255, green: 0xC5 / 255, blue: 0xEB / 255)
    static let keyBlue = Color(red: 0x41 / 255, green: 0x8F / 255, blue: 0xF9 / 255)
    static let keyLipColor = Color(red: 0x37 / 255, green: 0x77 / 255, blue: 0xD0 / 255)
}

private struct EssentialShortcutsView: View {
    let keys: [KeyShortcut?]
    let viewAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                Text("Essential Keyboard Shortcuts")
                    .font(.system(size: M.headingSize, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                Button(action: viewAll) {
                    HStack(spacing: 4) {
                        Text("View All")
                        Image(systemName: "arrow.up.right")
                    }
                    .font(.system(size: 14))
                    .foregroundStyle(.white)
                    .frame(width: M.buttonSize.width, height: M.buttonSize.height)
                    .background(M.buttonFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(alignment: .top) {
                        // Arc's 1px lighter top edge.
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .stroke(M.buttonHighlight, lineWidth: 1)
                            .mask(alignment: .top) { Rectangle().frame(height: 2) }
                    }
                }
                .buttonStyle(.plain)
                .padding(.trailing, M.buttonTrailing - M.trailing)
            }
            .padding(.top, M.headingTop)
            .frame(height: M.firstRowTop, alignment: .top)

            ForEach(Array(EssentialShortcutsWindow.rows.enumerated()), id: \.offset) { index, row in
                VStack(alignment: .leading, spacing: 0) {
                    if index > 0 {
                        M.separator.frame(width: M.separatorWidth, height: 1)
                    }
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title)
                                .font(.system(size: M.titleSize))
                                .foregroundStyle(.white)
                                .frame(height: M.titleToSubtitle, alignment: .topLeading)
                            Text(row.subtitle)
                                .font(.system(size: M.subtitleSize))
                                .foregroundStyle(M.subtitleColor)
                        }
                        Spacer(minLength: 8)
                        Keycaps(shortcut: keys[index])
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: M.rowPitch)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, M.leading)
        .padding(.trailing, M.trailing)
        .frame(width: M.size.width, height: M.size.height, alignment: .topLeading)
        .ignoresSafeArea()
    }
}

/// One blue 3D keycap per modifier, then the key.
private struct Keycaps: View {
    let shortcut: KeyShortcut?

    var body: some View {
        HStack(spacing: M.keySpacing) {
            if let shortcut {
                ForEach(shortcut.modifiers, id: \.self) { Keycap(label: $0.symbol) }
                Keycap(label: label(for: shortcut.key))
            }
        }
    }

    /// Arrows as symbols, other named keys spelled out ("TAB").
    private func label(for key: String) -> String {
        ["left", "right", "up", "down"].contains(key) ? KeyShortcut.namedKeys[key] ?? key : key.uppercased()
    }
}

private struct Keycap: View {
    let label: String

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: M.keyCornerRadius, style: .continuous)
        Text(label)
            // Named keys ("TAB") are a smaller size, as in Arc.
            .font(.system(size: label.count > 1 ? M.keyFontSize - 5 : M.keyFontSize, weight: .semibold))
            .foregroundStyle(M.keyBlue)
            .frame(minWidth: M.keySize.width)
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .frame(height: M.keySize.height - M.keyLip)
            .background(LinearGradient(colors: [M.keyTop, M.keyBottom], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(alignment: .top) {
                // White highlight along the top of the face.
                shape.stroke(.white.opacity(0.8), lineWidth: 1).mask(alignment: .top) { Rectangle().frame(height: 3) }
            }
            .padding(.bottom, M.keyLip)
            .background(M.keyLipColor, in: shape)
            .overlay(shape.strokeBorder(M.keyBlue, lineWidth: 1))
    }
}

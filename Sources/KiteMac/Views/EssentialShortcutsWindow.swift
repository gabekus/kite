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
        let host = NSHostingView(rootView: EssentialShortcutsView(keys: keys) {
            ShortcutsWindow.show(for: NSApp.mainMenu)
        })
        // Otherwise the window grows to fit the content below the titlebar.
        host.sizingOptions = []
        window.contentView = host
        // The frame, titlebar included, is Arc's 475x458; the content runs under the titlebar.
        window.setFrame(NSRect(origin: window.frame.origin, size: M.size), display: false)
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
        // Captures as Arc's #1E263D.
        window.backgroundColor = NSColor(displayP3Red: 0x15 / 255, green: 0x19 / 255, blue: 0x2C / 255, alpha: 1)
        return window
    }
}

/// Arc 1.169's measurements, in points from the window's top-left. Text positions are
/// where the capitals' tops land. Colours are Display P3, tuned so a capture of Kite
/// reads Arc's values (noted beside each).
private enum M {
    static let size = NSSize(width: 475, height: 458)
    static let leading: CGFloat = 31
    static let trailing: CGFloat = 30
    static let headingCapTop: CGFloat = 56
    static let headingSize: CGFloat = 19.5
    static let buttonTop: CGFloat = 54
    static let buttonSize = CGSize(width: 87, height: 22)
    static let buttonTrailing: CGFloat = 31
    static let buttonFill = Color(red: 0x63 / 255, green: 0x68 / 255, blue: 0x76 / 255)
    static let buttonHighlight = Color(red: 0x9D / 255, green: 0xA0 / 255, blue: 0xA9 / 255)
    static let firstTitleCapTop: CGFloat = 98
    static let rowPitch: CGFloat = 73
    /// The first separator, 50 under the first title; then one every row.
    static let firstSeparator: CGFloat = 148
    static let titleSize: CGFloat = 15
    static let subtitleSize: CGFloat = 11.5
    static let titleToSubtitle: CGFloat = 20
    static let subtitleColor = p3(0xBA, 0xBB, 0xC4) // #C4C5CD
    static let separator = p3(0x1F, 0x24, 0x36) // #2D3448
    static let separatorWidth: CGFloat = 413
    static let keySize = CGSize(width: 27.5, height: 28.5)
    /// The keycaps' top relative to the title's capitals.
    static let keyRaise: CGFloat = 0.5
    static let keySpacing: CGFloat = 3.5
    static let keyCornerRadius: CGFloat = 5
    static let keyLip: CGFloat = 3.5
    static let keyFontSize: CGFloat = 14
    static let keyTop = p3(0xBA, 0xCD, 0xF2) // #C2D4F4
    static let keyBottom = p3(0x97, 0xB5, 0xE4) // #ACC5EB
    static let keyBlue = p3(0x32, 0x7B, 0xF7) // #418FF9
    static let keyLipTop = p3(0x1F, 0x50, 0xA9) // #3778D0
    static let keyLipBottom = p3(0x2A, 0x66, 0xC8) // #418FF9 with the border

    /// Where a line of SF text's frame starts for its capitals to start at `capTop`.
    static func textTop(capTop: CGFloat, size: CGFloat) -> CGFloat { capTop - size * 0.25 }

    static func p3(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(.displayP3, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255)
    }
}

private struct EssentialShortcutsView: View {
    let keys: [KeyShortcut?]
    let viewAll: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Text("Essential Keyboard Shortcuts")
                .font(.system(size: M.headingSize, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .fixedSize()
                .offset(x: M.leading, y: M.textTop(capTop: M.headingCapTop, size: M.headingSize))

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
            .focusEffectDisabled()
            .offset(x: M.size.width - M.buttonTrailing - M.buttonSize.width, y: M.buttonTop)

            ForEach(Array(EssentialShortcutsWindow.rows.enumerated()), id: \.offset) { index, row in
                let capTop = M.firstTitleCapTop + CGFloat(index) * M.rowPitch
                Text(row.title)
                    .font(.system(size: M.titleSize))
                    .foregroundStyle(.white)
                    .offset(x: M.leading, y: M.textTop(capTop: capTop, size: M.titleSize))
                Text(row.subtitle)
                    .font(.system(size: M.subtitleSize))
                    .foregroundStyle(M.subtitleColor)
                    .offset(x: M.leading, y: M.textTop(capTop: capTop + M.titleToSubtitle, size: M.subtitleSize))
                Keycaps(shortcut: keys[index])
                    .frame(width: M.size.width - M.trailing, alignment: .trailing)
                    .offset(y: capTop - M.keyRaise)
                if index > 0 {
                    M.separator
                        .frame(width: M.separatorWidth, height: 1)
                        .offset(x: M.leading, y: M.firstSeparator + CGFloat(index - 1) * M.rowPitch)
                }
            }
        }
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
            .padding(.horizontal, label.count > 1 ? 4 : 0)
            .frame(minWidth: M.keySize.width)
            .frame(height: M.keySize.height - M.keyLip)
            .background(LinearGradient(colors: [M.keyTop, M.keyBottom], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(alignment: .top) {
                // White highlight along the top of the face.
                shape.stroke(.white.opacity(0.8), lineWidth: 1).mask(alignment: .top) { Rectangle().frame(height: 3) }
            }
            .padding(.bottom, M.keyLip)
            .background(LinearGradient(colors: [M.keyLipTop, M.keyLipBottom], startPoint: .top, endPoint: .bottom), in: shape)
            .overlay(shape.strokeBorder(M.keyBlue, lineWidth: 1))
    }
}

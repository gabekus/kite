import AppKit
import SwiftUI

/// The name pill over a space's icon in the bar, in a window of its own as Arc's is
/// (`SidebarDockItemTooltipView`; on 1 Nov 2026 its window reached past the browser window's left edge,
/// the pill centred on the icon, 2pt above it). Drawn inside the sidebar, a wide pill over the first
/// icon was cut off at the window's edge.
@MainActor
final class SpaceTipWindow {
    static let shared = SpaceTipWindow()

    private var panel: NSPanel?
    private var owner: UUID?

    /// Shows `tip` centred over `anchor` (the icon's cell), `gap` points above it.
    func show(_ tip: some View, for id: UUID, above anchor: NSView, gap: CGFloat) {
        guard let parent = anchor.window, parent.isVisible else { return }
        let panel = panel ?? makePanel()
        self.panel = panel
        let host = NSHostingView(rootView: AnyView(tip.fixedSize()))
        panel.contentView = host
        let size = host.fittingSize
        let cell = parent.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        panel.setFrame(NSRect(x: (cell.midX - size.width / 2).rounded(), y: cell.maxY + gap,
                              width: size.width, height: size.height), display: true)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        owner = id
        panel.alphaValue = 0
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    /// Hides the pill if it's `id`'s (another icon may have taken it over already).
    func hide(_ id: UUID) {
        guard owner == id, let panel else { return }
        owner = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        return panel
    }
}

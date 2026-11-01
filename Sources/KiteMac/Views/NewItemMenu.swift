import AppKit
import KiteCore
import SwiftUI

/// Arc's + menu in the bottom bar: a popover over the button with New Space and New Folder, then New
/// Split and New Tab with their shortcuts (Arc 1.169's tree and a capture, 1 Nov 2026: 222×308 with
/// 40pt rows inset 14, icons then titles at 39 in, shortcuts at the right end, a line between groups).
/// Arc's New Easel and New Boost are left out: Kite has neither.
struct NewItemMenu: View {
    private typealias M = ArcMetrics.NewItemMenu
    let store: BrowserStore
    let actions: SidebarActions
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            item("New Space", symbol: "plus.square.on.square") { store.beginNewSpace() }
            item("New Folder", symbol: "folder") {
                let index = store.state.selectedSpaceIndex
                store.mutate { _ = $0.createFolder(name: "New Folder", inSpace: index) }
            }
            divider
            item("New Split", symbol: "rectangle.split.2x1", shortcut: "⌘L", action: actions.addSplitView)
            item("New Tab", symbol: "plus.square", shortcut: "⌘T") { store.showCommandBar(.newTab) }
        }
        .padding(M.inset)
        .frame(width: M.width)
    }

    private var divider: some View {
        Rectangle().fill(.primary.opacity(0.15)).frame(height: 1)
            .padding(.horizontal, M.dividerInset)
            .frame(height: M.dividerHeight)
    }

    private func item(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        MenuRow(title: title, symbol: symbol, shortcut: shortcut) {
            close()
            action()
        }
    }
}

private struct MenuRow: View {
    private typealias M = ArcMetrics.NewItemMenu
    let title: String
    let symbol: String
    let shortcut: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 0) {
                Image(systemName: symbol)
                    .font(.system(size: 16))
                    .frame(width: M.iconWidth)
                    .padding(.leading, M.iconX)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .padding(.leading, M.textX - M.iconX - M.iconWidth)
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut).font(.system(size: 13)).opacity(0.5).padding(.trailing, 12)
                }
            }
            .frame(height: M.rowHeight)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(hovering ? 0.8 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

extension NewItemMenu {
    @MainActor
    static func present(from view: NSView, store: BrowserStore, actions: SidebarActions) {
        shown?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        weak var weakPopover = popover
        popover.contentViewController = NSHostingController(rootView: NewItemMenu(store: store, actions: actions) {
            weakPopover?.close()
        })
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .maxY)
        shown = popover
    }

    @MainActor private static weak var shown: NSPopover?
}

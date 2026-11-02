import AppKit
import SwiftUI

/// Hands SwiftUI's backing NSView to code that anchors AppKit popovers to it.
struct AnchorView: NSViewRepresentable {
    @Binding var view: NSView?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.view = view }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

/// Keeps a press on the views in front of it from moving the window. The browser window is movable
/// by its background, and the window server starts that move itself on a real press anywhere AppKit
/// marks draggable, before SwiftUI sees it: a favorite tile has to opt out to be dragged (Arc's
/// favorites are an `NSCollectionView`, which never moves the window). It takes no clicks itself.
struct NoWindowDrag: NSViewRepresentable {
    final class View: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView { View() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

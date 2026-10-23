import AppKit
import KiteCore
import ObjectiveC

/// `ui pointer`: what the pointer would meet at each point, without moving the real one.
///
/// At each point it hit-tests the window, lists the cursor rects and tracking areas there,
/// sends a synthetic mouse-moved event to the window, and works out the cursor Kite sets:
/// the topmost cursor rect's cursor, else what the topmost cursor-update area's owner sets.
/// Screenshots can't show any of this, which is why sweeps used to need the real pointer.
@MainActor
struct UIPointerProbe {
    let window: NSWindow

    func sweep(_ points: [UIPoint]) -> [UIPointerSample] {
        let paths = UITreeBuilder.paths(in: window)
        let cursorRects = CursorRectRecorder.rects(in: window)
        let areas = trackingAreas(paths: paths)
        let samples = points.map { point -> UIPointerSample in
            let base = window.basePoint(point)
            move(to: base)
            let hit = hitView(at: base)
            let rectsHere = cursorRects.filter { $0.rect.contains(base) }
            let areasHere = areas.filter { $0.rect.contains(base) }
            let cursor: String
            if let top = rectsHere.last {
                cursor = top.cursorName
            } else if let area = areasHere.last(where: { $0.area.options.contains(.cursorUpdate) }), area.isActive(in: window) {
                cursor = Self.cursorSet(by: area.area, at: base, in: window) + " (cursorUpdate)"
            } else {
                cursor = "arrow (default)"
            }
            return UIPointerSample(
                point: point,
                hit: hit.map { "\(paths[ObjectIdentifier($0)] ?? "titlebar") \(UIFormat.className($0))" },
                cursorRects: rectsHere.map { "\($0.owner) \($0.cursorName) [\(window.uiRect($0.rect).description)]" },
                trackingAreas: areasHere.map(\.summary),
                cursor: cursor
            )
        }
        return samples
    }

    private func hitView(at base: NSPoint) -> NSView? {
        guard let content = window.contentView, let frameView = content.superview ?? window.contentView else { return nil }
        return frameView.hitTest(frameView.convert(base, from: nil))
    }

    /// A mouse-moved event straight to the window: hover handlers and tracking areas see it,
    /// the window server and the real pointer don't.
    private func move(to base: NSPoint) {
        guard let event = NSEvent.mouseEvent(
            with: .mouseMoved, location: base, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0
        ) else { return }
        window.sendEvent(event)
    }

    // MARK: Tracking areas

    struct Area {
        let area: NSTrackingArea
        let rect: NSRect
        let summary: String

        /// Areas limited to the key window or the active app don't fire while Kite is in the background.
        func isActive(in window: NSWindow) -> Bool {
            if area.options.contains(.activeAlways) { return true }
            if area.options.contains(.activeInActiveApp) { return NSApp.isActive }
            return window.isKeyWindow && NSApp.isActive
        }
    }

    private func trackingAreas(paths: [ObjectIdentifier: String]) -> [Area] {
        var result: [Area] = []
        func visit(_ view: NSView) {
            guard !view.isHidden else { return }
            for area in view.trackingAreas {
                let local = area.options.contains(.inVisibleRect) ? view.visibleRect : area.rect
                let rect = view.convert(local, to: nil)
                let owner = area.owner.map { UIFormat.className($0 as AnyObject) } ?? "?"
                let path = paths[ObjectIdentifier(view)] ?? "titlebar"
                var options = Self.names(area.options)
                let active = Area(area: area, rect: rect, summary: "").isActive(in: window)
                if !active { options += ",INACTIVE NOW" }
                result.append(Area(area: area, rect: rect,
                                   summary: "\(path) \(UIFormat.className(view)) owner \(owner) \(options) [\(window.uiRect(rect).description)]"))
            }
            if !UIFormat.isWebContent(view) { view.subviews.forEach(visit) }
        }
        if let frameView = window.contentView?.superview ?? window.contentView { visit(frameView) }
        return result
    }

    static func names(_ options: NSTrackingArea.Options) -> String {
        let all: [(NSTrackingArea.Options, String)] = [
            (.mouseEnteredAndExited, "enteredExited"), (.mouseMoved, "moved"), (.cursorUpdate, "cursorUpdate"),
            (.activeWhenFirstResponder, "whenFirstResponder"), (.activeInKeyWindow, "inKeyWindow"),
            (.activeInActiveApp, "inActiveApp"), (.activeAlways, "always"), (.assumeInside, "assumeInside"),
            (.inVisibleRect, "visibleRect"), (.enabledDuringMouseDrag, "duringDrag"),
        ]
        return all.filter { options.contains($0.0) }.map(\.1).joined(separator: ",")
    }

    /// Asks the area's owner to set its cursor for a synthetic event at the point, and names
    /// what it set. The real cursor only changes if Kite is in front with the pointer over it.
    static func cursorSet(by area: NSTrackingArea, at base: NSPoint, in window: NSWindow) -> String {
        guard let owner = area.owner as? NSResponder,
              let event = NSEvent.mouseEvent(
                with: .mouseMoved, location: base, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 0, pressure: 0) else {
            return "unknown"
        }
        let before = NSCursor.current
        NSCursor.arrow.set()
        owner.cursorUpdate(with: event)
        let name = CursorNames.name(of: NSCursor.current)
        before.set()
        return name
    }
}

// MARK: Cursor rects

/// Records every `addCursorRect(_:cursor:)` while asked, by swapping in a recording copy of
/// NSView's method once (only after Diagnostics for Claude is used). AppKit keeps cursor rects
/// to itself, so this is the only way to read them back.
@MainActor
enum CursorRectRecorder {
    struct Entry {
        let owner: String
        /// Window base coordinates, already clipped to the view's visible rect.
        let rect: NSRect
        let cursorName: String
    }

    private static var installed = false
    fileprivate static var recording: [Entry]?

    static func rects(in window: NSWindow) -> [Entry] {
        install()
        recording = []
        // Clears the window's cursor rects and has every view add its own again, right now.
        window.resetCursorRects()
        let entries = recording ?? []
        recording = nil
        return entries
    }

    private static func install() {
        guard !installed,
              let original = class_getInstanceMethod(NSView.self, #selector(NSView.addCursorRect(_:cursor:))),
              let recorder = class_getInstanceMethod(NSView.self, #selector(NSView.kite_recordingAddCursorRect(_:cursor:)))
        else { return }
        method_exchangeImplementations(original, recorder)
        installed = true
    }

    fileprivate static func record(_ view: NSView, _ rect: NSRect, _ cursor: NSCursor) {
        guard recording != nil, !view.isHiddenOrHasHiddenAncestor else { return }
        let visible = rect.intersection(view.visibleRect)
        guard !visible.isEmpty else { return }
        recording?.append(Entry(owner: UIFormat.className(view), rect: view.convert(visible, to: nil),
                                cursorName: CursorNames.name(of: cursor)))
    }
}

extension NSView {
    /// After the exchange this runs as `addCursorRect(_:cursor:)`, and calling itself calls AppKit's.
    @objc dynamic func kite_recordingAddCursorRect(_ rect: NSRect, cursor: NSCursor) {
        MainActor.assumeIsolated { CursorRectRecorder.record(self, rect, cursor) }
        kite_recordingAddCursorRect(rect, cursor: cursor)
    }
}

/// Names AppKit's standard cursors, by identity or else by image and hot spot.
@MainActor
enum CursorNames {
    private static let known: [(String, NSCursor)] = {
        var list: [(String, NSCursor)] = [
            ("arrow", .arrow), ("iBeam", .iBeam), ("pointingHand", .pointingHand), ("resizeLeftRight", .resizeLeftRight),
            ("resizeLeft", .resizeLeft), ("resizeRight", .resizeRight), ("resizeUpDown", .resizeUpDown), ("resizeUp", .resizeUp),
            ("resizeDown", .resizeDown), ("crosshair", .crosshair), ("openHand", .openHand), ("closedHand", .closedHand),
            ("operationNotAllowed", .operationNotAllowed), ("disappearingItem", .disappearingItem), ("dragLink", .dragLink),
            ("dragCopy", .dragCopy), ("contextualMenu", .contextualMenu), ("iBeamVertical", .iBeamCursorForVerticalLayout),
        ]
        if #available(macOS 15.0, *) {
            list += [("columnResize", .columnResize), ("rowResize", .rowResize), ("zoomIn", .zoomIn), ("zoomOut", .zoomOut)]
            for (position, name) in [(NSCursor.FrameResizePosition.left, "Left"), (.right, "Right"), (.top, "Top"), (.bottom, "Bottom"),
                                     (.topLeft, "TopLeft"), (.topRight, "TopRight"), (.bottomLeft, "BottomLeft"), (.bottomRight, "BottomRight")] {
                list.append(("frameResize\(name)", .frameResize(position: position, directions: .all)))
                list.append(("frameResize\(name)Inward", .frameResize(position: position, directions: .inward)))
                list.append(("frameResize\(name)Outward", .frameResize(position: position, directions: .outward)))
            }
            list.append(("columnResizeLeft", .columnResize(directions: .left)))
            list.append(("columnResizeRight", .columnResize(directions: .right)))
        }
        return list
    }()

    private static var fingerprints: [String: String] = [:]

    static func name(of cursor: NSCursor) -> String {
        if let match = known.first(where: { $0.1 === cursor }) { return match.0 }
        let print = fingerprint(cursor)
        if let match = known.first(where: { fingerprint($0.1) == print }) { return match.0 }
        return "custom(hotspot \(UIReport.number(cursor.hotSpot.x)),\(UIReport.number(cursor.hotSpot.y)) "
            + "\(UIReport.number(cursor.image.size.width))×\(UIReport.number(cursor.image.size.height)))"
    }

    private static func fingerprint(_ cursor: NSCursor) -> String {
        let key = "\(ObjectIdentifier(cursor))"
        if let cached = fingerprints[key] { return cached }
        let data = cursor.image.tiffRepresentation ?? Data()
        let print = "\(cursor.hotSpot) \(cursor.image.size) \(data.count) \(data.hashValue)"
        fingerprints[key] = print
        return print
    }
}

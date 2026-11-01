import AppKit

/// Animates the sidebar's rows coming and going the way Arc does.
///
/// Arc's sidebar is an `NSOutlineView`. It applies each snapshot between `beginUpdates` and
/// `endUpdates` inside one `NSAnimationContext` group of 0.12s with the default timing function,
/// inserting rows with `.effectFade` and removing them with `.effectFade` (docs/arc-visual-spec.md
/// "Sidebar rows"). SwiftUI's `List` drives an `NSTableView` too, but it inserts and removes rows
/// with no animation whatever the transaction (seen with a logging build: options 0, outside any
/// group). So Kite steps in at the table: after a state change that adds, removes or moves rows
/// (`arm()`), the sidebar's table gets Arc's options and group.
@MainActor
enum SidebarRowsAnimator {
    private static let hosts = NSHashTable<NSView>.weakObjects()
    /// SwiftUI applies a change on the next display pass; a change that touched no shown rows
    /// (another space's) lapses after this.
    private static let armedFor: CFTimeInterval = 0.1
    private static var armedUntil: CFTimeInterval = 0
    /// Tables inside an update block that this opened a group for.
    private static var grouped: [ObjectIdentifier: Int] = [:]
    /// Rows inserted in the open group, faded in when it closes.
    private static var inserted: [ObjectIdentifier: IndexSet] = [:]
    private static var installed = false

    /// The sidebar's hosting view; its tables animate.
    static func register(_ host: NSView) {
        install()
        hosts.add(host)
    }

    /// The next updates to the sidebar's rows animate.
    static func arm() {
        armedUntil = CACurrentMediaTime() + armedFor
    }

    fileprivate static func animates(_ table: NSTableView) -> Bool {
        CACurrentMediaTime() < armedUntil && hosts.allObjects.contains { table.isDescendant(of: $0) }
    }

    fileprivate static func isGrouped(_ table: NSTableView) -> Bool {
        grouped[ObjectIdentifier(table)] != nil
    }

    fileprivate static func beginGroup() {
        NSAnimationContext.beginGrouping()
        let context = NSAnimationContext.current
        let c = ArcMetrics.Motion.sidebarRowsCurve
        context.duration = ArcMetrics.Motion.sidebarRowsDuration
        context.timingFunction = CAMediaTimingFunction(controlPoints: c.x1, c.y1, c.x2, c.y2)
    }

    fileprivate static func beginUpdates(_ table: NSTableView) {
        let id = ObjectIdentifier(table)
        if let depth = grouped[id] {
            grouped[id] = depth + 1
        } else if animates(table) {
            beginGroup()
            grouped[id] = 1
        }
    }

    fileprivate static func endUpdates(_ table: NSTableView) {
        let id = ObjectIdentifier(table)
        guard let depth = grouped[id] else { return }
        if depth > 1 {
            grouped[id] = depth - 1
        } else {
            grouped[id] = nil
            endGroup(table)
        }
    }

    fileprivate static func noteInserted(_ indexes: IndexSet, in table: NSTableView) {
        inserted[ObjectIdentifier(table), default: []].formUnion(indexes)
    }

    /// `.effectFade` alone leaves a new row opaque: SwiftUI makes its view after the table has
    /// animated. So the new rows are made now and faded in on the group's timing, as Arc's are.
    private static func endGroup(_ table: NSTableView) {
        for row in inserted.removeValue(forKey: ObjectIdentifier(table)) ?? [] where row < table.numberOfRows {
            // Just made, so not backed by a layer until the next display unless asked now.
            guard let view = table.rowView(atRow: row, makeIfNecessary: true) else { continue }
            view.wantsLayer = true
            guard let layer = view.layer else { continue }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = NSAnimationContext.current.duration
            fade.timingFunction = NSAnimationContext.current.timingFunction
            layer.add(fade, forKey: "kiteFadeIn")
        }
        NSAnimationContext.endGrouping()
    }

    /// Runs a row change in Arc's group unless an update block already opened one.
    fileprivate static func inGroup(_ table: NSTableView, _ body: () -> Void) {
        guard animates(table), !isGrouped(table) else { return body() }
        beginGroup()
        body()
        endGroup(table)
    }

    private static func install() {
        guard !installed else { return }
        installed = true
        let pairs: [(Selector, Selector)] = [
            (#selector(NSTableView.beginUpdates), #selector(NSTableView.kite_beginUpdates)),
            (#selector(NSTableView.endUpdates), #selector(NSTableView.kite_endUpdates)),
            (#selector(NSTableView.insertRows(at:withAnimation:)), #selector(NSTableView.kite_insertRows(at:withAnimation:))),
            (#selector(NSTableView.removeRows(at:withAnimation:)), #selector(NSTableView.kite_removeRows(at:withAnimation:))),
            (#selector(NSTableView.moveRow(at:to:)), #selector(NSTableView.kite_moveRow(at:to:))),
        ]
        for (original, replacement) in pairs {
            guard let a = class_getInstanceMethod(NSTableView.self, original),
                  let b = class_getInstanceMethod(NSTableView.self, replacement) else { continue }
            method_exchangeImplementations(a, b)
        }
    }
}

/// After the exchange these run as AppKit's methods, and calling themselves calls AppKit's.
extension NSTableView {
    @objc fileprivate func kite_beginUpdates() {
        MainActor.assumeIsolated { SidebarRowsAnimator.beginUpdates(self) }
        kite_beginUpdates()
    }

    @objc fileprivate func kite_endUpdates() {
        kite_endUpdates()
        MainActor.assumeIsolated { SidebarRowsAnimator.endUpdates(self) }
    }

    @objc fileprivate func kite_insertRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions) {
        MainActor.assumeIsolated {
            let animates = SidebarRowsAnimator.animates(self)
            SidebarRowsAnimator.inGroup(self) {
                kite_insertRows(at: indexes, withAnimation: animates ? .effectFade : options)
                if animates { SidebarRowsAnimator.noteInserted(indexes, in: self) }
            }
        }
    }

    @objc fileprivate func kite_removeRows(at indexes: IndexSet, withAnimation options: NSTableView.AnimationOptions) {
        MainActor.assumeIsolated {
            let animates = SidebarRowsAnimator.animates(self)
            SidebarRowsAnimator.inGroup(self) { kite_removeRows(at: indexes, withAnimation: animates ? .effectFade : options) }
        }
    }

    @objc fileprivate func kite_moveRow(at oldIndex: Int, to newIndex: Int) {
        MainActor.assumeIsolated {
            SidebarRowsAnimator.inGroup(self) { kite_moveRow(at: oldIndex, to: newIndex) }
        }
    }
}

import AppKit
import KiteCore

/// Builds the `ui tree` of a window: AppKit views with their layer styling, then SwiftUI's
/// accessibility elements inside each hosting view (SwiftUI draws without one view per
/// element, so its accessibility tree is where its geometry is), and optionally the
/// Core Animation sublayers that aren't views.
@MainActor
struct UITreeBuilder {
    let window: NSWindow
    let layers: Bool

    /// Node "0" is the content view; the titlebar's views (traffic lights) follow as its last child,
    /// since the content runs under the titlebar.
    func build() -> UINode {
        guard let content = window.contentView else { return UINode(kind: "NSWindow (no content view)") }
        var root = node(for: content)
        if let frameView = content.superview {
            let titlebar = frameView.subviews.filter { $0 !== content }.map { node(for: $0) }
            if !titlebar.isEmpty {
                root.children.append(UINode(kind: "titlebar", frame: window.uiRect(frameView.frame), children: titlebar))
            }
        }
        return root
    }

    /// Paths of every view under the content view, for naming views in other reports.
    static func paths(in window: NSWindow) -> [ObjectIdentifier: String] {
        var paths: [ObjectIdentifier: String] = [:]
        func visit(_ view: NSView, _ path: String) {
            paths[ObjectIdentifier(view)] = path
            guard !UIFormat.isWebContent(view) else { return }
            for (index, child) in view.subviews.enumerated() { visit(child, "\(path).\(index)") }
        }
        if let content = window.contentView { visit(content, "0") }
        return paths
    }

    private func node(for view: NSView) -> UINode {
        var attributes: [UINode.Attribute] = []
        var label: String?
        if view.isHidden { attributes.append(.init("hidden", "true")) }
        if view.alphaValue < 1 { attributes.append(.init("alpha", UIReport.number(Double(view.alphaValue)))) }

        switch view {
        case let effect as NSVisualEffectView:
            attributes.append(.init("material", Self.name(effect.material)))
            attributes.append(.init("blending", effect.blendingMode == .behindWindow ? "behindWindow" : "withinWindow"))
            attributes.append(.init("state", effect.state == .active ? "active" : effect.state == .inactive ? "inactive" : "followsWindow"))
            if effect.isEmphasized { attributes.append(.init("emphasized", "true")) }
        case let field as NSTextField:
            label = field.stringValue
            UIFormat.font(field.font).map { attributes.append(.init("font", $0)) }
            UIFormat.hex(field.textColor?.cgColor).map { attributes.append(.init("color", $0)) }
        case let button as NSButton:
            label = button.title.isEmpty ? button.accessibilityLabel() : button.title
            UIFormat.font(button.font).map { attributes.append(.init("font", $0)) }
            if button.state == .on { attributes.append(.init("on", "true")) }
            if !button.isEnabled { attributes.append(.init("enabled", "false")) }
        default:
            break
        }
        if let layer = view.layer { attributes += Self.style(of: layer) }

        var children: [UINode] = []
        if UIFormat.isWebContent(view) {
            attributes.append(.init("web", "page (read it with the page tools)"))
        } else {
            children = view.subviews.map { node(for: $0) }
            if UIFormat.className(view).contains("HostingView") {
                children += AXRead(view).children.compactMap { element(for: $0, depth: 0) }
            }
            if layers, let layer = view.layer {
                children += (layer.sublayers ?? []).filter { !($0.delegate is NSView) }.map { node(for: $0, in: view) }
            }
        }
        return UINode(kind: UIFormat.className(view), identifier: view.identifier?.rawValue, label: label,
                      frame: window.uiRect(view.convert(view.bounds, to: nil)), attributes: attributes, children: children)
    }

    // MARK: SwiftUI (accessibility elements)

    private func element(for object: Any, depth: Int) -> UINode? {
        // Views among the children are already in the tree.
        guard !(object is NSView), depth < 40, let element = object as? NSObject else { return nil }
        let ax = AXRead(element)
        var attributes: [UINode.Attribute] = []
        if let subrole = ax.subrole { attributes.append(.init("subrole", subrole)) }
        if ax.isSelected { attributes.append(.init("selected", "true")) }
        if !ax.isEnabled { attributes.append(.init("enabled", "false")) }
        if let value = ax.value { attributes.append(.init("value", AccessibilityOutline.quote(String(value.prefix(80))))) }
        let children = ax.children.compactMap { self.element(for: $0, depth: depth + 1) }
        return UINode(kind: ax.role ?? "AXUnknown", identifier: ax.identifier, label: ax.label, frame: ax.screenFrame.map { window.uiRect(fromScreen: $0) },
                      attributes: attributes, children: children)
    }

    // MARK: Layers

    private func node(for layer: CALayer, in view: NSView) -> UINode {
        let frame = view.layer.map { layer.convert(layer.bounds, to: $0) }.map { view.convert($0, to: nil) }
        var attributes = Self.style(of: layer)
        if layer.isHidden { attributes.insert(.init("hidden", "true"), at: 0) }
        if layer.contents != nil { attributes.append(.init("contents", "image")) }
        let children = (layer.sublayers ?? []).filter { !($0.delegate is NSView) }.map { node(for: $0, in: view) }
        return UINode(kind: UIFormat.className(layer), identifier: layer.name, frame: frame.map { window.uiRect($0) },
                      attributes: attributes, children: children)
    }

    /// What a layer adds to how its view looks: fill, corners, border, shadow, filters.
    static func style(of layer: CALayer) -> [UINode.Attribute] {
        var attributes: [UINode.Attribute] = []
        if layer.opacity < 1 { attributes.append(.init("opacity", UIReport.number(Double(layer.opacity)))) }
        UIFormat.hex(layer.backgroundColor).map { attributes.append(.init("bg", $0)) }
        if layer.cornerRadius > 0 {
            let curve = layer.cornerCurve == .continuous ? " continuous" : ""
            attributes.append(.init("radius", UIReport.number(Double(layer.cornerRadius)) + curve.replacingOccurrences(of: " ", with: "/")))
            if layer.maskedCorners != [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner] {
                attributes.append(.init("corners", String(layer.maskedCorners.rawValue)))
            }
        }
        if layer.masksToBounds { attributes.append(.init("clips", "true")) }
        if layer.borderWidth > 0 {
            attributes.append(.init("border", UIReport.number(Double(layer.borderWidth)) + " " + (UIFormat.hex(layer.borderColor) ?? "?")))
        }
        if layer.shadowOpacity > 0 {
            let offset = layer.shadowOffset
            attributes.append(.init("shadow", "\(UIFormat.hex(layer.shadowColor) ?? "?") opacity \(UIReport.number(Double(layer.shadowOpacity))) "
                + "radius \(UIReport.number(Double(layer.shadowRadius))) offset \(UIReport.number(offset.width)),\(UIReport.number(offset.height))"))
        }
        if let filter = layer.compositingFilter { attributes.append(.init("compositing", "\(filter)")) }
        let filters = (layer.backgroundFilters ?? []).map { "\($0)" }
        if !filters.isEmpty { attributes.append(.init("backgroundFilters", filters.joined(separator: ","))) }
        if layer is CAMetalLayer { attributes.append(.init("metal", "true")) }
        return attributes
    }

    static func name(_ material: NSVisualEffectView.Material) -> String {
        switch material {
        case .titlebar: "titlebar"
        case .selection: "selection"
        case .menu: "menu"
        case .popover: "popover"
        case .sidebar: "sidebar"
        case .headerView: "headerView"
        case .sheet: "sheet"
        case .windowBackground: "windowBackground"
        case .hudWindow: "hudWindow"
        case .fullScreenUI: "fullScreenUI"
        case .toolTip: "toolTip"
        case .contentBackground: "contentBackground"
        case .underWindowBackground: "underWindowBackground"
        case .underPageBackground: "underPageBackground"
        default: "raw\(material.rawValue)"
        }
    }
}

/// One accessibility element, read through the NSAccessibility methods by name: SwiftUI's elements
/// (AccessibilityNode) implement them without declaring the protocol and don't answer the old
/// attribute API, and a hosting view lists its SwiftUI elements only through `accessibilityChildren`.
@MainActor
struct AXRead {
    let object: NSObject

    init(_ object: NSObject) { self.object = object }

    private func read(_ key: String, getter: String? = nil) -> Any? {
        guard object.responds(to: Selector(getter ?? key)) else { return nil }
        return object.value(forKey: key)
    }

    var role: String? { read("accessibilityRole") as? String }
    var subrole: String? { read("accessibilitySubrole") as? String }
    var identifier: String? { (read("accessibilityIdentifier") as? String)?.nilIfEmpty }
    var label: String? { (read("accessibilityLabel") as? String)?.nilIfEmpty ?? (read("accessibilityTitle") as? String)?.nilIfEmpty }
    var isSelected: Bool { (read("accessibilitySelected", getter: "isAccessibilitySelected") as? NSNumber)?.boolValue == true }
    var isEnabled: Bool { (read("accessibilityEnabled", getter: "isAccessibilityEnabled") as? NSNumber)?.boolValue != false }
    var value: String? {
        let value = read("accessibilityValue")
        return ((value as? String) ?? (value as? NSNumber)?.stringValue)?.nilIfEmpty
    }
    var children: [NSObject] { read("accessibilityChildren") as? [NSObject] ?? [] }
    /// In AppKit screen coordinates (bottom-left); only clients outside the app see them flipped.
    var screenFrame: NSRect? {
        guard let frame = (read("accessibilityFrame") as? NSValue)?.rectValue, frame != .zero else { return nil }
        return frame
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

import AppKit
import KiteCore

/// The `ui` tool's Mac side: Kite's own windows, read and driven from inside the app.
///
/// Off unless the user turns on Kite menu → Diagnostics for Claude (which needs Claude's
/// control on too), or a test build runs on a throwaway profile with `KITE_DIAGNOSTICS=1`.
/// Nothing here reaches another app, moves the real pointer, or focuses Kite.
@MainActor
final class UIDiagnostics {
    static let shared = UIDiagnostics()
    static let defaultsKey = "claudeDiagnostics"

    /// `KITE_DIAGNOSTICS=1` counts only with `KITE_SUPPORT_PATH`, so it can't switch this on for a real profile.
    static var enabledByEnvironment: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["KITE_DIAGNOSTICS"] == "1" && environment["KITE_SUPPORT_PATH"] != nil
    }

    static var isEnabled: Bool { enabledByEnvironment || UserDefaults.standard.bool(forKey: defaultsKey) }

    let keyLog = KeyRoutingLog()

    /// Starts or stops what runs in the background (the key log) to match the setting.
    func applySetting() {
        if Self.isEnabled { keyLog.start() } else { keyLog.stop() }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.defaultsKey)
        applySetting()
    }

    func run(_ inspection: UIInspection) async throws -> ToolOutput {
        switch inspection {
        case .windows:
            return .text(windowsReport())
        case let .tree(number, root, depth, match, layers, maxNodes):
            let window = try self.window(number)
            let awake = await wakeAccessibility()
            let tree = UITreeBuilder(window: window, layers: layers).build()
            guard let start = tree.node(at: root ?? "0") else {
                throw AutomationError(.notFound, "There's no node \(root ?? "0"). Call tree without root for the paths.")
            }
            let note = awake ? "" : "SwiftUI's elements are missing: they need Accessibility permission for Kite "
                + "(System Settings → Privacy & Security → Accessibility).\n"
            return .text(header(window) + note + UIReport.tree(start, rootPath: root ?? "0", depth: depth, match: match, maxNodes: maxNodes))
        case let .capture(number, region, format, pixels, image, save):
            return try await UICapture.run(window: try window(number), region: region, format: format, pixels: pixels,
                                           image: image, save: save)
        case let .pointer(number, points, modifiers):
            let window = try self.window(number)
            let probe = UIPointerProbe(window: window, modifiers: UIInputSender.flags(modifiers))
            return .text(header(window) + UIReport.pointer(probe.sweep(points)))
        case let .input(number, event):
            let window = try self.window(number)
            let result = try await UIInputSender(window: window, keyLog: keyLog).send(event)
            return .text(result)
        case .menu(let match):
            return .text(UIReport.menu(UIMenuReader.items(), match: match))
        case let .keyLog(limit, clear):
            return .text(keyLog.report(limit: limit, clear: clear))
        case let .trace(number, seconds, keys, match):
            let window = try self.window(number)
            if match != nil { _ = await wakeAccessibility() }
            return .text(header(window) + (await UITracer(window: window, keyLog: keyLog).run(seconds: seconds, keys: keys, match: match)))
        }
    }

    private var accessibilityAwake = false

    /// SwiftUI builds its accessibility elements only once an assistive app has asked for them through
    /// the accessibility API, so Kite asks itself, off the main thread (which answers). That needs Kite to
    /// have Accessibility permission; without it, only AppKit's elements are there.
    private func wakeAccessibility() async -> Bool {
        if accessibilityAwake { return true }
        let pid = getpid()
        accessibilityAwake = await Task.detached {
            let app = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(app, 2)
            var windows: CFTypeRef?
            return AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success
        }.value
        if accessibilityAwake { try? await Task.sleep(for: .milliseconds(100)) }
        return accessibilityAwake
    }

    // MARK: Windows

    /// The window by number, or the browser window in front.
    func window(_ number: Int?) throws -> NSWindow {
        if let number {
            guard let window = NSApp.window(withWindowNumber: number) else {
                throw AutomationError(.notFound, "Kite has no window \(number). Call ui with action windows.")
            }
            return window
        }
        let browsers = NSApp.orderedWindows.filter { $0.windowController is BrowserWindowController }
        guard let window = browsers.first(where: \.isMainWindow) ?? browsers.first else {
            throw AutomationError(.notFound, "Kite has no browser window open.")
        }
        return window
    }

    private func header(_ window: NSWindow) -> String {
        "Window \(window.windowNumber), \(UIReport.number(window.frame.width))×\(UIReport.number(window.frame.height)) pt "
            + "at \(UIReport.number(window.backingScaleFactor))×. Points from the window's top-left.\n"
    }

    private func windowsReport() -> String {
        var windows = NSApp.orderedWindows.filter { $0.isVisible || $0.isMiniaturized }
        // Popovers (Site Controls, extensions, downloads) aren't in orderedWindows; list them too
        // so `{"window": N}` can reach them.
        windows += NSApp.windows.filter { $0.isVisible && $0.className.contains("Popover") && !windows.contains($0) }
        guard !windows.isEmpty else { return "Kite has no windows open." }
        return windows.map { window in
            var flags: [String] = []
            if let controller = window.windowController as? BrowserWindowController {
                flags.append(controller.isIncognito ? "incognito browser" : "browser")
            } else {
                flags.append(String(describing: type(of: window)))
            }
            if window.isKeyWindow { flags.append("key") }
            if window.isMainWindow { flags.append("main") }
            if window.styleMask.contains(.fullScreen) { flags.append("full screen") }
            if window.isMiniaturized { flags.append("minimized") }
            if !window.occlusionState.contains(.visible) { flags.append("covered") }
            if !window.isOnActiveSpace { flags.append("other Space") }
            let screen = window.screen.map { "\(FrameClock.maximumRate(of: $0)) Hz" } ?? "no screen"
            return "- window \(window.windowNumber) [\(flags.joined(separator: ", "))] "
                + "\(UIReport.number(window.frame.width))×\(UIReport.number(window.frame.height)) pt, "
                + "\(UIReport.number(window.backingScaleFactor))×, \(screen)"
        }.joined(separator: "\n") + "\nKite is \(NSApp.isActive ? "the active app" : "in the background")."
    }
}

// MARK: Shared helpers

/// Window coordinates: AppKit's window base (bottom-left) ⇄ the ui tool's top-left points.
extension NSWindow {
    /// The centre of the device pixel whose top-left is `point`, as capture reads it. A bare flip would put
    /// a point on a rect's top edge at that rect's maxY, which AppKit counts as outside.
    func basePoint(_ point: UIPoint) -> NSPoint {
        let half = 0.5 / backingScaleFactor
        return NSPoint(x: point.x + half, y: frame.height - point.y - half)
    }

    func uiPoint(_ point: NSPoint) -> UIPoint {
        UIPoint(x: point.x, y: frame.height - point.y)
    }

    /// A rect in window base coordinates, as a top-left `UIRect`.
    func uiRect(_ rect: NSRect) -> UIRect {
        UIRect(x: rect.minX, y: frame.height - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A rect in screen coordinates (AppKit's, bottom-left), as a top-left `UIRect` in this window.
    func uiRect(fromScreen rect: NSRect) -> UIRect {
        uiRect(convertFromScreen(rect))
    }
}

enum UIFormat {
    /// "#RRGGBB", with "@alpha" below 1, in sRGB; colours defined in Display P3 also give their P3 values.
    static func hex(_ color: CGColor?) -> String? {
        guard let color, let sRGB = CGColorSpace(name: CGColorSpace.sRGB),
              let converted = color.converted(to: sRGB, intent: .defaultIntent, options: nil),
              let c = converted.components, c.count >= 3 else { return nil }
        var text = hexDigits(c[0], c[1], c[2])
        let alpha = c.count >= 4 ? c[3] : 1
        if alpha < 0.999 { text += "@" + UIReport.number(Double(alpha)) }
        if let name = color.colorSpace?.name, name == CGColorSpace.displayP3, let p3 = color.components, p3.count >= 3 {
            text += "(p3 \(hexDigits(p3[0], p3[1], p3[2])))"
        }
        return text
    }

    private static func hexDigits(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> String {
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(r), byte(g), byte(b))
    }

    static func font(_ font: NSFont?) -> String? {
        guard let font else { return nil }
        let traits = font.fontDescriptor.object(forKey: .traits) as? [NSFontDescriptor.TraitKey: Any]
        let weight = (traits?[.weight] as? NSNumber).map { " w" + UIReport.number($0.doubleValue) } ?? ""
        return "\(font.fontName.replacingOccurrences(of: " ", with: "_"))/\(UIReport.number(font.pointSize))\(weight)"
    }

    /// Views whose insides belong to the web page: the page tools read those.
    static func isWebContent(_ view: NSView) -> Bool {
        let name = String(describing: type(of: view))
        return ["RenderWidgetHostView", "WebContentsView", "WKWebView", "BridgedContentView"].contains { name.contains($0) }
    }

    static func className(_ object: AnyObject) -> String {
        String(describing: type(of: object))
    }
}

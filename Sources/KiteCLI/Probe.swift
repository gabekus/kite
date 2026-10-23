import AppKit
import ApplicationServices
import Foundation
import KiteCore
import ScreenCaptureKit

// `kite probe APP …`: the same measurements as Kite's ui tool, for another app (Arc, Safari),
// from outside it: its accessibility tree in window points, and its window's pixels via
// ScreenCaptureKit, without bringing it forward or touching the pointer.
//
// Text is hidden unless --text is given: another app's tab titles and URLs are the user's.
// Needs Accessibility (tree) and Screen Recording (capture) for the app running `kite`.

let probeUsage = """
    kite probe APP                       List APP's windows (APP: name, bundle id or pid)
    kite probe APP tree [--window N] [--depth N] [--match TEXT] [--text]
                                         Accessibility tree: roles and frames in window points
    kite probe APP capture [--window N] [-o FILE] [--region x,y,w,h] [--pixels "x,y x,y"]
                                         Capture the window in the background (sRGB PNG)
    """

struct ProbeError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum Probe {
    static func run(_ args: Arguments) async throws -> Int32 {
        guard let target = args.positional.first else { throw ProbeError(probeUsage) }
        guard let app = findApp(target) else { throw ProbeError("No running app matches \"\(target)\".") }
        let action = args.positional.count > 1 ? args.positional[1] : "windows"
        let windows = try axWindows(app)
        let index = try args.options["--window"].map { value -> Int in
            guard let n = Int(value), windows.indices.contains(n) else { throw ProbeError("--window is 0 to \(windows.count - 1).") }
            return n
        } ?? 0

        switch action {
        case "windows":
            guard !windows.isEmpty else { print("\(app.localizedName ?? target) has no windows."); return 0 }
            for (i, window) in windows.enumerated() {
                let frame = frame(of: window).map { "\(UIReport.number($0.width))×\(UIReport.number($0.height)) pt at \(UIReport.number($0.minX)),\(UIReport.number($0.minY))" } ?? "no frame"
                let subrole = attribute(window, kAXSubroleAttribute) as? String ?? ""
                print("- window \(i) \(subrole) \(frame)")
            }
        case "tree":
            guard windows.indices.contains(index), let origin = frame(of: windows[index])?.origin else {
                throw ProbeError("\(app.localizedName ?? target) has no window \(index).")
            }
            let depth = Int(args.options["--depth"] ?? "") ?? 30
            let root = node(windows[index], origin: origin, depth: depth, text: args.flags.contains("--text"))
            print(UIReport.tree(root, depth: depth, match: args.options["--match"], maxNodes: Int(args.options["--max"] ?? "") ?? 2000))
        case "capture":
            guard windows.indices.contains(index), let frame = frame(of: windows[index]) else {
                throw ProbeError("\(app.localizedName ?? target) has no window \(index).")
            }
            let image = try await capture(pid: app.processIdentifier, frame: frame)
            let scale = Double(image.width) / frame.width
            if let pixels = args.options["--pixels"] {
                let bitmap = NSBitmapImageRep(cgImage: image)
                for pair in pixels.split(separator: " ") {
                    let parts = pair.split(separator: ",").compactMap { Double($0) }
                    guard parts.count == 2 else { throw ProbeError("--pixels is \"x,y x,y\" in window points.") }
                    let x = Int(parts[0] * scale), y = Int(parts[1] * scale)
                    let color = x >= 0 && y >= 0 && x < bitmap.pixelsWide && y < bitmap.pixelsHigh
                        ? bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) : nil
                    print("(\(UIReport.number(parts[0])), \(UIReport.number(parts[1]))): \(color.map(hex) ?? "outside the window")")
                }
            }
            var output = image
            if let region = args.options["--region"] {
                let parts = region.split(separator: ",").compactMap { Double($0) }
                guard parts.count == 4, let crop = image.cropping(to: CGRect(x: parts[0] * scale, y: parts[1] * scale,
                                                                              width: parts[2] * scale, height: parts[3] * scale).integral) else {
                    throw ProbeError("--region is x,y,w,h in window points, inside the window.")
                }
                output = crop
            }
            if args.options["--pixels"] == nil || args.options["-o"] != nil {
                let path = args.options["-o"] ?? "probe-\(Int(Date().timeIntervalSince1970)).png"
                guard let data = NSBitmapImageRep(cgImage: output).representation(using: .png, properties: [:]) else {
                    throw ProbeError("Couldn't encode the capture.")
                }
                try data.write(to: URL(fileURLWithPath: path))
                print("\(path) (\(output.width)×\(output.height) px at \(UIReport.number(scale))×, sRGB)")
            }
        default:
            throw ProbeError("Unknown probe action \"\(action)\".\n\n\(probeUsage)")
        }
        return 0
    }

    static func findApp(_ target: String) -> NSRunningApplication? {
        if let pid = pid_t(target) { return NSRunningApplication(processIdentifier: pid) }
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { $0.bundleIdentifier?.caseInsensitiveCompare(target) == .orderedSame }
            ?? apps.first { $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame }
    }

    // MARK: Accessibility

    static func axWindows(_ app: NSRunningApplication) throws -> [AXUIElement] {
        guard AXIsProcessTrusted() else {
            throw ProbeError("This terminal (or app) needs Accessibility permission: System Settings › Privacy & Security › Accessibility.")
        }
        let element = AXUIElementCreateApplication(app.processIdentifier)
        return attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
    }

    static func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Top-left screen points, as accessibility reports them.
    static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute), let size = attribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero, extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: point, size: extent)
    }

    static func node(_ element: AXUIElement, origin: CGPoint, depth: Int, text: Bool) -> UINode {
        let role = attribute(element, kAXRoleAttribute) as? String ?? "AXUnknown"
        var attributes: [UINode.Attribute] = []
        if let subrole = attribute(element, kAXSubroleAttribute) as? String { attributes.append(.init("subrole", subrole)) }
        if (attribute(element, kAXSelectedAttribute) as? Bool) == true { attributes.append(.init("selected", "true")) }
        if (attribute(element, kAXEnabledAttribute) as? Bool) == false { attributes.append(.init("enabled", "false")) }
        let rawLabel = (attribute(element, kAXDescriptionAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (attribute(element, kAXTitleAttribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
        let label = rawLabel.map { text ? $0 : "‹\($0.count) chars›" }
        let frame = frame(of: element).map {
            UIRect(x: $0.minX - origin.x, y: $0.minY - origin.y, width: $0.width, height: $0.height)
        }
        let children = depth > 1 ? (attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []).map {
            node($0, origin: origin, depth: depth - 1, text: text)
        } : []
        return UINode(kind: role, identifier: attribute(element, kAXIdentifierAttribute) as? String, label: label, frame: frame,
                      attributes: attributes, children: children)
    }

    // MARK: Capture

    static func capture(pid: pid_t, frame: CGRect) async throws -> CGImage {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch {
            throw ProbeError("Screen Recording permission is needed for this terminal (or app): System Settings › Privacy & Security › "
                + "Screen & System Audio Recording. (\(error.localizedDescription))")
        }
        // The accessibility window and ScreenCaptureKit's share a frame.
        let candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        guard let window = candidates.min(by: { distance($0.frame, frame) < distance($1.frame, frame) }) else {
            throw ProbeError("ScreenCaptureKit lists no window for that app.")
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let scale = CGFloat(filter.pointPixelScale)
        configuration.width = Int(filter.contentRect.width * scale)
        configuration.height = Int(filter.contentRect.height * scale)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.captureResolution = .best
        configuration.colorSpaceName = CGColorSpace.sRGB
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    static func hex(_ color: NSColor) -> String {
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(color.redComponent), byte(color.greenComponent), byte(color.blueComponent))
            + (color.alphaComponent < 0.999 ? "@" + UIReport.number(Double(color.alphaComponent)) : "")
    }
}

import AppKit
import ImageIO
import KiteCore
import UniformTypeIdentifiers

/// Writes and removes the launcher bundles in the apps folder (WebAppShim has the layout):
///
///     <Name>.app/Contents/Info.plist
///     <Name>.app/Contents/PkgInfo
///     <Name>.app/Contents/MacOS/launcher      (sh: open -b <Kite> kite-app://<id>)
///     <Name>.app/Contents/Resources/app.icns
///
/// Nothing here registers the bundle with Launch Services: macOS finds apps in ~/Applications on its own.
@MainActor
enum WebAppShimWriter {
    /// Where launchers go: ~/Applications/Kite Apps. A test profile (KITE_SUPPORT_PATH) never writes
    /// there: it uses KITE_TEST_APPS_DIR, else a "Kite Apps" folder inside the profile.
    static var appsDirectory: URL {
        let environment = ProcessInfo.processInfo.environment
        if environment["KITE_SUPPORT_PATH"] != nil {
            if let test = environment["KITE_TEST_APPS_DIR"], !test.isEmpty { return URL(fileURLWithPath: test, isDirectory: true) }
            return AppDelegate.supportDirectory.appendingPathComponent(WebAppShim.folderName, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent(WebAppShim.folderName, isDirectory: true)
    }

    static var kiteBundleID: String { Bundle.main.bundleIdentifier ?? "dev.gabek.Kite" }

    /// Writes `app`'s launcher with `icon` and returns its file name. An older launcher for the same app
    /// (`replacing`) is removed first, so a reinstall under a new name doesn't leave the old one behind.
    static func write(_ app: WebApp, icon: NSImage?, replacing old: String?) throws -> String {
        let fm = FileManager.default
        let directory = appsDirectory
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        if let old { remove(shimName: old, appID: app.id) }
        let taken = Set((try? fm.contentsOfDirectory(atPath: directory.path)) ?? [])
        let name = WebAppShim.bundleName(for: app.name, taken: taken)
        let bundle = directory.appendingPathComponent(name, isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        do {
            try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
            try fm.createDirectory(at: resources, withIntermediateDirectories: true)
            let plist = try PropertyListSerialization.data(
                fromPropertyList: WebAppShim.infoPlist(for: app, kiteBundleID: kiteBundleID), format: .xml, options: 0)
            try plist.write(to: contents.appendingPathComponent("Info.plist"))
            try Data("APPL????".utf8).write(to: contents.appendingPathComponent("PkgInfo"))
            let launcher = macOS.appendingPathComponent(WebAppShim.executableName)
            try Data(WebAppShim.launcherScript(appID: app.id, kiteBundleID: kiteBundleID).utf8).write(to: launcher)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
            if let icon { writeICNS(icon, to: resources.appendingPathComponent(WebAppShim.iconFileName)) }
        } catch {
            try? fm.removeItem(at: bundle)
            throw error
        }
        return name
    }

    /// Removes a launcher, only if it's this app's (its Info.plist names `appID`), so a hand-made
    /// app of the same name in the folder is never touched.
    static func remove(shimName: String, appID: String) {
        guard !shimName.contains("/"), shimName.hasSuffix(".app") else { return }
        let bundle = appsDirectory.appendingPathComponent(shimName, isDirectory: true)
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["KiteAppID"] as? String == appID else { return }
        try? FileManager.default.removeItem(at: bundle)
    }

    /// An .icns with the icon drawn at each size macOS asks for (16 to 1024 px).
    @discardableResult
    static func writeICNS(_ image: NSImage, to url: URL) -> Bool {
        let sizes = [16, 32, 64, 128, 256, 512, 1024]
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.icns.identifier as CFString, sizes.count, nil)
        else { return false }
        for size in sizes {
            guard let cgImage = render(image, pixels: size) else { continue }
            CGImageDestinationAddImage(destination, cgImage, nil)
        }
        return CGImageDestinationFinalize(destination)
    }

    /// PNG data of the icon at `pixels` square, for the profile's copy (menus use it).
    static func pngData(_ image: NSImage, pixels: Int = 256) -> Data? {
        guard let cgImage = render(image, pixels: pixels) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    private static func render(_ image: NSImage, pixels: Int) -> CGImage? {
        guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    /// An icon for an app whose site has none Kite could read: its first letter on its theme colour.
    static func letterIcon(name: String, themeColor: String?) -> NSImage {
        let size = NSSize(width: 256, height: 256)
        return NSImage(size: size, flipped: false) { rect in
            let hex = themeColor ?? "#5b5bd6"
            let fill = WebApps.components(of: hex).map { NSColor(srgbRed: $0.red, green: $0.green, blue: $0.blue, alpha: 1) } ?? .systemIndigo
            fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 20, dy: 20), xRadius: 48, yRadius: 48).fill()
            let letter = String(name.trimmingCharacters(in: .whitespaces).first ?? "W").uppercased()
            let ink: NSColor = WebApps.prefersDarkForeground(on: hex) ? .black : .white
            let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 128, weight: .semibold), .foregroundColor: ink]
            let text = NSAttributedString(string: letter, attributes: attributes)
            let textSize = text.size()
            text.draw(at: NSPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2))
            return true
        }
    }
}

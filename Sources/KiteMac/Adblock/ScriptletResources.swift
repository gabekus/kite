import Foundation
import JavaScriptCore
import KiteCore

/// uBlock Origin's scriptlets and redirect resources, which `##+js(...)` and
/// `$redirect` filters refer to. uBO is GPL, so Kite downloads a release at
/// runtime and converts it here rather than shipping it.
enum ScriptletResources {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// The latest uBO release tag, e.g. "1.75.0".
    static func latestRelease(session: URLSession) async throws -> String {
        let url = URL(string: "https://api.github.com/repos/gorhill/uBlock/releases/latest")!
        let (data, _) = try await session.data(from: url)
        struct Release: Decodable { var tag_name: String }
        let tag = try JSONDecoder().decode(Release.self, from: data).tag_name
        // The tag becomes a path, so accept only version-like names.
        guard tag.range(of: #"^[0-9A-Za-z._-]+$"#, options: .regularExpression) != nil else {
            throw Failure(description: "unexpected uBO release tag")
        }
        return tag
    }

    /// Downloads uBO `release`'s source and extracts just the scriptlet and redirect files into `directory`.
    static func download(release: String, into directory: URL, session: URLSession) async throws -> URL {
        let url = URL(string: "https://codeload.github.com/gorhill/uBlock/tar.gz/refs/tags/\(release)")!
        let (archive, response) = try await session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(description: "uBO download failed") }
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = "uBlock-\(release)/src"
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", directory.path, "--strip-components", "2",
                         "\(root)/js", "\(root)/web_accessible_resources"]
        try tar.run()
        tar.waitUntilExit()
        try? FileManager.default.removeItem(at: archive)
        guard tar.terminationStatus == 0 else { throw Failure(description: "couldn't unpack uBO") }
        return directory
    }

    /// Builds adblock-rust resource JSON from an extracted uBO `src/` folder.
    static func build(from source: URL) throws -> Data {
        let scriptlets = try scriptletResources(js: source.appendingPathComponent("js"))
        var all = try JSONSerialization.jsonObject(with: scriptlets) as? [Any] ?? []
        #if canImport(KiteAdblock)
        if let redirects = AdblockEngine.redirectResources(
            directory: source.appendingPathComponent("web_accessible_resources"),
            index: source.appendingPathComponent("js/redirect-resources.js")
        ), let list = try JSONSerialization.jsonObject(with: redirects) as? [Any] {
            all += list
        }
        #endif
        return try JSONSerialization.data(withJSONObject: all)
    }

    /// Bundles uBO's scriptlet modules into one script and runs it in a bare
    /// JavaScriptCore context (no DOM, no network) to read each scriptlet's source.
    static func scriptletResources(js: URL) throws -> Data {
        var files: [String: String] = [:]
        var queue = ["resources/scriptlets.js"]
        while let path = queue.popLast() {
            guard files[path] == nil else { continue }
            // Module paths come from import statements; keep them inside uBO's folder.
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else {
                throw Failure(description: "unexpected import \(path)")
            }
            let source = try String(contentsOf: js.appendingPathComponent(path), encoding: .utf8)
            files[path] = source
            queue += ScriptletBundle.importedPaths(of: source, at: path)
        }
        let script = try ScriptletBundle.make(files: files)
        guard let context = JSContext() else { throw Failure(description: "no JavaScript context") }
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        context.evaluateScript(script)
        let description = context.evaluateScript(ScriptletBundle.describeScript)?.toString()
        if let failure { throw Failure(description: "uBO scriptlets: \(failure)") }
        guard let description else { throw Failure(description: "uBO scriptlets: no output") }
        return try ScriptletBundle.resources(fromDescription: Data(description.utf8))
    }
}

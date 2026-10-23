import Foundation

/// Turns uBlock Origin's scriptlet ES modules (`src/js/resources/*.js` and the few
/// `src/js/*.js` files they import) into one classic script that defines
/// `builtinScriptlets`, so a plain JavaScript context can evaluate it.
///
/// Each module becomes a function scope that returns its exports; imports become
/// destructuring of earlier modules. Modules are emitted in dependency order.
public enum ScriptletBundle {
    public struct BundleError: Error, CustomStringConvertible {
        public let description: String
    }

    /// `files` maps a path relative to uBO's `src/js/` (e.g. "resources/scriptlets.js") to its source.
    public static func make(files: [String: String], entry: String = "resources/scriptlets.js") throws -> String {
        var order: [String] = []
        var visiting: Set<String> = []
        func visit(_ path: String) throws {
            if order.contains(path) { return }
            guard !visiting.contains(path) else { throw BundleError(description: "import cycle at \(path)") }
            guard let source = files[path] else { throw BundleError(description: "missing module \(path)") }
            visiting.insert(path)
            for item in imports(in: source) { try visit(resolve(item.from, relativeTo: path)) }
            visiting.remove(path)
            order.append(path)
        }
        try visit(entry)

        var script = "\"use strict\";\n"
        for path in order {
            let source = files[path]!
            var body = ""
            for item in imports(in: source) where !item.names.isEmpty {
                let module = moduleVariable(resolve(item.from, relativeTo: path))
                let bindings = item.names.map { $0.local == $0.imported ? $0.local : "\($0.imported): \($0.local)" }
                body += "const { \(bindings.joined(separator: ", ")) } = \(module);\n"
            }
            body += stripModuleSyntax(source)
            let exported = exports(in: source)
            script += "const \(moduleVariable(path)) = (() => {\n\(body)\nreturn { \(exported.joined(separator: ", ")) };\n})();\n"
        }
        script += "var builtinScriptlets = \(moduleVariable(entry)).builtinScriptlets;\n"
        return script
    }

    /// Every module path the entry needs, so callers know which files to read.
    public static func importedPaths(of source: String, at path: String) -> [String] {
        imports(in: source).map { resolve($0.from, relativeTo: path) }
    }

    // MARK: Parsing

    struct Import {
        var names: [(imported: String, local: String)]
        var from: String
    }

    private static let importPattern = try! NSRegularExpression(
        pattern: #"^import\s+(?:\{([^}]*)\}\s*from\s*)?['"]([^'"]+)['"]\s*;?"#,
        options: [.anchorsMatchLines]
    )
    private static let exportPattern = try! NSRegularExpression(
        pattern: #"^export\s+(?:async\s+)?(?:function\*?|const|let|var|class)\s+([A-Za-z_$][\w$]*)"#,
        options: [.anchorsMatchLines]
    )

    static func imports(in source: String) -> [Import] {
        let range = NSRange(source.startIndex..., in: source)
        return importPattern.matches(in: source, range: range).map { match in
            let list = Range(match.range(at: 1), in: source).map { String(source[$0]) } ?? ""
            let names = list.split(separator: ",").compactMap { part -> (String, String)? in
                let words = part.split(whereSeparator: \.isWhitespace).map(String.init)
                switch words.count {
                case 1: return (words[0], words[0])
                case 3 where words[1] == "as": return (words[0], words[2])
                default: return nil
                }
            }
            return Import(names: names, from: String(source[Range(match.range(at: 2), in: source)!]))
        }
    }

    static func exports(in source: String) -> [String] {
        let range = NSRange(source.startIndex..., in: source)
        return exportPattern.matches(in: source, range: range).map { String(source[Range($0.range(at: 1), in: source)!]) }
    }

    static func stripModuleSyntax(_ source: String) -> String {
        let range = NSRange(source.startIndex..., in: source)
        let withoutImports = importPattern.stringByReplacingMatches(in: source, range: range, withTemplate: "")
        return withoutImports.replacingOccurrences(
            of: #"(?m)^export\s+(?=(async\s+)?(function|const|let|var|class)\b)"#,
            with: "",
            options: .regularExpression
        )
    }

    static func resolve(_ specifier: String, relativeTo path: String) -> String {
        var parts = path.split(separator: "/").dropLast().map(String.init)
        for component in specifier.split(separator: "/") {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(String(component))
            }
        }
        return parts.joined(separator: "/")
    }

    private static func moduleVariable(_ path: String) -> String {
        "__module_" + path.map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined()
    }
}

extension ScriptletBundle {
    /// Script to evaluate after `make`'s bundle: describes every scriptlet as JSON.
    public static let describeScript = """
        JSON.stringify(builtinScriptlets.map(d => ({
          name: d.name, aliases: d.aliases || [], source: d.fn.toString(),
          dependencies: d.dependencies || [], requiresTrust: !!d.requiresTrust
        })))
        """

    /// Turns `describeScript`'s output into adblock-rust `Resource` JSON. Callable
    /// scriptlets (`*.js`) are `application/javascript`; their helpers (`*.fn`) are
    /// `fn/javascript`, which adblock-rust only includes as dependencies.
    public static func resources(fromDescription json: Data) throws -> Data {
        struct Scriptlet: Decodable {
            var name: String
            var aliases: [String]
            var source: String
            var dependencies: [String]
            var requiresTrust: Bool
        }
        let scriptlets = try JSONDecoder().decode([Scriptlet].self, from: json)
        let resources: [[String: Any]] = scriptlets.map { item in
            var resource: [String: Any] = [
                "name": item.name,
                "aliases": item.aliases,
                "kind": ["mime": item.name.hasSuffix(".fn") ? "fn/javascript" : "application/javascript"],
                "content": Data(item.source.utf8).base64EncodedString(),
                "dependencies": item.dependencies,
            ]
            if item.requiresTrust { resource["permission"] = 1 }
            return resource
        }
        return try JSONSerialization.data(withJSONObject: resources)
    }
}

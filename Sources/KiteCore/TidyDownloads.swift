import Foundation

/// Arc Max's Tidy Downloads: a finished download gets a short, readable name from AI, keeping
/// its extension, and a "Download renamed!" toast offers Undo. Kite asks its own Claude
/// (headless `claude -p`). Sources and what's inferred are in docs/arc-visual-spec.md.
public enum TidyDownloads {
    /// Settings key. Arc's is `renameDownloadsEnabled` (on in Gabe's Arc), so Kite's is on too
    /// until turned off from the Kite menu.
    public static let enabledKey = "tidyDownloadsEnabled"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? true
    }

    /// Arc's toast copy.
    public static let renamedMessage = "Download renamed!"
    public static let revertedMessage = "Download name reverted!"

    /// What Claude is asked. Arc's request gives the model the original filename, the source tab's
    /// title and the source domain, asks for 2-4 readable words, and wants the answer in the
    /// user's language. The wording and examples here are Kite's own.
    public static func prompt(fileName: String, tabTitle: String?, domain: String?, language: String) -> String {
        """
        Someone just downloaded a file. Suggest a better filename: short (about 2 to 4 words), \
        clear and easy to read.
        - If the name already says what the file is, keep it close to the original.
        - If it doesn't, use the tab title or the website to say what it is.
        - Drop machine noise: long ID numbers, hashes, "(1)", "copy", "final_v2" and the like.
        - Shorten dates and times so a person can read them at a glance; no seconds.
        - Use normal spaces and capitalisation instead of underscores, dashes or run-together words.
        - Keep the file's extension.
        Examples (original name | tab title | site -> new name):
        - 'IMG_20240512_183355.jpg' | 'Trip photos - Google Drive' | 'drive.google.com' -> 'Trip photo May 12.jpg'
        - 'invoice-INV-0042-8f3a9c.pdf' | 'Billing - Acme Cloud' | 'acme.example' -> 'Acme invoice 0042.pdf'
        - 'kite-2.3.0-arm64.dmg' | 'Download Kite' | 'kite.example' -> 'Kite 2.3.0 arm64.dmg'
        - 'download.csv' | 'Monthly sales report - Dashboard' | 'stats.example' -> 'Monthly sales report.csv'
        Write the new name in \(language). Reply with JSON only: {"newName": "<the new filename>"}

        Original filename: '\(fileName)'
        Source tab title: '\(tabTitle ?? "")'
        Source domain: '\(domain ?? "")'
        """
    }

    /// The structured answer Claude Code is held to (`--json-schema`).
    public static let schema = #"{"type":"object","properties":{"newName":{"type":"string"}},"required":["newName"]}"#

    /// `claude -p` for one name: the fast model, no tools, no MCP servers, no settings or
    /// session left behind. The prompt goes on stdin.
    public static func arguments(model: String = "haiku") -> [String] {
        ["-p", "--model", model, "--tools", "", "--strict-mcp-config", "--no-session-persistence",
         "--disable-slash-commands", "--setting-sources", "", "--output-format", "json", "--json-schema", schema]
    }

    /// The name out of Claude Code's `--output-format json` result: `structured_output.newName`,
    /// else a JSON object in `result`.
    public static func name(fromClaudeOutput output: String) -> String? {
        guard let data = output.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["is_error"] as? Bool != true else { return nil }
        if let structured = object["structured_output"] as? [String: Any], let name = structured["newName"] as? String {
            return name
        }
        guard var result = object["result"] as? String else { return nil }
        if let start = result.firstIndex(of: "{"), let end = result.lastIndex(of: "}"), start < end {
            result = String(result[start...end])
        }
        guard let inner = result.data(using: .utf8),
              let answer = try? JSONSerialization.jsonObject(with: inner) as? [String: Any] else { return nil }
        return answer["newName"] as? String
    }

    /// The extension a rename keeps, without its dot: "pdf", or "tar.gz" for compressed tarballs.
    public static func fileExtension(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "" }
        let base = (name as NSString).deletingPathExtension
        if (base as NSString).pathExtension.lowercased() == "tar", base.count > 4 { return "tar.\(ext)" }
        return ext
    }

    /// Longest name Kite keeps before the extension (macOS allows 255 bytes in all).
    public static let maxBaseLength = 120

    /// Claude's suggestion made safe to use as `original`'s new name: one path component, no
    /// leading dot, the original extension exactly as it was. Nil when there's nothing usable or
    /// it's the same name.
    public static func tidiedName(_ proposed: String, original: String) -> String? {
        let ext = fileExtension(of: original)
        var base = proposed
        // Whatever the model did to the extension, the original's goes back on.
        if !ext.isEmpty, base.lowercased().hasSuffix("." + ext.lowercased()) {
            base = String(base.dropLast(ext.count + 1))
        } else if !ext.isEmpty, let dot = base.lastIndex(of: "."),
                  base.distance(from: dot, to: base.endIndex) <= 6,
                  base[base.index(after: dot)...].allSatisfy({ $0.isLetter || $0.isNumber }),
                  !base[base.index(after: dot)...].allSatisfy(\.isNumber) {
            // The model swapped or re-cased the extension ("x.jpeg" for ".jpg"): drop its version.
            base = String(base[..<dot])
        }
        base = String(base.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) { return " " }
            if scalar == "/" || scalar == ":" || scalar == "\\" { return "-" }
            return Character(scalar)
        })
        base = base.split(whereSeparator: { $0 == " " }).joined(separator: " ")
        base = base.trimmingCharacters(in: CharacterSet(charactersIn: " .").union(.whitespacesAndNewlines))
        if base.count > maxBaseLength {
            base = String(base.prefix(maxBaseLength)).trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        }
        // Arc refuses an empty name or one starting with "." (a hidden file).
        guard !base.isEmpty, !base.hasPrefix(".") else { return nil }
        let name = ext.isEmpty ? base : "\(base).\(ext)"
        return name == original ? nil : name
    }

    /// `name`, or "Name 2.ext", "Name 3.ext"… when `exists` says it's taken, the way Kite numbers
    /// downloads that would collide.
    public static func available(_ name: String, exists: (String) -> Bool) -> String {
        guard exists(name) else { return name }
        let ext = fileExtension(of: name)
        let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
        var n = 2
        while true {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            if !exists(candidate) { return candidate }
            n += 1
        }
    }

    /// The language Claude names files in: the user's first preferred language, in English.
    public static func languageName(preferred: [String] = Locale.preferredLanguages) -> String {
        guard let code = preferred.first.map({ Locale(identifier: $0).language.languageCode?.identifier ?? $0 }),
              let name = Locale(identifier: "en").localizedString(forLanguageCode: code) else { return "English" }
        return name
    }
}

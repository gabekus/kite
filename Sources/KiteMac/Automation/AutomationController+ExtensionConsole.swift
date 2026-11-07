import AppKit
import KiteCore

// read_console_messages with `extension`: an extension's background worker, not a tab.
// Kite is attached to every extension's worker from launch (ExtensionTabsBridge), so its
// console is there to read even when nobody was driving a tab, such as when 1Password's
// "Unlock 1Password" button fails inside its worker.
extension AutomationController {
    func readExtensionConsole(_ name: String, pattern: String?, onlyErrors: Bool, limit: Int, clear: Bool) throws -> ToolOutput {
        #if canImport(CEFBridge)
        guard let report = ExtensionTabsBridge.consoleReport(extension: name, pattern: pattern, onlyErrors: onlyErrors,
                                                            limit: limit, clear: clear) else {
            let known = ExtensionTabsBridge.knownExtensions
            throw AutomationError(.notFound, "No extension worker matches \"\(name)\"."
                + (known.isEmpty ? " Kite isn't attached to any extension's worker yet." : " Kite sees: \(known.joined(separator: ", "))."))
        }
        return .text(UntrustedContent.wrap(report, source: "console of extension \(name)"))
        #else
        throw AutomationError(.unsupported, "Extensions run only in Chromium tabs.")
        #endif
    }
}

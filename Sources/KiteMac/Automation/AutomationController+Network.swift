import Foundation
import KiteCore

// The network log tools. They read the log Kite keeps in memory, so a call
// costs a socket round trip and no page work; only bodies go back to Chromium.

extension AutomationController {
    /// Checks the tab id and leaves out tabs the user took back from Claude.
    func networkQuery(_ query: NetworkLog.Query) throws -> NetworkLog.Query {
        var query = query
        if let tab = query.tab {
            guard let id = UUID(uuidString: tab.trimmingCharacters(in: .whitespaces)) else {
                throw AutomationError(.invalidArguments, "\"\(tab)\" isn't a tab id. Call tabs_context for ids.")
            }
            if isRevoked(id) { throw AutomationError.stopped }
            query.tab = id.uuidString
        }
        query.excludedTabs = Set(revokedTabs.map(\.uuidString))
        return query
    }

    func networkRequest(_ seq: Int, body: Bool, maxBodyLength: Int) async throws -> ToolOutput {
        guard let entry = network.entry(seq), !(UUID(uuidString: entry.tab).map { isRevoked($0) } ?? false) else {
            throw AutomationError(.notFound, "There's no request #\(seq) in the log (it keeps the newest \(NetworkLog.capacity)). "
                + "Call network_log for ids.")
        }
        var lines = [NetworkLog.detail(entry, headers: true)]
        if body && maxBodyLength > 0 {
            let actions = networkActions(entry.tab)
            if entry.hasRequestBody {
                if let actions, let sent = try? await actions.requestBody(requestID: entry.requestID) {
                    lines.append("Request body (\(sent.count) characters):\n" + Self.clip(Redaction.body(sent), maxBodyLength))
                } else {
                    lines.append("Request body: no longer available.")
                }
            }
            if entry.status != nil, entry.failure == nil, entry.redirectedTo == nil {
                if let actions, let response = try? await actions.responseBody(requestID: entry.requestID) {
                    if response.base64 {
                        lines.append("Response body: binary, \(response.body.count * 3 / 4) bytes (not shown).")
                    } else if response.body.isEmpty {
                        lines.append("Response body: empty.")
                    } else {
                        lines.append("Response body (\(response.body.count) characters):\n"
                            + Self.clip(Redaction.body(response.body), maxBodyLength))
                    }
                } else {
                    lines.append("Response body: no longer available (Chromium let it go, or the tab's page closed).")
                }
            }
        }
        return .text(UntrustedContent.wrap(lines.joined(separator: "\n"), source: "network request #\(seq)"))
    }

    func exportHAR(_ query: NetworkLog.Query, bodies: Bool) async throws -> ToolOutput {
        let entries = network.matching(query).shown
        guard !entries.isEmpty else { return .text("No requests match, so there's nothing to export.") }
        var texts: [Int: (text: String, base64: Bool)] = [:]
        if bodies {
            for entry in entries where entry.status != nil && entry.failure == nil && entry.redirectedTo == nil
                && Self.isText(entry.mimeType) {
                guard let actions = networkActions(entry.tab),
                      let response = try? await actions.responseBody(requestID: entry.requestID), !response.base64 else { continue }
                texts[entry.seq] = (Redaction.body(String(response.body.prefix(Self.maxExportBody))), false)
            }
        }
        let url = try networkStore.export(network.har(entries, bodies: texts))
        var summary = "Wrote \(entries.count) request\(entries.count == 1 ? "" : "s")"
        if bodies { summary += " (\(texts.count) with bodies)" }
        return .text(summary + " to \(url.path)\nSecrets in URLs, headers and bodies are redacted. Kite deletes exports after "
            + "\(NetworkLogStore.retentionDays) days.")
    }

    static let maxExportBody = 1_000_000

    static func isText(_ mimeType: String?) -> Bool {
        guard let mime = mimeType?.lowercased() else { return false }
        return mime.hasPrefix("text/") || ["json", "javascript", "xml", "x-www-form-urlencoded", "graphql"].contains { mime.contains($0) }
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "… (\(text.count - limit) more characters; raise max_body_length to see them)" : text
    }
}

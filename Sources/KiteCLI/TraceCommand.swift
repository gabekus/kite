import Foundation
import KiteCore

/// `kite trace`: reads Kite's action trace (`<support>/Traces/*.jsonl`) straight from the profile, so it works
/// whether or not Kite is running. Kite writes it every half second, so the last half second may not be there yet.
enum TraceCommand {
    static let defaultSince: TimeInterval = 3600

    static func run(_ args: Arguments, supportDirectory: URL) throws -> Int32 {
        let action = args.positional.first ?? "timeline"
        guard ["timeline", "export", "resources", "summary"].contains(action) else {
            throw CLIError("kite trace takes export, resources or summary (or nothing for the timeline), not \"\(action)\".")
        }
        var since = defaultSince
        if let text = args.options["--since"] {
            guard let seconds = TraceReport.duration(text) else { throw CLIError("--since is a duration like 90s, 15m, 1h or 2d.") }
            since = seconds
        } else if action == "export", args.options["--session"] != nil {
            // A session's export takes everything kept.
            since = Double(TraceStore.retentionDays) * 86400
        }
        if let actor = args.options["--actor"], !["user", "agent", "kite"].contains(actor.lowercased()) {
            throw CLIError("--actor is user, agent or kite.")
        }
        let query = TraceReport.Query(since: Date().addingTimeInterval(-since), session: args.options["--session"],
                                      tab: args.options["--tab"], actor: args.options["--actor"]?.lowercased())
        let directory = TraceStore.directory(supportDirectory: supportDirectory)
        let records = TraceReport.filter(TraceStore.read(directory: directory, since: query.since), query)

        if action == "export" || args.flags.contains("--json") {
            var out = Data()
            for record in records {
                guard var line = try? record.encoded() else { continue }
                line.append(0x0A)
                out.append(line)
            }
            FileHandle.standardOutput.write(out)
            return 0
        }
        if action == "resources" {
            let limit = args.options["--limit"].flatMap(Int.init) ?? 10
            print(TraceReport.resources(records, limit: limit))
            return 0
        }
        if records.isEmpty {
            let where_ = FileManager.default.fileExists(atPath: directory.path) ? "" : " (no trace at \(directory.path) yet)"
            print("No trace records in this window\(where_). Record Action Trace is in Kite's Settings › Advanced.")
            return 0
        }
        if action == "timeline" {
            print(TraceReport.timeline(records))
            print("")
        }
        print(TraceReport.summaryText(TraceReport.summary(records)))
        return 0
    }
}

import Foundation
import KiteCore

/// `vpn` with action reconnect: has the VPN client on this Mac connect again. It runs here, in the
/// CLI (as the user, from their terminal or Claude), not in Kite, which may not script other apps.
/// Only connects and disconnects: it never imports, edits or removes a VPN profile.
enum VPNClient {
    static let tunnelblick = "/Applications/Tunnelblick.app"
    /// OpenVPN Connect 3 installs into a folder of its own; older versions sat in /Applications.
    static let openVPNConnect = [
        "/Applications/OpenVPN Connect/OpenVPN Connect.app/Contents/MacOS/OpenVPN Connect",
        "/Applications/OpenVPN Connect.app/Contents/MacOS/OpenVPN Connect",
    ]

    /// What happened, for the tool's result. `started` is false when nothing was asked to connect.
    struct Result {
        var started: Bool
        var message: String
    }

    static func reconnect(profile: String?) -> Result {
        let files = FileManager.default
        if files.fileExists(atPath: tunnelblick) { return reconnectTunnelblick(profile) }
        if let connect = openVPNConnect.first(where: files.isExecutableFile) { return reconnectOpenVPNConnect(connect, profile) }
        return Result(started: false, message: "No VPN client Kite knows (Tunnelblick, OpenVPN Connect) is installed on this Mac, "
            + "so nothing was asked to reconnect. Kite still handles a sign-in page the client opens itself.")
    }

    /// Tunnelblick's AppleScript: `connect` and `disconnect` take a configuration's name.
    private static func reconnectTunnelblick(_ profile: String?) -> Result {
        let names = (osascript(#"tell application "Tunnelblick" to get name of configurations"#).output ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let name: String
        if let profile {
            guard names.contains(profile) else {
                return Result(started: false, message: "Tunnelblick has no configuration called \(profile). It has: \(names.joined(separator: ", ")).")
            }
            name = profile
        } else if names.count == 1 {
            name = names[0]
        } else {
            return Result(started: false, message: names.isEmpty ? "Tunnelblick has no configurations."
                : "Tunnelblick has several configurations; pass profile, one of: \(names.joined(separator: ", ")).")
        }
        let quoted = "\"" + name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        _ = osascript("tell application \"Tunnelblick\" to disconnect \(quoted)")
        let connect = osascript("tell application \"Tunnelblick\" to connect \(quoted)")
        guard connect.status == 0 else {
            return Result(started: false, message: "Tunnelblick didn't connect \(name): \(connect.error ?? "unknown error").")
        }
        return Result(started: true, message: "Asked Tunnelblick to reconnect \(name).")
    }

    /// OpenVPN Connect's command line (`--list-profiles`, `--connect-shortcut=PROFILE_ID`).
    private static func reconnectOpenVPNConnect(_ app: String, _ profile: String?) -> Result {
        guard let profile else {
            let list = run(app, ["--list-profiles"])
            return Result(started: false, message: "OpenVPN Connect needs the profile to connect: pass profile, its id from this list.\n"
                + (list.output ?? list.error ?? "(it listed nothing)"))
        }
        let connect = run(app, ["--connect-shortcut=\(profile)"])
        guard connect.status == 0 else {
            return Result(started: false, message: "OpenVPN Connect didn't connect \(profile): \(connect.error ?? connect.output ?? "exit \(connect.status)").")
        }
        return Result(started: true, message: "Asked OpenVPN Connect to connect \(profile).")
    }

    private static func osascript(_ script: String) -> (status: Int32, output: String?, error: String?) {
        run("/usr/bin/osascript", ["-e", script])
    }

    private static func run(_ path: String, _ arguments: [String]) -> (status: Int32, output: String?, error: String?) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return (-1, nil, error.localizedDescription) }
        let output = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        func text(_ data: Data) -> String? {
            let string = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            return string.isEmpty ? nil : string
        }
        return (process.terminationStatus, text(output), text(errors))
    }

    /// A tool call from `kite mcp` or a subcommand: vpn reconnect runs the client here first.
    static func route(_ tool: String, _ arguments: JSONValue, through connection: KiteConnection) async -> ToolOutput {
        guard tool == AutomationCommand.Tool.vpn.rawValue, arguments["action"]?.stringValue == "reconnect" else {
            return await connection.call(tool, arguments)
        }
        return await call(arguments, through: connection)
    }

    /// Runs the client for a reconnect call, then has Kite wait for the sign-in it opens.
    static func call(_ arguments: JSONValue, through connection: KiteConnection) async -> ToolOutput {
        guard case .object(var json) = arguments else { return await connection.call("vpn", arguments) }
        let profile = json["profile"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let client = reconnect(profile: profile)
        guard client.started else {
            let status = await connection.call("vpn", ["action": "status"])
            return ToolOutput(content: [.text(client.message + "\n" + status.text)], isError: status.isError)
        }
        json["action"] = "wait"
        json.removeValue(forKey: "profile")
        let waited = await connection.call("vpn", .object(json))
        return ToolOutput(content: [.text(client.message + "\n" + waited.text)], isError: waited.isError)
    }
}

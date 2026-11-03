import Foundation

/// Where Kite keeps its profile (session, history, Chromium's data) on any platform.
///
/// `KITE_SUPPORT_PATH` overrides it for test runs. An override that isn't an existing
/// directory is refused rather than created or ignored: on macOS a bad path once made
/// Chromium fall back to the user's own Chromium profile and change it.
public enum SupportDirectory {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case overrideIsNotADirectory(String)

        public var description: String {
            switch self {
            case .overrideIsNotADirectory(let path):
                "KITE_SUPPORT_PATH is not an existing directory: \(path)"
            }
        }
    }

    public static let overrideVariable = "KITE_SUPPORT_PATH"

    /// `platformDefault` is used when there's no override (on Windows, %LOCALAPPDATA%\Kite).
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        platformDefault: @autoclosure () -> URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard let override = environment[overrideVariable], !override.isEmpty else {
            return platformDefault()
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: override, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure.overrideIsNotADirectory(override)
        }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    /// The Windows default, %LOCALAPPDATA%\Kite (where Chrome keeps "User Data" too).
    /// Nil when LOCALAPPDATA isn't set.
    public static func windowsDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        guard let local = environment["LOCALAPPDATA"], !local.isEmpty else { return nil }
        return URL(fileURLWithPath: local, isDirectory: true).appendingPathComponent("Kite", isDirectory: true)
    }
}

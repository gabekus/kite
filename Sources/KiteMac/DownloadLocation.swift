import AppKit
import KiteCore
#if canImport(CEFBridge)
import CEFBridge
#endif

/// Profile settings › Download location, for both engines: the profile's folder (Downloads
/// unless one was chosen with Other…), and whether to ask each time.
@MainActor
enum DownloadLocation {
    private static var store: BrowserStore? { (NSApp.delegate as? AppDelegate)?.browserStore }

    /// The settings of the profile in `directory`; nil (incognito) reads the default profile's.
    static func settings(profile directory: String?) -> ProfileSettings {
        store?.state.settings(ofProfile: directory) ?? ProfileSettings()
    }

    /// Where downloads go when no folder was chosen: the user's Downloads, or a test run's own
    /// folder (never the user's Downloads from a throwaway profile).
    static var defaultFolder: URL {
        let environment = ProcessInfo.processInfo.environment
        if let test = environment["KITE_TEST_DOWNLOADS_PATH"], !test.isEmpty, environment["KITE_SUPPORT_PATH"] != nil {
            return URL(fileURLWithPath: test, isDirectory: true)
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
    }

    /// The folder for the profile's downloads; a chosen folder that has gone falls back to Downloads.
    static func folder(profile directory: String?) -> URL {
        settings(profile: directory).downloadFolder(downloads: defaultFolder) { path in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func setFolder(_ url: URL, profile directory: String?) {
        store?.mutate { state in
            state.updateSettings(ofProfile: directory) {
                $0.downloadDirectory = url.standardizedFileURL.path == defaultFolder.standardizedFileURL.path ? nil : url.path
                $0.promptsForDownload = false
            }
        }
    }

    static func setPrompts(_ prompts: Bool, profile directory: String?) {
        store?.mutate { state in state.updateSettings(ofProfile: directory) { $0.promptsForDownload = prompts } }
    }

    /// Arc's Other…: a folder panel opened in the current folder, with "Select" to confirm.
    static func chooseFolder(profile directory: String?) {
        let panel = NSOpenPanel()
        panel.directoryURL = folder(profile: directory)
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setFolder(url, profile: directory)
    }

    /// Hands Chromium the profile's folder as each download starts.
    static func installForChromium() {
        #if canImport(CEFBridge)
        KCBrowser.downloadFolderProvider = { directory, prompt in
            prompt.pointee = ObjCBool(settings(profile: directory).promptsForDownload)
            return folder(profile: directory)
        }
        #endif
    }
}

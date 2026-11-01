import Foundation

/// Settings Arc keeps per profile, beside its search engine (Arc's profile preferences state:
/// `downloadFilePath`, `promptForDownloadFilePath`, `searchSuggestEnabled`; Chromium keeps the
/// same three as `download.default_directory`, `download.prompt_for_download` and
/// `search.suggest_enabled` in each profile's Preferences).
public struct ProfileSettings: Hashable, Codable, Sendable {
    /// The folder downloads save into; nil is the user's Downloads folder.
    public var downloadDirectory: String?
    /// Arc's "Ask" choice: a save panel for every download, starting in `downloadDirectory`.
    public var promptsForDownload: Bool
    /// "Include search engine suggestions": the command bar asks the search engine what to
    /// suggest as you type. On by default, as in Arc.
    public var includesSearchSuggestions: Bool

    public init(downloadDirectory: String? = nil, promptsForDownload: Bool = false, includesSearchSuggestions: Bool = true) {
        self.downloadDirectory = downloadDirectory
        self.promptsForDownload = promptsForDownload
        self.includesSearchSuggestions = includesSearchSuggestions
    }

    private enum CodingKeys: String, CodingKey {
        case downloadDirectory, promptsForDownload, includesSearchSuggestions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        downloadDirectory = try c.decodeIfPresent(String.self, forKey: .downloadDirectory)
        promptsForDownload = try c.decodeIfPresent(Bool.self, forKey: .promptsForDownload) ?? false
        includesSearchSuggestions = try c.decodeIfPresent(Bool.self, forKey: .includesSearchSuggestions) ?? true
    }

    /// The folder to save into: the chosen one while it still exists, else `downloads`.
    public func downloadFolder(downloads: URL, exists: (String) -> Bool) -> URL {
        guard let downloadDirectory, exists(downloadDirectory) else { return downloads }
        return URL(fileURLWithPath: downloadDirectory, isDirectory: true)
    }
}

extension BrowserState {
    /// The settings of the profile in `directory` (nil, an incognito window, uses the default
    /// profile's, as Arc reads them from the non-incognito profile).
    public func settings(ofProfile directory: String?) -> ProfileSettings {
        profileSettings[profile(directory).dataStoreID.uuidString] ?? ProfileSettings()
    }

    public mutating func updateSettings(ofProfile directory: String?, _ change: (inout ProfileSettings) -> Void) {
        let key = profile(directory).dataStoreID.uuidString
        var settings = profileSettings[key] ?? ProfileSettings()
        change(&settings)
        profileSettings[key] = settings == ProfileSettings() ? nil : settings
    }
}

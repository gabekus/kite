import Foundation

/// What View › Show Toolbar's bar prints for the page's address. Arc's setting "Show full URL
/// when Toolbar is enabled" (`toolbarShowFullURLsEnabledPreference`) switches its toolbar
/// between a short and a long title (`displayTitleShort` / `displayTitleLong`). Evidence and
/// what's inferred are in docs/arc-visual-spec.md.
public enum ToolbarURL {
    /// Settings key. Unset in Gabe's Arc, which reads it as a plain bool, so off by default.
    public static let showsFullURLKey = "toolbarShowFullURLs"

    public static func showsFullURL(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: showsFullURLKey) as? Bool ?? false
    }

    /// Off: the host, as the toolbar has always shown it. On: the whole address, with scheme,
    /// path, query and fragment. A URL without a host (about:blank, data:) shows in full either way.
    public static func text(for url: URL?, full: Bool) -> String {
        guard let url else { return "" }
        guard !full, let host = url.host(), !host.isEmpty else {
            return url.absoluteString
        }
        return host
    }
}

import Foundation

/// Arc's site permission prompt (its `PermissionRequests` module): the words it shows when a
/// site asks for the camera, microphone, location or notifications. Strings are Arc 1.171's own,
/// read from its binary (see docs/arc-visual-spec.md, "Site permission prompt").
public enum PermissionPrompt {
    /// Arc's buttons: "Not Now" (deny) and "Allow".
    public static let allowTitle = "Allow"
    public static let denyTitle = "Not Now"
    /// The footer: "Click the lock" + the `lock.fill` symbol + " to change this any time".
    public static let footerBeforeLock = "Click the lock "
    public static let footerAfterLock = " to change this any time"
    public static let footerSymbol = "lock.fill"
    /// Arc's fallback when it has no title for the site.
    public static let fallbackSiteName = "this website"

    /// The site as the prompt names it: the origin's host (with a port that isn't the scheme's
    /// default), or Arc's fallback.
    public static func siteName(for origin: URL?) -> String {
        guard let host = origin?.host(), !host.isEmpty else { return fallbackSiteName }
        return host + (origin?.port.map { ":\($0)" } ?? "")
    }

    /// Arc's lower-case permission names (`ArcPermissionRequestType+Utils` display names).
    public static func displayName(_ permission: SitePermission) -> String {
        switch permission {
        case .camera: "camera"
        case .microphone: "microphone"
        case .location: "location"
        case .notifications: "notifications"
        }
    }

    /// The question, and where the site's name sits in it (Arc sets the name apart in its own
    /// font and colour). One notifications request: "Allow %@ to send you notifications?";
    /// anything else: "Allow %@ to access your %@?" with the permission names.
    public static func title(site: String, permissions: [SitePermission]) -> (text: String, siteRange: Range<String.Index>) {
        let lead = "Allow "
        let rest: String
        if permissions == [.notifications] {
            rest = " to send you notifications?"
        } else {
            rest = " to access your \(joinedNames(permissions))?"
        }
        let text = lead + site + rest
        let start = text.index(text.startIndex, offsetBy: lead.count)
        return (text, start..<text.index(start, offsetBy: site.count))
    }

    /// "camera", "camera and microphone", "camera, microphone and location". How Arc joins several
    /// names wasn't read from its binary; this is English list style.
    public static func joinedNames(_ permissions: [SitePermission]) -> String {
        let names = permissions.map(displayName)
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        default: return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        }
    }

    /// The prompt's icon: the permission's own symbol (Site Controls' row icon); for camera and
    /// microphone together, the camera's.
    public static func symbol(for permissions: [SitePermission]) -> String {
        (permissions.first ?? .notifications).symbol
    }
}

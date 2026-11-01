import Foundation

/// Air Traffic Control: Arc's routes for links opened from other apps. Each route says
/// "if the URL is equal to / contains <text>, open it in <space or Little Arc>", and a default
/// route catches everything else. The model mirrors Arc's `LinkRouting` module (see
/// docs/arc-visual-spec.md, "Air Traffic Control"): a rule has URL components and a destination,
/// the state has the rules plus a default destination.
public enum AirTrafficControl {
    /// How a component compares its text with the link. Arc: `LinkSourceTextMatchingStyle`
    /// `matches` ("Is equal to") and `contains` ("Contains").
    public enum MatchStyle: String, Codable, CaseIterable, Sendable {
        case matches
        case contains

        /// The pop-up's titles, as Arc's dialog shows them.
        public var title: String {
            switch self {
            case .matches: return "Is equal to"
            case .contains: return "Contains"
            }
        }
    }

    /// One condition on the link's URL. Arc's `LinkSourceComponent` has a single component type,
    /// `urlMatch`; there is no source-app component in Arc's binary.
    public struct Component: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var style: MatchStyle
        public var pattern: String

        public init(id: UUID = UUID(), style: MatchStyle = .contains, pattern: String = "") {
            self.id = id
            self.style = style
            self.pattern = pattern
        }

        public func matches(_ url: URL) -> Bool {
            let needle = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !needle.isEmpty else { return false }
            switch style {
            case .contains:
                return url.absoluteString.lowercased().contains(needle)
            case .matches:
                // "Is equal to" accepts the site ("spotify.com") or the whole link, ignoring
                // scheme, "www." and a trailing slash. Arc's exact comparison wasn't found (inferred).
                let target = AirTrafficControl.normalized(needle)
                if let host = url.host?.lowercased(), AirTrafficControl.stripWWW(host) == target { return true }
                return AirTrafficControl.normalized(url.absoluteString.lowercased()) == target
            }
        }
    }

    /// Where a routed link opens. Arc's `LinkDestination` cases are `space`, `littleArc`,
    /// `profile` and `mostRecent`; Kite has no profiles, so there's no `profile` case.
    public enum Destination: Codable, Hashable, Sendable {
        case mostRecentSpace
        case littleKite
        case space(UUID)
    }

    /// A route. Arc's `LinkMatchingRule`: `sourceComponents` + `destination`.
    public struct Rule: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var components: [Component]
        public var destination: Destination

        public init(id: UUID = UUID(), components: [Component] = [Component()], destination: Destination = .littleKite) {
            self.id = id
            self.components = components
            self.destination = destination
        }

        /// Any one of the rule's URL components (inferred: Arc's dialog adds components with a
        /// plus button; whether they're "or" or "and" wasn't found).
        public func matches(_ url: URL) -> Bool {
            components.contains { $0.matches(url) }
        }
    }

    /// What's saved (LinkRouting.json). Arc's `StorableLinkRoutingState`: `version`, `rules`,
    /// `defaultDestination`. A nil default follows Kite menu → Open Links from Other Apps in
    /// Little Kite (Arc's `openExternalLinksInLittleBrowserEnabled`).
    public struct State: Codable, Equatable, Sendable {
        public var version: Int
        public var rules: [Rule]
        public var defaultDestination: Destination?

        public init(version: Int = 1, rules: [Rule] = [], defaultDestination: Destination? = nil) {
            self.version = version
            self.rules = rules
            self.defaultDestination = defaultDestination
        }

        /// The default route, resolved against the Little Kite setting.
        public func resolvedDefault(opensExternalLinksInLittleKite: Bool) -> Destination {
            defaultDestination ?? (opensExternalLinksInLittleKite ? .littleKite : .mostRecentSpace)
        }

        /// Where a link from another app goes: the first route that matches, else the default.
        /// A route to a space that no longer exists is skipped. Only web links are routed; files
        /// and other schemes open as a tab in the most recent space, as before.
        public func destination(
            for url: URL,
            spaceIDs: Set<UUID>,
            opensExternalLinksInLittleKite: Bool
        ) -> Destination {
            guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" else {
                return .mostRecentSpace
            }
            func valid(_ d: Destination) -> Bool {
                if case .space(let id) = d { return spaceIDs.contains(id) }
                return true
            }
            if let rule = rules.first(where: { $0.matches(url) && valid($0.destination) }) {
                return rule.destination
            }
            let fallback = resolvedDefault(opensExternalLinksInLittleKite: opensExternalLinksInLittleKite)
            return valid(fallback) ? fallback : .mostRecentSpace
        }
    }

    static func stripWWW(_ host: String) -> String {
        host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    static func normalized(_ text: String) -> String {
        var s = text
        for prefix in ["https://", "http://"] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        s = stripWWW(s)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

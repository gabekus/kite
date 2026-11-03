import Foundation

/// Air Traffic Control routes from Arc's `StorableLinkRouting.json`. Delete with ArcImport.swift
/// once Arc has shut down.
///
/// The shape, from a real file and Arc's coding keys (docs/arc-visual-spec.md, "Air Traffic
/// Control"): `{"version", "rules": [{"id", "sourceComponents": [{"id", "componentType":
/// {"urlMatch": {"_0": {"contains": {}}, "_1": "pattern"}}}], "destination": …}],
/// "defaultDestination": …}`. A destination is Swift's enum encoding of `LinkDestination`:
/// `{"space": {"_0": {"space": {"_0": "<space id>"}}}}`, `{"littleArc": {"_0": …}}`,
/// `{"mostRecent": {}}` or `{"profile": …}`.
public enum ArcLinkRoutingImport {
    public struct Result: Equatable, Sendable {
        public var rules: [AirTrafficControl.Rule]
        /// Arc's default when it's a space. Kite keeps a Little Kite or most-recent-space default
        /// as Open Links from Other Apps in Little Kite instead (`defaultOpensInLittleKite`).
        public var defaultSpace: UUID?
        /// Arc's default as that setting: true for Little Arc, false for the most recent space.
        public var defaultOpensInLittleKite: Bool?
        /// Routes to an Arc profile, which Kite's routes can't open in.
        public var profileRoutes: Int
        /// Routes Kite couldn't read.
        public var unreadable: Int

        public var isEmpty: Bool { rules.isEmpty && defaultSpace == nil }

        /// Leaves out routes to spaces Kite doesn't have, which would never open anything.
        public func keeping(spaces ids: Set<UUID>) -> Result {
            var result = self
            result.rules.removeAll { if case .space(let id) = $0.destination { !ids.contains(id) } else { false } }
            if let space = defaultSpace, !ids.contains(space) { result.defaultSpace = nil }
            return result
        }
    }

    public static func parse(_ data: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        var result = Result(rules: [], profileRoutes: 0, unreadable: 0)
        for raw in root["rules"] as? [Any] ?? [] {
            let object = raw as? [String: Any] ?? [:]
            if (object["destination"] as? [String: Any])?["profile"] != nil {
                result.profileRoutes += 1
                continue
            }
            let rawComponents = object["sourceComponents"] as? [Any] ?? []
            let components = rawComponents.compactMap(component)
            // The ID is what a second import replaces by, so a route without one is left out.
            guard let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)),
                  !components.isEmpty, components.count == rawComponents.count,
                  let destination = destination(object["destination"])
            else {
                result.unreadable += 1
                continue
            }
            result.rules.append(AirTrafficControl.Rule(id: id, components: components, destination: destination))
        }
        switch destination(root["defaultDestination"]) {
        case .space(let id): result.defaultSpace = id
        case .littleKite: result.defaultOpensInLittleKite = true
        case .mostRecentSpace: result.defaultOpensInLittleKite = false
        case nil: break
        }
        return result
    }

    private static func component(_ raw: Any) -> AirTrafficControl.Component? {
        guard let object = raw as? [String: Any],
              let match = (object["componentType"] as? [String: Any])?["urlMatch"] as? [String: Any],
              let pattern = match["_1"] as? String
        else { return nil }
        // Either a bare case name or Swift's enum encoding, {"contains": {}}. A style Kite doesn't
        // know could match far more than Arc did, so its component isn't read.
        let styleName = (match["_0"] as? String) ?? (match["_0"] as? [String: Any])?.keys.first
        guard let style = styleName.flatMap(AirTrafficControl.MatchStyle.init(rawValue:)) else { return nil }
        let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return AirTrafficControl.Component(id: id, style: style, pattern: pattern)
    }

    /// Little Arc opens in Little Kite, whichever space Arc would have put it in after.
    static func destination(_ raw: Any?) -> AirTrafficControl.Destination? {
        guard let object = raw as? [String: Any] else { return nil }
        if object["littleArc"] != nil { return .littleKite }
        if object["mostRecent"] != nil { return .mostRecentSpace }
        // Imported spaces keep Arc's IDs, so the route finds its space in Kite.
        let space = ((object["space"] as? [String: Any])?["_0"] as? [String: Any])?["space"] as? [String: Any]
        return (space?["_0"] as? String).flatMap(UUID.init(uuidString:)).map(AirTrafficControl.Destination.space)
    }
}

extension AirTrafficControl.State {
    /// Adds Arc's routes after Kite's own, replacing a route imported before (same ID), and takes
    /// Arc's default when it's a space. Returns how many routes were new.
    @discardableResult
    public mutating func merge(arc imported: ArcLinkRoutingImport.Result) -> Int {
        var added = 0
        for rule in imported.rules {
            if let index = rules.firstIndex(where: { $0.id == rule.id }) {
                rules[index] = rule
            } else {
                rules.append(rule)
                added += 1
            }
        }
        if let space = imported.defaultSpace { defaultDestination = .space(space) }
        return added
    }
}

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
        public var defaultDestination: AirTrafficControl.Destination?
        /// Routes left out: ones to an Arc profile, which Kite's routes can't open in, or that
        /// Kite couldn't read.
        public var skipped: Int

        public var isEmpty: Bool { rules.isEmpty && defaultDestination == nil }
    }

    public static func parse(_ data: Data) -> Result? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["rules"] as? [Any]
        else { return nil }
        var rules: [AirTrafficControl.Rule] = []
        var skipped = 0
        for case let raw as [String: Any] in list {
            let components = (raw["sourceComponents"] as? [Any] ?? []).compactMap(component)
            guard !components.isEmpty, let destination = destination(raw["destination"]) else {
                skipped += 1
                continue
            }
            let id = (raw["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            rules.append(AirTrafficControl.Rule(id: id, components: components, destination: destination))
        }
        return Result(rules: rules, defaultDestination: destination(root["defaultDestination"]), skipped: skipped)
    }

    private static func component(_ raw: Any) -> AirTrafficControl.Component? {
        guard let object = raw as? [String: Any],
              let match = (object["componentType"] as? [String: Any])?["urlMatch"] as? [String: Any],
              let pattern = match["_1"] as? String
        else { return nil }
        // Either a bare case name or Swift's enum encoding, {"contains": {}}.
        let styleName = (match["_0"] as? String) ?? (match["_0"] as? [String: Any])?.keys.first
        let id = (object["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
        return AirTrafficControl.Component(
            id: id,
            style: styleName.flatMap(AirTrafficControl.MatchStyle.init(rawValue:)) ?? .contains,
            pattern: pattern
        )
    }

    /// Little Arc opens in Little Kite, whichever space Arc would have put it in after.
    static func destination(_ raw: Any?) -> AirTrafficControl.Destination? {
        guard let object = raw as? [String: Any] else { return nil }
        if object["littleArc"] != nil { return .littleKite }
        if object["mostRecent"] != nil { return .mostRecentSpace }
        if let space = object["space"] {
            // Imported spaces keep Arc's IDs, so the route finds its space in Kite.
            return firstUUID(in: space).map(AirTrafficControl.Destination.space)
        }
        return nil
    }

    private static func firstUUID(in value: Any) -> UUID? {
        if let string = value as? String { return UUID(uuidString: string) }
        if let object = value as? [String: Any] {
            for key in object.keys.sorted() { if let id = firstUUID(in: object[key]!) { return id } }
        }
        if let list = value as? [Any] {
            for item in list { if let id = firstUUID(in: item) { return id } }
        }
        return nil
    }
}

extension AirTrafficControl.State {
    /// Adds Arc's routes after Kite's own, replacing a route imported before (same ID), and takes
    /// Arc's default. Returns how many routes were new.
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
        if let destination = imported.defaultDestination { defaultDestination = destination }
        return added
    }
}

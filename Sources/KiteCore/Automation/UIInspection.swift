import Foundation

/// A point in a Kite window, in points from the window's top-left corner (titlebar included,
/// since the content runs under it). Negative values and values past the edge are allowed, so
/// a sweep can start outside the window.
public struct UIPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A rectangle in the same window coordinates as `UIPoint`.
public struct UIRect: Hashable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(_ point: UIPoint) -> Bool {
        point.x >= x && point.x < x + width && point.y >= y && point.y < y + height
    }

    /// "x,y w×h" with at most two decimals, the way every ui report prints frames.
    public var description: String {
        "\(UIReport.number(x)),\(UIReport.number(y)) \(UIReport.number(width))×\(UIReport.number(height))"
    }
}

/// Synthetic input for Kite's own window. It never reaches another app, and never moves the real pointer.
public enum UIInputEvent: Hashable, Sendable {
    case keys([KeyChord])
    case text(String)
    case click(UIPoint, button: ComputerAction.Button, count: Int, modifiers: KeyChord.Modifiers)
    case drag(from: UIPoint, to: UIPoint, steps: Int)
    /// Wheel deltas in points; positive dy scrolls content up (like a swipe up on a trackpad).
    case scroll(UIPoint, dx: Double, dy: Double)
}

/// The `ui` tool: Kite's own native interface (window, sidebar, command bar, menus), read from
/// inside the app so nobody has to record the screen or drive the user's Mac.
/// Only answered while Diagnostics for Claude is on.
public enum UIInspection: Hashable, Sendable {
    /// Kite's windows: number, kind, frame, key/main, full screen, sidebar shown.
    case windows
    /// The view tree with frames, materials, corner radii, colours and fonts, and SwiftUI's
    /// accessibility elements inside hosting views. `root` is a node path like "0.3.1".
    case tree(window: Int?, root: String?, depth: Int, match: String?, layers: Bool, maxNodes: Int)
    /// Pixels of a window as they reach the screen (blur, Metal and web content included).
    /// `pixels` reads single pixels' colours as hex; with `image` false only those come back.
    case capture(window: Int?, region: UIRect?, format: ImageFormat, pixels: [UIPoint], image: Bool, save: String?)
    /// Synthetic pointer moves through the points: at each, the view hit, cursor rects, tracking
    /// areas and the cursor Kite sets.
    case pointer(window: Int?, points: [UIPoint])
    case input(window: Int?, event: UIInputEvent)
    /// The menu bar: every item's path, shortcut, action, target, enabled and hidden state.
    case menu(match: String?)
    /// Recent key presses and where each went: menu item, responder, text input.
    case keyLog(limit: Int, clear: Bool)
    /// Records animations and frame timing for `seconds`, optionally after pressing `keys`.
    case trace(window: Int?, seconds: Double, keys: [KeyChord]?, match: String?)

    public static let actions = ["windows", "tree", "capture", "pointer", "input", "menu", "key_log", "trace"]
    public static let defaultDepth = 12
    public static let defaultMaxNodes = 400
    public static let maxPointerSteps = 400

    public var isReadOnly: Bool {
        switch self {
        case .input, .trace(_, _, .some, _): false
        default: true
        }
    }

    public typealias Invalid = AutomationCommand.InvalidArguments

    public init(arguments values: [String: JSONValue]) throws {
        let a = UIArguments(values)
        let window = try a.int("window", in: 0...Int(Int32.max))
        switch try a.string("action") ?? "" {
        case "windows":
            self = .windows
        case "tree":
            let root = try a.string("root").flatMap { $0.isEmpty ? nil : $0 }
            if let root, !root.allSatisfy({ $0.isNumber || $0 == "." }) {
                throw Invalid("\"root\" is a node path from an earlier tree, like \"0.3.1\".")
            }
            self = .tree(window: window, root: root, depth: try a.int("depth", in: 1...60) ?? Self.defaultDepth,
                         match: try a.nonEmpty("match"), layers: try a.bool("layers"),
                         maxNodes: try a.int("max_nodes", in: 1...5000) ?? Self.defaultMaxNodes)
        case "capture":
            let format: ImageFormat
            switch try a.string("format")?.lowercased() {
            case nil, "png": format = .png
            case "jpeg", "jpg": format = .jpeg
            default: throw Invalid("\"format\" is png or jpeg.")
            }
            let pixels = try a.points("pixels") ?? []
            guard pixels.count <= 200 else { throw Invalid("At most 200 \"pixels\" at a time.") }
            let image = try a.values["image"].map { _ in try a.bool("image") } ?? pixels.isEmpty
            self = .capture(window: window, region: try a.rect("region"), format: format, pixels: pixels, image: image,
                            save: try a.nonEmpty("save"))
        case "pointer":
            let points: [UIPoint]
            if let list = try a.points("points") {
                guard !list.isEmpty else { throw Invalid("\"points\" is empty.") }
                points = list
            } else if let from = try a.point("from") {
                let to = try a.point("to") ?? from
                let steps = try a.int("steps", in: 1...Self.maxPointerSteps) ?? (from == to ? 1 : 10)
                points = steps == 1 && from == to ? [from] : (0...steps).map { i in
                    let t = Double(i) / Double(steps)
                    return UIPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                }
            } else {
                throw Invalid("Pass \"points\" [[x, y], …], or \"from\" (and \"to\" and \"steps\") for a sweep.")
            }
            guard points.count <= Self.maxPointerSteps + 1 else { throw Invalid("At most \(Self.maxPointerSteps + 1) points.") }
            self = .pointer(window: window, points: points)
        case "input":
            self = .input(window: window, event: try a.inputEvent())
        case "menu":
            self = .menu(match: try a.nonEmpty("match"))
        case "key_log":
            self = .keyLog(limit: try a.int("limit", in: 1...500) ?? 30, clear: try a.bool("clear"))
        case "trace":
            let seconds = try a.double("seconds") ?? 1.5
            guard seconds > 0, seconds <= 10 else { throw Invalid("\"seconds\" is more than 0 and at most 10.") }
            self = .trace(window: window, seconds: seconds, keys: try a.keys(), match: try a.nonEmpty("match"))
        case "":
            throw Invalid("\"action\" is required (\(Self.actions.joined(separator: ", "))).")
        case let other:
            throw Invalid("\"\(other)\" isn't a ui action (\(Self.actions.joined(separator: ", "))).")
        }
    }

    public static let summary = """
        Kite's own native UI (sidebar, card, command bar, menus, windows), read from inside the app: no screen recording, \
        no focus change, no real pointer. Needs Diagnostics for Claude on (Kite menu). Coordinates are points from the \
        window's top-left. Actions: windows; tree (views with frames, materials, radii, colours, fonts, SwiftUI elements; \
        root, depth, match, layers); capture (exact window pixels even when covered or in the background; region \
        [x,y,w,h], pixels [[x,y],…] for hex colours only); pointer (synthetic moves via points or from/to/steps: view hit, \
        cursor rects, tracking areas, cursor shown); input (keys, text, click, drag, scroll into Kite's window only); \
        menu (every item, shortcut, action, enabled; flags unsafe shortcuts); key_log (where recent keys went); \
        trace (animations with durations and curves, sampled frames and frame timing for seconds, after optional keys).
        """

    public static var inputSchema: JSONValue {
        let point: JSONValue = ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2]
        return [
            "type": "object",
            "properties": [
                "action": ["type": "string", "enum": .array(actions.map { .string($0) })],
                "window": ["type": "integer", "description": "Window number from windows. Default: the browser window in front."],
                "root": ["type": "string", "description": "tree: start at this node path, e.g. \"0.3\"."],
                "depth": ["type": "integer", "minimum": 1, "maximum": 60],
                "match": ["type": "string", "description": "tree/menu/trace: only nodes whose class, id or label contain this."],
                "layers": ["type": "boolean", "description": "tree: include Core Animation sublayers."],
                "max_nodes": ["type": "integer", "minimum": 1, "maximum": 5000],
                "region": ["type": "array", "items": ["type": "number"], "minItems": 4, "maxItems": 4,
                           "description": "capture: [x, y, width, height] in points."],
                "pixels": ["type": "array", "items": point, "description": "capture: points to read colours at."],
                "image": ["type": "boolean", "description": "capture: return the image (default: true unless pixels)."],
                "format": ["type": "string", "enum": ["png", "jpeg"]],
                "save": ["type": "string", "description": "capture: also write the image to this path."],
                "points": ["type": "array", "items": point, "description": "pointer: points to move through."],
                "from": point, "to": point,
                "steps": ["type": "integer", "minimum": 1, "maximum": .number(Double(maxPointerSteps))],
                "keys": ["type": "string", "description": "input/trace: keys like \"cmd+s\" or \"cmd+t Escape\"."],
                "text": ["type": "string", "description": "input: text to type."],
                "click": point,
                "button": ["type": "string", "enum": ["left", "right", "middle"]],
                "count": ["type": "integer", "minimum": 1, "maximum": 3],
                "modifiers": ["type": "string", "description": "input click: e.g. \"cmd\" or \"shift+alt\"."],
                "scroll": point,
                "dx": ["type": "number"], "dy": ["type": "number"],
                "seconds": ["type": "number", "description": "trace: how long to record (default 1.5, max 10)."],
                "limit": ["type": "integer", "minimum": 1, "maximum": 500],
                "clear": ["type": "boolean"],
            ] as JSONValue,
            "required": ["action"],
        ]
    }
}

/// Typed access to the `ui` tool's arguments.
private struct UIArguments {
    typealias Invalid = AutomationCommand.InvalidArguments
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw Invalid("\"\(key)\" must be a string.") }
        return string
    }

    func nonEmpty(_ key: String) throws -> String? {
        try string(key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    func bool(_ key: String) throws -> Bool {
        guard let value = values[key], !value.isNull else { return false }
        guard let bool = value.boolValue else { throw Invalid("\"\(key)\" must be true or false.") }
        return bool
    }

    func double(_ key: String) throws -> Double? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let number = value.doubleValue, number.isFinite else { throw Invalid("\"\(key)\" must be a number.") }
        return number
    }

    func int(_ key: String, in range: ClosedRange<Int>) throws -> Int? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let int = value.intValue, range.contains(int) else {
            throw Invalid("\"\(key)\" must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return int
    }

    static func point(_ value: JSONValue) -> UIPoint? {
        guard let pair = value.arrayValue, pair.count == 2, let x = pair[0].doubleValue, let y = pair[1].doubleValue,
              x.isFinite, y.isFinite, abs(x) < 100_000, abs(y) < 100_000 else { return nil }
        return UIPoint(x: x, y: y)
    }

    func point(_ key: String) throws -> UIPoint? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let point = Self.point(value) else { throw Invalid("\"\(key)\" must be [x, y] in window points.") }
        return point
    }

    func points(_ key: String) throws -> [UIPoint]? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let list = value.arrayValue else { throw Invalid("\"\(key)\" must be a list of [x, y] points.") }
        return try list.map {
            guard let point = Self.point($0) else { throw Invalid("\"\(key)\" must be a list of [x, y] points.") }
            return point
        }
    }

    func rect(_ key: String) throws -> UIRect? {
        guard let value = values[key], !value.isNull else { return nil }
        let numbers = value.arrayValue?.compactMap(\.doubleValue) ?? []
        guard numbers.count == 4, value.arrayValue?.count == 4, numbers[2] > 0, numbers[3] > 0,
              numbers.allSatisfy(\.isFinite) else {
            throw Invalid("\"\(key)\" must be [x, y, width, height] in points.")
        }
        return UIRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
    }

    func keys() throws -> [KeyChord]? {
        guard let text = try nonEmpty("keys") else { return nil }
        do {
            return try KeyChord.parseSequence(text)
        } catch let error as KeyChord.ParseError {
            throw Invalid(error.description)
        }
    }

    func modifiers() throws -> KeyChord.Modifiers {
        guard let text = try nonEmpty("modifiers") else { return [] }
        guard let chord = try? KeyChord.parse(text + "+a") else {
            throw Invalid("\"modifiers\" must look like \"cmd\", \"shift\" or \"cmd+shift\".")
        }
        return chord.modifiers
    }

    func inputEvent() throws -> UIInputEvent {
        var events: [UIInputEvent] = []
        if let keys = try keys() { events.append(.keys(keys)) }
        if let text = try string("text"), !text.isEmpty { events.append(.text(text)) }
        if let point = try point("click") {
            let button = ComputerAction.Button(rawValue: try string("button") ?? "left")
            guard let button else { throw Invalid("\"button\" is left, right or middle.") }
            events.append(.click(point, button: button, count: try int("count", in: 1...3) ?? 1, modifiers: try modifiers()))
        }
        if let from = try point("from"), let to = try point("to") {
            events.append(.drag(from: from, to: to, steps: try int("steps", in: 1...UIInspection.maxPointerSteps) ?? 10))
        }
        if let point = try point("scroll") {
            let dx = try double("dx") ?? 0, dy = try double("dy") ?? 0
            guard dx != 0 || dy != 0 else { throw Invalid("Scrolling needs \"dx\" or \"dy\".") }
            events.append(.scroll(point, dx: dx, dy: dy))
        }
        guard events.count == 1 else {
            throw Invalid(events.isEmpty
                ? "input needs one of \"keys\", \"text\", \"click\" [x, y], \"from\"+\"to\" (a drag) or \"scroll\" [x, y]."
                : "input takes one event at a time; use batch for several.")
        }
        return events[0]
    }
}

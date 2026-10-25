import Foundation

/// The element an action targets: a ref from `read_page`/`find`, or a CSS selector.
public enum AutomationTarget: Hashable, Sendable {
    case ref(String)
    case selector(String)
}

/// A point in a tab's viewport, in the same CSS-pixel coordinates as `screenshot`.
public struct ViewportPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// Mouse and keyboard actions in Claude in Chrome's `computer` style.
public enum ComputerAction: Hashable, Sendable {
    public enum Button: String, Sendable { case left, right, middle }
    public enum Direction: String, Sendable, CaseIterable { case up, down, left, right }

    /// Where a pointer action lands: a point, or the center of an element.
    public enum Location: Hashable, Sendable {
        case point(ViewportPoint)
        case target(AutomationTarget)
    }

    case screenshot(ImageFormat)
    case click(Location, button: Button, count: Int, modifiers: KeyChord.Modifiers)
    case hover(Location)
    case scroll(Location?, direction: Direction, amount: Int)
    case drag(from: ViewportPoint, to: ViewportPoint)
    case key([KeyChord], repeat: Int)
    case type(String)
    case wait(seconds: Double)
    /// A full-resolution crop: x0, y0, x1, y1.
    case zoom(x0: Double, y0: Double, x1: Double, y1: Double)

    public static let actionNames = [
        "screenshot", "left_click", "right_click", "middle_click", "double_click", "triple_click", "hover",
        "scroll", "left_click_drag", "key", "type", "wait", "zoom",
    ]
}

/// How screenshots are encoded. JPEG is several times smaller, so it's the default;
/// PNG is lossless for reading small text.
public enum ImageFormat: String, Hashable, Sendable {
    case jpeg, png
    public var mimeType: String { "image/\(rawValue)" }
}

/// What `wait_for` waits for.
public enum WaitCondition: Hashable, Sendable {
    /// The page finishes loading (returns at once if it isn't loading).
    case load
    /// The URL changes, then the page loads.
    case navigation
    case selector(String)
    case text(String)
    /// No network requests for half a second.
    case networkIdle
}

/// Where a new tab goes.
public enum TabPlacement: Hashable, Sendable {
    case currentSpace
    /// The profile's "Claude" space, made on first use, so Claude's tabs stay out of the user's way.
    case claudeSpace
    /// A space by id or name.
    case space(String)
}

/// One request to drive the browser. The same tool names and arguments are used
/// by the MCP server, the `kite` CLI and the app's automation socket, so the
/// relay in between never has to understand them.
public enum AutomationCommand: Hashable, Sendable {
    // Tabs and windows
    case tabsContext
    case tabsCreate(url: String?, active: Bool, placement: TabPlacement)
    case tabsClose(tab: String)
    case switchTab(tab: String)
    /// `newTab` opens the URL in a new background tab. "back" and "forward" move through history.
    case navigate(tab: String?, url: String, newTab: Bool)
    case resizeWindow(width: Int, height: Int)

    // Reading
    /// `changesOnly` returns only what changed since the last read of this tab.
    case readPage(tab: String?, maxTextLength: Int, interactiveOnly: Bool, changesOnly: Bool)
    case find(tab: String?, query: String)
    case getPageText(tab: String?, maxTextLength: Int)
    case screenshot(tab: String?, format: ImageFormat)

    // Acting
    case click(tab: String?, target: AutomationTarget)
    /// `target` nil types into whatever has focus. `submit` presses Return afterwards.
    case type(tab: String?, target: AutomationTarget?, text: String, submit: Bool)
    case formInput(tab: String?, target: AutomationTarget, value: JSONValue)
    case computer(tab: String?, action: ComputerAction)
    case javascript(tab: String?, code: String)
    case waitFor(tab: String?, condition: WaitCondition, timeout: Double)
    case handleDialog(tab: String?, accept: Bool, promptText: String?)
    case uploadFile(tab: String?, target: AutomationTarget, paths: [String])

    // Debugging
    case readConsole(tab: String?, pattern: String?, onlyErrors: Bool, limit: Int, clear: Bool)
    case readNetwork(tab: String?, urlPattern: String?, limit: Int, clear: Bool)
    /// Kite's HAR-style log across tabs, from a cursor. `query.tab` nil means every tab.
    case networkLog(query: NetworkLog.Query)
    /// One request in full: headers, timing, and its bodies while the page still has them.
    case networkRequest(id: Int, body: Bool, maxBodyLength: Int)
    case exportHAR(query: NetworkLog.Query, bodies: Bool)
    case listDownloads

    // Kite
    case listSpaces
    case switchSpace(space: String)
    case createSpace(name: String, icon: String?)
    case pinTab(tab: String?, pinned: Bool)
    case createFolder(name: String, space: String?)
    case moveToFolder(tab: String?, folder: String)

    /// Kite's own native UI, for debugging Kite itself (Diagnostics for Claude).
    case ui(UIInspection)

    /// Several tool calls in one round trip, run in order. It stops at the first error, and before any
    /// step that needs the user's OK (that step is then called on its own).
    indirect case batch(steps: [AutomationCommand])

    public static let maxBatchSteps = 25
    public static let defaultMaxTextLength = 20_000
    public static let maxTextLengthLimit = 200_000
    public static let defaultLogLimit = 100
    public static let maxWait: Double = 30
    public static let defaultBodyLength = 4_000

    public enum Tool: String, CaseIterable, Sendable {
        case tabsContext = "tabs_context"
        case tabsCreate = "tabs_create"
        case tabsClose = "tabs_close"
        case switchTab = "switch_tab"
        case navigate
        case resizeWindow = "resize_window"
        case readPage = "read_page"
        case find
        case getPageText = "get_page_text"
        case screenshot
        case click
        case type
        case formInput = "form_input"
        case computer
        case javascript
        case waitFor = "wait_for"
        case handleDialog = "handle_dialog"
        case uploadFile = "upload_file"
        case readConsole = "read_console_messages"
        case readNetwork = "read_network_requests"
        case networkLog = "network_log"
        case networkRequest = "network_request"
        case exportHAR = "export_har"
        case listDownloads = "list_downloads"
        case listSpaces = "list_spaces"
        case switchSpace = "switch_space"
        case createSpace = "create_space"
        case pinTab = "pin_tab"
        case createFolder = "create_folder"
        case moveToFolder = "move_to_folder"
        case ui
        case batch

        /// Older or Claude-in-Chrome names that still work but aren't listed.
        static let aliases: [String: Tool] = [
            "list_tabs": .tabsContext, "tabs_context_mcp": .tabsContext, "tabs_create_mcp": .tabsCreate,
            "tabs_close_mcp": .tabsClose, "javascript_tool": .javascript,
        ]

        public init?(name: String) {
            guard let tool = Tool(rawValue: name) ?? Self.aliases[name] else { return nil }
            self = tool
        }
    }

    public struct InvalidArguments: Error, Equatable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public var tool: Tool {
        switch self {
        case .tabsContext: .tabsContext
        case .tabsCreate: .tabsCreate
        case .tabsClose: .tabsClose
        case .switchTab: .switchTab
        case .navigate: .navigate
        case .resizeWindow: .resizeWindow
        case .readPage: .readPage
        case .find: .find
        case .getPageText: .getPageText
        case .screenshot: .screenshot
        case .click: .click
        case .type: .type
        case .formInput: .formInput
        case .computer: .computer
        case .javascript: .javascript
        case .waitFor: .waitFor
        case .handleDialog: .handleDialog
        case .uploadFile: .uploadFile
        case .readConsole: .readConsole
        case .readNetwork: .readNetwork
        case .networkLog: .networkLog
        case .networkRequest: .networkRequest
        case .exportHAR: .exportHAR
        case .listDownloads: .listDownloads
        case .listSpaces: .listSpaces
        case .switchSpace: .switchSpace
        case .createSpace: .createSpace
        case .pinTab: .pinTab
        case .createFolder: .createFolder
        case .moveToFolder: .moveToFolder
        case .ui: .ui
        case .batch: .batch
        }
    }

    /// Parses a tool call. Unknown arguments are ignored; missing or mistyped ones throw.
    public init(tool name: String, arguments: JSONValue?) throws {
        guard let tool = Tool(name: name) else { throw InvalidArguments("Unknown tool \"\(name)\".") }
        if let arguments, !arguments.isNull, arguments.objectValue == nil {
            throw InvalidArguments("Arguments must be an object.")
        }
        let a = Arguments(arguments?.objectValue ?? [:])
        let tab = try a.string("tab")

        switch tool {
        case .tabsContext:
            self = .tabsContext
        case .tabsCreate:
            let placement: TabPlacement
            switch try a.string("space") {
            case nil, "": placement = try a.bool("in_claude_space") ? .claudeSpace : .currentSpace
            case let space? where space.lowercased() == "claude": placement = .claudeSpace
            case let space?: placement = .space(space)
            }
            self = .tabsCreate(url: try a.string("url").flatMap { $0.isEmpty ? nil : $0 }, active: try a.bool("active"),
                               placement: placement)
        case .tabsClose:
            self = .tabsClose(tab: try a.required("tab"))
        case .switchTab:
            self = .switchTab(tab: try a.required("tab"))
        case .navigate:
            let url = try a.required("url")
            let newTab = try a.bool("new_tab")
            if newTab && tab != nil { throw InvalidArguments("Pass \"tab\" or \"new_tab\", not both.") }
            self = .navigate(tab: tab, url: url, newTab: newTab)
        case .resizeWindow:
            guard let width = try a.int("width", in: 400...10_000), let height = try a.int("height", in: 300...10_000) else {
                throw InvalidArguments("\"width\" and \"height\" are required.")
            }
            self = .resizeWindow(width: width, height: height)
        case .readPage:
            let filter = try a.string("filter") ?? "all"
            guard ["all", "interactive"].contains(filter) else { throw InvalidArguments("\"filter\" is \"all\" or \"interactive\".") }
            self = .readPage(tab: tab, maxTextLength: try a.textLimit(), interactiveOnly: filter == "interactive",
                             changesOnly: try a.bool("changes_only"))
        case .find:
            self = .find(tab: tab, query: try a.required("query"))
        case .getPageText:
            self = .getPageText(tab: tab, maxTextLength: try a.textLimit())
        case .screenshot:
            self = .screenshot(tab: tab, format: try a.imageFormat())
        case .click:
            self = .click(tab: tab, target: try a.target(required: true)!)
        case .type:
            guard let text = try a.string("text") else { throw InvalidArguments("\"text\" is required.") }
            self = .type(tab: tab, target: try a.target(required: false), text: text, submit: try a.bool("submit"))
        case .formInput:
            guard let value = a.values["value"], !value.isNull else { throw InvalidArguments("\"value\" is required.") }
            guard value.stringValue != nil || value.boolValue != nil || value.doubleValue != nil else {
                throw InvalidArguments("\"value\" must be a string, number or boolean.")
            }
            self = .formInput(tab: tab, target: try a.target(required: true)!, value: value)
        case .computer:
            self = .computer(tab: tab, action: try a.computerAction())
        case .javascript:
            let code = try a.string("code") ?? a.string("text")
            guard let code, !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw InvalidArguments("\"code\" is required.")
            }
            self = .javascript(tab: tab, code: code)
        case .waitFor:
            let condition: WaitCondition
            let value = try a.string("value")
            switch try a.required("condition") {
            case "load": condition = .load
            case "navigation": condition = .navigation
            case "network_idle": condition = .networkIdle
            case "selector":
                guard let value, !value.isEmpty else { throw InvalidArguments("\"selector\" waits need a \"value\".") }
                condition = .selector(value)
            case "text":
                guard let value, !value.isEmpty else { throw InvalidArguments("\"text\" waits need a \"value\".") }
                condition = .text(value)
            case let other:
                throw InvalidArguments("\"\(other)\" isn't a condition (load, navigation, selector, text, network_idle).")
            }
            let timeout = try a.double("timeout_ms").map { $0 / 1000 } ?? 10
            guard timeout > 0, timeout <= Self.maxWait else { throw InvalidArguments("\"timeout_ms\" must be from 1 to 30000.") }
            self = .waitFor(tab: tab, condition: condition, timeout: timeout)
        case .handleDialog:
            guard let accept = a.values["accept"]?.boolValue else { throw InvalidArguments("\"accept\" (true or false) is required.") }
            self = .handleDialog(tab: tab, accept: accept, promptText: try a.string("prompt_text"))
        case .uploadFile:
            let list = a.values["paths"]?.arrayValue ?? []
            let paths = list.compactMap(\.stringValue).filter { !$0.isEmpty }
            guard !paths.isEmpty, paths.count == list.count else { throw InvalidArguments("\"paths\" must be a list of file paths.") }
            self = .uploadFile(tab: tab, target: try a.target(required: true)!, paths: paths)
        case .readConsole:
            self = .readConsole(tab: tab, pattern: try a.pattern("pattern"), onlyErrors: try a.bool("only_errors"),
                                limit: try a.int("limit", in: 1...1000) ?? Self.defaultLogLimit, clear: try a.bool("clear"))
        case .readNetwork:
            self = .readNetwork(tab: tab, urlPattern: try a.pattern("url_pattern"),
                                limit: try a.int("limit", in: 1...1000) ?? Self.defaultLogLimit, clear: try a.bool("clear"))
        case .networkLog:
            self = .networkLog(query: try a.networkQuery(tab: tab, limit: 1...1000))
        case .networkRequest:
            guard let id = try a.int("id", in: 1...Int.max) else { throw InvalidArguments("\"id\" (the number after # in network_log) is required.") }
            self = .networkRequest(id: id, body: try (a.values["body"] == nil || a.bool("body")),
                                   maxBodyLength: try a.int("max_body_length", in: 0...Self.maxTextLengthLimit) ?? Self.defaultBodyLength)
        case .exportHAR:
            var query = try a.networkQuery(tab: tab, limit: 1...NetworkLog.capacity)
            if a.values["limit"] == nil { query.limit = NetworkLog.capacity }
            if a.values["type"] == nil { query.types = ["all"] }
            self = .exportHAR(query: query, bodies: try a.bool("bodies"))
        case .listDownloads:
            self = .listDownloads
        case .listSpaces:
            self = .listSpaces
        case .switchSpace:
            self = .switchSpace(space: try a.required("space"))
        case .createSpace:
            self = .createSpace(name: try a.required("name"), icon: try a.string("icon"))
        case .pinTab:
            guard let value = a.values["pinned"], !value.isNull else {
                self = .pinTab(tab: tab, pinned: true)
                return
            }
            guard let pinned = value.boolValue else { throw InvalidArguments("\"pinned\" must be true or false.") }
            self = .pinTab(tab: tab, pinned: pinned)
        case .createFolder:
            self = .createFolder(name: try a.required("name"), space: try a.string("space"))
        case .moveToFolder:
            self = .moveToFolder(tab: tab, folder: try a.required("folder"))
        case .ui:
            self = .ui(try UIInspection(arguments: a.values))
        case .batch:
            guard let list = a.values["steps"]?.arrayValue, !list.isEmpty else {
                throw InvalidArguments("\"steps\" must be a list of {\"tool\": …, \"arguments\": {…}}.")
            }
            guard list.count <= Self.maxBatchSteps else { throw InvalidArguments("A batch has at most \(Self.maxBatchSteps) steps.") }
            self = .batch(steps: try list.enumerated().map { index, step in
                guard let name = step["tool"]?.stringValue else { throw InvalidArguments("Step \(index + 1) has no \"tool\".") }
                guard Tool(name: name) != .batch else { throw InvalidArguments("Batches can't contain batches.") }
                var arguments = step["arguments"]?.objectValue ?? [:]
                if step["arguments"].map({ !$0.isNull && $0.objectValue == nil }) == true {
                    throw InvalidArguments("Step \(index + 1)'s \"arguments\" must be an object.")
                }
                // A batch-wide tab applies to steps that don't name one.
                if let tab, arguments["tab"] == nil, Tool(name: name)?.takesTab == true { arguments["tab"] = .string(tab) }
                do {
                    return try AutomationCommand(tool: name, arguments: .object(arguments))
                } catch let error as InvalidArguments {
                    throw InvalidArguments("Step \(index + 1) (\(name)): \(error.description)")
                }
            })
        }
    }
}

/// Typed access to a tool's argument object.
private struct Arguments {
    typealias Invalid = AutomationCommand.InvalidArguments
    let values: [String: JSONValue]

    init(_ values: [String: JSONValue]) { self.values = values }

    func string(_ key: String) throws -> String? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let string = value.stringValue else { throw Invalid("\"\(key)\" must be a string.") }
        return string
    }

    func required(_ key: String) throws -> String {
        guard let string = try string(key), !string.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw Invalid("\"\(key)\" is required.")
        }
        return string
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

    /// The filters `network_log` and `export_har` share.
    func networkQuery(tab: String?, limit range: ClosedRange<Int>) throws -> NetworkLog.Query {
        var query = NetworkLog.Query(tab: tab, since: try int("since", in: 0...Int.max), urlPattern: try pattern("url_pattern"),
                                     host: try string("host").flatMap { $0.isEmpty ? nil : $0 },
                                     limit: try int("limit", in: range) ?? NetworkLog.defaultLimit)
        if let status = try string("status")?.lowercased(), !status.isEmpty {
            guard NetworkLog.statusFilters.contains(status) else {
                throw Invalid("\"status\" is one of \(NetworkLog.statusFilters.joined(separator: ", ")).")
            }
            query.status = status
        }
        // "fetch,xhr" or ["fetch", "xhr"].
        let types: [String]
        switch values["type"] {
        case .string(let list)?: types = list.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        case .array(let list)?: types = try list.map {
            guard let type = $0.stringValue else { throw Invalid("\"type\" must be a string or a list of strings.") }
            return type.lowercased()
        }
        case nil, .null?: types = []
        default: throw Invalid("\"type\" must be a string or a list of strings.")
        }
        if !types.filter({ !$0.isEmpty }).isEmpty { query.types = Set(types.filter { !$0.isEmpty }) }
        return query
    }

    func imageFormat() throws -> ImageFormat {
        guard let name = try string("format") else { return .jpeg }
        guard let format = ImageFormat(rawValue: name.lowercased()) else { throw Invalid("\"format\" is jpeg or png.") }
        return format
    }

    func textLimit() throws -> Int {
        guard let value = values["max_text_length"], !value.isNull else { return AutomationCommand.defaultMaxTextLength }
        guard let int = value.intValue, int >= 0 else {
            throw Invalid("\"max_text_length\" must be a whole number of characters.")
        }
        return min(int, AutomationCommand.maxTextLengthLimit)
    }

    /// A regular expression, checked here so a bad one fails before reaching the app.
    func pattern(_ key: String) throws -> String? {
        guard let pattern = try string(key), !pattern.isEmpty else { return nil }
        guard (try? NSRegularExpression(pattern: pattern)) != nil else {
            throw Invalid("\"\(key)\" isn't a valid regular expression.")
        }
        return pattern
    }

    func target(required: Bool) throws -> AutomationTarget? {
        let ref = try string("ref").flatMap { $0.isEmpty ? nil : $0 }
        let selector = try string("selector").flatMap { $0.isEmpty ? nil : $0 }
        switch (ref, selector) {
        case (let ref?, nil): return .ref(ref)
        case (nil, let selector?): return .selector(selector)
        case (.some, .some): throw Invalid("Pass either \"ref\" or \"selector\", not both.")
        case (nil, nil):
            if required { throw Invalid("Pass \"ref\" (from read_page or find) or \"selector\".") }
            return nil
        }
    }

    func point(_ key: String) throws -> ViewportPoint? {
        guard let value = values[key], !value.isNull else { return nil }
        guard let pair = value.arrayValue, pair.count == 2, let x = pair[0].doubleValue, let y = pair[1].doubleValue,
              x.isFinite, y.isFinite, x >= 0, y >= 0 else {
            throw Invalid("\"\(key)\" must be [x, y] in screenshot pixels.")
        }
        return ViewportPoint(x: x, y: y)
    }

    func location(required: Bool) throws -> ComputerAction.Location? {
        let point = try self.point("coordinate")
        let target = try self.target(required: false)
        switch (point, target) {
        case (let point?, nil): return .point(point)
        case (nil, let target?): return .target(target)
        case (.some, .some): throw Invalid("Pass \"coordinate\" or a ref/selector, not both.")
        case (nil, nil):
            if required { throw Invalid("Pass \"coordinate\" [x, y] or a \"ref\".") }
            return nil
        }
    }

    func modifiers() throws -> KeyChord.Modifiers {
        guard let text = try string("modifiers"), !text.isEmpty else { return [] }
        // Reuse the chord parser on "<modifiers>+a".
        guard let chord = try? KeyChord.parse(text + "+a") else {
            throw Invalid("\"modifiers\" must look like \"cmd\", \"shift\" or \"cmd+shift\".")
        }
        return chord.modifiers
    }

    func computerAction() throws -> ComputerAction {
        let action = try required("action")
        switch action {
        case "screenshot":
            return .screenshot(try imageFormat())
        case "left_click", "right_click", "middle_click", "double_click", "triple_click":
            let button: ComputerAction.Button = action == "right_click" ? .right : action == "middle_click" ? .middle : .left
            let count = action == "double_click" ? 2 : action == "triple_click" ? 3 : 1
            return .click(try location(required: true)!, button: button, count: count, modifiers: try modifiers())
        case "hover":
            return .hover(try location(required: true)!)
        case "scroll":
            let direction = try string("scroll_direction") ?? "down"
            guard let parsed = ComputerAction.Direction(rawValue: direction) else {
                throw Invalid("\"scroll_direction\" is up, down, left or right.")
            }
            return .scroll(try location(required: false), direction: parsed, amount: try int("scroll_amount", in: 1...50) ?? 3)
        case "left_click_drag":
            guard let from = try point("start_coordinate"), let to = try point("coordinate") else {
                throw Invalid("Drags need \"start_coordinate\" and \"coordinate\".")
            }
            return .drag(from: from, to: to)
        case "key":
            let text = try required("text")
            do {
                return .key(try KeyChord.parseSequence(text), repeat: try int("repeat", in: 1...100) ?? 1)
            } catch let error as KeyChord.ParseError {
                throw Invalid(error.description)
            }
        case "type":
            guard let text = try string("text"), !text.isEmpty else { throw Invalid("\"text\" is required.") }
            return .type(text)
        case "wait":
            let seconds = try double("duration") ?? 1
            guard seconds >= 0, seconds <= AutomationCommand.maxWait else { throw Invalid("\"duration\" is 0 to 30 seconds.") }
            return .wait(seconds: seconds)
        case "zoom":
            let region = values["region"]?.arrayValue ?? []
            let numbers = region.compactMap(\.doubleValue)
            guard region.count == 4, numbers.count == 4, numbers[2] > numbers[0], numbers[3] > numbers[1],
                  numbers[0] >= 0, numbers[1] >= 0 else {
                throw Invalid("\"region\" must be [x0, y0, x1, y1] with x1 > x0 and y1 > y0.")
            }
            return .zoom(x0: numbers[0], y0: numbers[1], x1: numbers[2], y1: numbers[3])
        default:
            throw Invalid("\"\(action)\" isn't a computer action (\(ComputerAction.actionNames.joined(separator: ", "))).")
        }
    }
}

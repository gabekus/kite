import AppKit
import KiteCore

/// `ui input`: synthetic keys, clicks, drags and scrolls delivered to one Kite window only.
///
/// While Kite is the active app with this window key, keys go through `NSApp.sendEvent`, the
/// exact path a real key takes. In the background they take the same steps by hand (view key
/// equivalents, the menu bar, then the first responder), so Kite never has to come forward.
/// Mouse events go to the window directly. Nothing reaches the window server, so the real
/// pointer and other apps are untouched.
@MainActor
struct UIInputSender {
    let window: NSWindow
    let keyLog: KeyRoutingLog

    func send(_ event: UIInputEvent) async throws -> String {
        switch event {
        case .keys(let chords):
            var pressed: [(chord: KeyChord, entry: Int, route: String)] = []
            for chord in chords {
                let (entry, route) = try press(chord)
                pressed.append((chord, entry, route))
            }
            // A web view can claim a key and hand it back to the menu bar a moment later.
            try? await Task.sleep(for: .milliseconds(50))
            return pressed.map { chord, entry, route in
                let menu = keyLog.routes(of: entry)
                return "\(AutomationController.keyName(chord)): \(route)" + (menu.isEmpty ? "" : "; " + menu.joined(separator: "; "))
            }.joined(separator: "\n")
        case .text(let text):
            for character in text {
                let chord = (try? KeyChord.parse(String(character))) ?? KeyChord(
                    key: String(character), code: "", keyCode: 0, text: String(character), modifiers: [], commands: [])
                _ = try press(chord)
            }
            return "Typed \(text.count) characters into window \(window.windowNumber) (\(responderName))."
        case let .click(point, button, count, modifiers):
            guard button != .middle else { throw AutomationError(.unsupported, "ui input can't send middle clicks.") }
            let flags = Self.flags(modifiers)
            let (down, up): (NSEvent.EventType, NSEvent.EventType) = button == .right ? (.rightMouseDown, .rightMouseUp) : (.leftMouseDown, .leftMouseUp)
            let hit = hitName(point), note = firstMouseNote(at: point)
            var rest: [Gesture] = [(up, point, 1)]
            for click in Swift.stride(from: 2, through: count, by: 1) { rest += [(down, point, click), (up, point, click)] }
            send(down, then: rest, at: point, flags: flags)
            try? await Task.sleep(for: .milliseconds(50))
            return "\(count == 1 ? "Clicked" : "\(count)× clicked") \(button.rawValue) at (\(UIReport.number(point.x)), \(UIReport.number(point.y))) on \(hit)." + note
        case let .drag(from, to, steps):
            let hit = hitName(from), note = firstMouseNote(at: from)
            let moves = (1...steps).map { step -> Gesture in
                let t = Double(step) / Double(steps)
                return (.leftMouseDragged, UIPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t), 1)
            }
            send(.leftMouseDown, then: moves + [(.leftMouseUp, to, 1)], at: from, flags: [])
            try? await Task.sleep(for: .milliseconds(50))
            return "Dragged from (\(UIReport.number(from.x)), \(UIReport.number(from.y))) to (\(UIReport.number(to.x)), \(UIReport.number(to.y))) in \(steps) steps, starting on \(hit)." + note
        case let .scroll(point, dx, dy):
            guard let cgEvent = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                        wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else {
                throw AutomationError(.failed, "Couldn't make a scroll event.")
            }
            let screen = window.convertPoint(toScreen: window.basePoint(point))
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            cgEvent.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
            cgEvent.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
            guard let event = NSEvent(cgEvent: cgEvent) else { throw AutomationError(.failed, "Couldn't make a scroll event.") }
            window.sendEvent(event)
            return "Scrolled dx \(UIReport.number(dx)), dy \(UIReport.number(dy)) at (\(UIReport.number(point.x)), \(UIReport.number(point.y))) on \(hitName(point))."
        }
    }

    // MARK: Keys

    private var responderName: String {
        window.firstResponder.map { UIFormat.className($0) } ?? "no first responder"
    }

    /// Presses a key; returns its key log entry and where it went.
    private func press(_ chord: KeyChord) throws -> (entry: Int, route: String) {
        guard let keyCode = Self.macKeyCodes[chord.code] ?? (chord.code.isEmpty ? 0 : nil) else {
            throw AutomationError(.unsupported, "ui input doesn't know the Mac key for \(chord.code).")
        }
        var flags = Self.flags(chord.modifiers)
        // AppKit marks arrows, navigation and F keys with fn (and arrows with the keypad flag).
        if Self.functionCharacters[chord.code] != nil, !["Enter", "Tab", "Escape", "Backspace"].contains(chord.code) {
            flags.insert(.function)
            if chord.code.hasPrefix("Arrow") { flags.insert(.numericPad) }
        }
        // With ⌘ or ⌃ held a real key event carries the unshifted character ("w" for ⌘⇧W), and AppKit
        // matches menu key equivalents on that plus the flags.
        let isCommand = !chord.modifiers.isDisjoint(with: [.meta, .control])
        let characters = Self.functionCharacters[chord.code] ?? (isCommand ? chord.key.lowercased() : chord.text ?? chord.key)
        let ignoringModifiers = Self.functionCharacters[chord.code]
            ?? (isCommand || !chord.modifiers.contains(.shift) ? chord.key.lowercased() : chord.key.uppercased())
        let timestamp = ProcessInfo.processInfo.systemUptime
        guard let down = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: timestamp,
                                          windowNumber: window.windowNumber, context: nil, characters: characters,
                                          charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode),
              let up = NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: flags, timestamp: timestamp + 0.01,
                                        windowNumber: window.windowNumber, context: nil, characters: characters,
                                        charactersIgnoringModifiers: ignoringModifiers, isARepeat: false, keyCode: keyCode) else {
            throw AutomationError(.failed, "Couldn't make a key event for \(chord.key).")
        }
        let entry = keyLog.record(down, synthetic: true)
        let route = keyLog.whileDelivering(entry) { deliver(down) }
        deliverUp(up)
        return (entry, route)
    }

    /// Delivers a key down the way AppKit would for this window, and says where it went.
    private func deliver(_ event: NSEvent) -> String {
        // Named before delivery, which can move focus (Escape closing the command bar).
        let responder = responderName
        if window.isKeyWindow && NSApp.isActive {
            NSApp.sendEvent(event)
            return "sent through the app (Kite in front) to \(responder)"
        }
        // AppKit offers keys with ⌘ or ⌃ (and function keys) as key equivalents before typing them.
        let isEquivalentCandidate = !event.modifierFlags.isDisjoint(with: [.command, .control]) || event.modifierFlags.contains(.function)
        if isEquivalentCandidate {
            // Menu commands that target the front browser window go to this one instead. Ones sent up the
            // responder chain (Close Window) still go to Kite's key or main window.
            MenuRouter.deliveringTo = window.windowController as? BrowserWindowController
            defer { MenuRouter.deliveringTo = nil }
            if window.performKeyEquivalent(with: event) { return "claimed as a key equivalent by a view (Kite in background)" }
            if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { return "handled by the menu bar (Kite in background)" }
        }
        window.sendEvent(event)
        return "sent to \(responder) (Kite in background)"
    }

    private func deliverUp(_ event: NSEvent) {
        if window.isKeyWindow && NSApp.isActive { NSApp.sendEvent(event) } else { window.sendEvent(event) }
    }

    static func flags(_ modifiers: KeyChord.Modifiers) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if modifiers.contains(.meta) { flags.insert(.command) }
        if modifiers.contains(.control) { flags.insert(.control) }
        if modifiers.contains(.alt) { flags.insert(.option) }
        if modifiers.contains(.shift) { flags.insert(.shift) }
        return flags
    }

    // MARK: Mouse

    /// Sends a mouse down with the rest of its gesture already queued. Views like NSTextView run their own
    /// tracking loop inside mouseDown, waiting for the mouse up; sent one by one, that loop would never end.
    /// Whatever no loop takes is dispatched from the queue to the window as usual.
    private typealias Gesture = (type: NSEvent.EventType, point: UIPoint, clickCount: Int)

    private func send(_ down: NSEvent.EventType, then rest: [Gesture], at point: UIPoint, flags: NSEvent.ModifierFlags) {
        for event in rest {
            if let event = mouseEvent(event.type, at: event.point, flags: flags, clickCount: event.clickCount) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        if let event = mouseEvent(down, at: point, flags: flags, clickCount: 1) { window.sendEvent(event) }
    }

    private func mouseEvent(_ type: NSEvent.EventType, at point: UIPoint, flags: NSEvent.ModifierFlags, clickCount: Int) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: window.basePoint(point), modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clickCount,
            pressure: type == .leftMouseUp || type == .rightMouseUp ? 0 : 1)
    }

    /// With the window not key, AppKit gives a click only to views that accept first mouse; a real first
    /// click would activate Kite instead, and synthetic ones never do, so they keep being dropped.
    private func firstMouseNote(at point: UIPoint) -> String {
        guard !window.isKeyWindow, let frameView = window.contentView?.superview ?? window.contentView,
              let view = frameView.hitTest(frameView.convert(window.basePoint(point), from: nil)),
              let event = NSEvent.mouseEvent(
                with: .leftMouseDown, location: window.basePoint(point), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1),
              !view.acceptsFirstMouse(for: event) else { return "" }
        return " \(UIFormat.className(view)) doesn't accept first mouse and the window isn't key, so AppKit didn't deliver it "
            + "(a real click would activate Kite first). Test this with Kite in front."
    }

    private func hitName(_ point: UIPoint) -> String {
        guard let frameView = window.contentView?.superview ?? window.contentView,
              let view = frameView.hitTest(frameView.convert(window.basePoint(point), from: nil)) else { return "nothing" }
        let path = UITreeBuilder.paths(in: window)[ObjectIdentifier(view)] ?? "titlebar"
        return "\(path) \(UIFormat.className(view))"
    }

    // MARK: Key tables

    /// DOM `code` → Mac virtual key code (kVK_*), US layout.
    static let macKeyCodes: [String: UInt16] = {
        var table: [String: UInt16] = [
            "KeyA": 0, "KeyS": 1, "KeyD": 2, "KeyF": 3, "KeyH": 4, "KeyG": 5, "KeyZ": 6, "KeyX": 7, "KeyC": 8, "KeyV": 9,
            "KeyB": 11, "KeyQ": 12, "KeyW": 13, "KeyE": 14, "KeyR": 15, "KeyY": 16, "KeyT": 17, "Digit1": 18, "Digit2": 19,
            "Digit3": 20, "Digit4": 21, "Digit6": 22, "Digit5": 23, "Equal": 24, "Digit9": 25, "Digit7": 26, "Minus": 27,
            "Digit8": 28, "Digit0": 29, "BracketRight": 30, "KeyO": 31, "KeyU": 32, "BracketLeft": 33, "KeyI": 34, "KeyP": 35,
            "Enter": 36, "KeyL": 37, "KeyJ": 38, "Quote": 39, "KeyK": 40, "Semicolon": 41, "Backslash": 42, "Comma": 43,
            "Slash": 44, "KeyN": 45, "KeyM": 46, "Period": 47, "Tab": 48, "Space": 49, "Backquote": 50, "Backspace": 51,
            "Escape": 53, "Delete": 117, "Home": 115, "End": 119, "PageUp": 116, "PageDown": 121,
            "ArrowLeft": 123, "ArrowRight": 124, "ArrowDown": 125, "ArrowUp": 126,
        ]
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (index, code) in functionKeys.enumerated() { table["F\(index + 1)"] = code }
        return table
    }()

    /// The characters AppKit puts on non-printing keys.
    static let functionCharacters: [String: String] = {
        func scalar(_ value: Int) -> String { String(Character(UnicodeScalar(value)!)) }
        var table: [String: String] = [
            "Enter": "\r", "Tab": "\t", "Escape": "\u{1B}", "Backspace": "\u{7F}", "Delete": scalar(NSDeleteFunctionKey),
            "Home": scalar(NSHomeFunctionKey), "End": scalar(NSEndFunctionKey), "PageUp": scalar(NSPageUpFunctionKey),
            "PageDown": scalar(NSPageDownFunctionKey), "ArrowLeft": scalar(NSLeftArrowFunctionKey),
            "ArrowRight": scalar(NSRightArrowFunctionKey), "ArrowDown": scalar(NSDownArrowFunctionKey),
            "ArrowUp": scalar(NSUpArrowFunctionKey),
        ]
        for n in 1...12 { table["F\(n)"] = scalar(NSF1FunctionKey + n - 1) }
        return table
    }()
}

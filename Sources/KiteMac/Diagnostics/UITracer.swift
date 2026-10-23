import AppKit
import KiteCore

/// `ui trace`: records what moves in a window for a few seconds, one sample per displayed frame.
///
/// - Every Core Animation animation that starts: layer, key path, duration, delay, timing curve
///   (control points, or spring parameters), from and to.
/// - Every layer whose on-screen (presentation) frame or opacity changes, sampled each frame,
///   with progress from 0 to 1 so the curve can be compared with Arc's.
/// - With `match`, SwiftUI elements whose role, id or label match, sampled each frame too:
///   SwiftUI often animates without Core Animation animations.
/// - Frame timing: intervals between frames, and frames that came late.
@MainActor
final class UITracer: NSObject {
    private let window: NSWindow
    private let keyLog: KeyRoutingLog

    private struct Sample {
        let time: Double
        let frame: CGRect
        let opacity: Float
    }

    private var start: CFTimeInterval = 0
    private var frameTimes: [CFTimeInterval] = []
    private var series: [ObjectIdentifier: (name: String, samples: [Sample])] = [:]
    private var seenAnimations: Set<String> = []
    private var animations: [String] = []
    private var elementSeries: [String: [Sample]] = [:]
    private var match: String?
    private var paths: [ObjectIdentifier: String] = [:]
    private var link: CADisplayLink?
    private var pendingKeys: [KeyChord]?
    private var keyResult: String?

    init(window: NSWindow, keyLog: KeyRoutingLog) {
        self.window = window
        self.keyLog = keyLog
    }

    func run(seconds: Double, keys: [KeyChord]?, match: String?) async -> String {
        guard let content = window.contentView else { return "The window has no content view." }
        self.match = match
        paths = UITreeBuilder.paths(in: window)
        pendingKeys = keys
        let link = content.displayLink(target: self, selector: #selector(tick(_:)))
        let rate = Float(FrameClock.maximumRate(of: window.screen))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, rate), maximum: rate, preferred: rate)
        link.add(to: .main, forMode: .common)
        self.link = link
        try? await Task.sleep(for: .seconds(seconds))
        link.invalidate()
        self.link = nil
        return report(seconds: seconds, rate: Int(rate))
    }

    @objc private func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        if frameTimes.isEmpty { start = now }
        frameTimes.append(now)
        let t = now - start
        sampleLayers(at: t)
        if let match { sampleElements(matching: match, at: t) }
        // Press the keys after the first frame, so the trace has the state before them.
        if let keys = pendingKeys, frameTimes.count == 1 {
            pendingKeys = nil
            Task { @MainActor in
                keyResult = (try? await UIInputSender(window: window, keyLog: keyLog).send(.keys(keys))) ?? "Couldn't press the keys."
            }
        }
    }

    // MARK: Layers

    private func sampleLayers(at t: Double) {
        guard let root = (window.contentView?.superview ?? window.contentView)?.layer else { return }
        let rootPresentation = root.presentation() ?? root
        func visit(_ layer: CALayer, depth: Int) {
            guard depth < 40, !layer.isHidden else { return }
            if let view = layer.delegate as? NSView, UIFormat.isWebContent(view) { return }
            let keys = layer.animationKeys() ?? []
            for key in keys { noteAnimation(layer, key: key, at: t) }
            let presentation = layer.presentation() ?? layer
            let frame = presentation.convert(presentation.bounds, to: rootPresentation)
            let sample = Sample(time: t, frame: frame, opacity: presentation.opacity)
            let id = ObjectIdentifier(layer)
            if var entry = series[id] {
                if let last = entry.samples.last, last.frame != frame || last.opacity != sample.opacity || !keys.isEmpty {
                    entry.samples.append(sample)
                    series[id] = entry
                }
            } else if frameTimes.count == 1 || !keys.isEmpty {
                // The first frame is the baseline for every layer; later newcomers only if animating.
                series[id] = (name(of: layer), [sample])
            }
            layer.sublayers?.forEach { visit($0, depth: depth + 1) }
        }
        visit(root, depth: 0)
    }

    private func noteAnimation(_ layer: CALayer, key: String, at t: Double) {
        guard let animation = layer.animation(forKey: key) else { return }
        let id = "\(ObjectIdentifier(layer)) \(key) \(ObjectIdentifier(animation))"
        guard !seenAnimations.contains(id) else { return }
        seenAnimations.insert(id)
        animations.append("+\(String(format: "%.3f", t))s \(name(of: layer)) " + Self.describe(animation, key: key))
    }

    private func name(of layer: CALayer) -> String {
        if let view = layer.delegate as? NSView {
            return "\(paths[ObjectIdentifier(view)] ?? "titlebar") \(UIFormat.className(view))"
        }
        var owner = layer.superlayer
        while let current = owner, !(current.delegate is NSView) { owner = current.superlayer }
        let inside = (owner?.delegate as? NSView).map { " in \(paths[ObjectIdentifier($0)] ?? "titlebar") \(UIFormat.className($0))" } ?? ""
        return UIFormat.className(layer) + (layer.name.map { "#\($0)" } ?? "") + inside
    }

    static func describe(_ animation: CAAnimation, key: String) -> String {
        var parts: [String] = []
        if let property = animation as? CAPropertyAnimation { parts.append(property.keyPath ?? key) } else { parts.append(key) }
        parts.append("\(UIReport.number(animation.duration))s")
        if animation.beginTime > 0 { parts.append("begin \(UIReport.number(animation.beginTime))") }
        if let spring = animation as? CASpringAnimation {
            parts.append("spring mass \(UIReport.number(spring.mass)) stiffness \(UIReport.number(spring.stiffness)) "
                + "damping \(UIReport.number(spring.damping)) v0 \(UIReport.number(spring.initialVelocity)) "
                + "settles \(UIReport.number(spring.settlingDuration))s")
        } else if let timing = animation.timingFunction {
            var c1: [Float] = [0, 0], c2: [Float] = [0, 0]
            timing.getControlPoint(at: 1, values: &c1)
            timing.getControlPoint(at: 2, values: &c2)
            parts.append("curve(\([c1[0], c1[1], c2[0], c2[1]].map { UIReport.number(Double($0)) }.joined(separator: ",")))")
        } else {
            parts.append("linear")
        }
        if let basic = animation as? CABasicAnimation {
            if let from = basic.fromValue { parts.append("from \(Self.value(from))") }
            if let to = basic.toValue { parts.append("to \(Self.value(to))") }
            if let by = basic.byValue { parts.append("by \(Self.value(by))") }
        }
        if let keyframes = animation as? CAKeyframeAnimation, let values = keyframes.values {
            parts.append("\(values.count) keyframes \(Self.value(values.first as Any)) … \(Self.value(values.last as Any))")
        }
        if let group = animation as? CAAnimationGroup {
            parts.append("group [" + (group.animations ?? []).map { describe($0, key: "") }.joined(separator: "; ") + "]")
        }
        return parts.joined(separator: " ")
    }

    private static func value(_ value: Any) -> String {
        switch value {
        case let number as NSNumber: return UIReport.number(number.doubleValue)
        case let value as NSValue:
            switch String(cString: value.objCType) {
            case let type where type.contains("CGPoint"): let p = value.pointValue; return "(\(UIReport.number(p.x)),\(UIReport.number(p.y)))"
            case let type where type.contains("CGRect"):
                let r = value.rectValue
                return "[\(UIReport.number(r.minX)),\(UIReport.number(r.minY)) \(UIReport.number(r.width))×\(UIReport.number(r.height))]"
            case let type where type.contains("CGSize"): let s = value.sizeValue; return "\(UIReport.number(s.width))×\(UIReport.number(s.height))"
            default: return "\(value)"
            }
        default:
            let type = CFGetTypeID(value as CFTypeRef)
            if type == CGColor.typeID { return UIFormat.hex((value as! CGColor)) ?? "colour" }
            if type == CGPath.typeID { return "path" }
            return String(describing: value).prefix(60).description
        }
    }

    // MARK: SwiftUI elements

    private func sampleElements(matching query: String, at t: Double) {
        guard let content = window.contentView else { return }
        var found = 0
        func visit(_ object: NSObject, depth: Int) {
            guard depth < 40, found < 20 else { return }
            let role = object.accessibilityAttributeValue(.role) as? String ?? ""
            let label = (object.accessibilityAttributeValue(.description) as? String) ?? (object.accessibilityAttributeValue(.title) as? String) ?? ""
            let identifier = object.accessibilityAttributeValue(.identifier) as? String ?? ""
            if !(object is NSView), [role, label, identifier].contains(where: { $0.range(of: query, options: .caseInsensitive) != nil }),
               let position = (object.accessibilityAttributeValue(.position) as? NSValue)?.pointValue,
               let size = (object.accessibilityAttributeValue(.size) as? NSValue)?.sizeValue {
                found += 1
                let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                let rect = window.convertFromScreen(NSRect(x: position.x, y: primaryHeight - position.y - size.height,
                                                           width: size.width, height: size.height))
                let key = "\(role)\(identifier.isEmpty ? "" : " #" + identifier) \(AccessibilityOutline.quote(String(label.prefix(40))))"
                let samples = elementSeries[key] ?? []
                if samples.last?.frame != rect { elementSeries[key] = samples + [Sample(time: t, frame: rect, opacity: 1)] }
            }
            for child in object.accessibilityAttributeValue(.children) as? [NSObject] ?? [] { visit(child, depth: depth + 1) }
        }
        visit(content, depth: 0)
    }

    // MARK: Report

    private func report(seconds: Double, rate: Int) -> String {
        var lines: [String] = []
        let intervals = zip(frameTimes.dropFirst(), frameTimes).map { ($0 - $1) * 1000 }
        let expected = 1000 / Double(max(rate, 1))
        if intervals.isEmpty {
            lines.append("No frames were drawn in \(UIReport.number(seconds)) s (window hidden or covered?).")
        } else {
            let average = intervals.reduce(0, +) / Double(intervals.count)
            let late = intervals.filter { $0 > expected * 1.5 }.count
            lines.append("\(frameTimes.count) frames in \(UIReport.number(seconds)) s on a \(rate) Hz screen: interval avg "
                + "\(UIReport.number(average)) ms, max \(UIReport.number(intervals.max() ?? 0)) ms, \(late) late (over \(UIReport.number(expected * 1.5)) ms).")
        }
        if let keyResult { lines.append("Keys: \(keyResult)") }
        lines.append(animations.isEmpty ? "No Core Animation animations started." : "Animations started:")
        lines += animations.map { "  " + $0 }

        let height = Double(window.frame.height)
        let moving = series.values.filter { $0.samples.count > 1 }.sorted { $0.name < $1.name }
        if moving.isEmpty {
            lines.append("No layer moved, resized or faded.")
        } else {
            lines.append("Layers that changed (window points from the top-left; p is progress 0→1 of the biggest change):")
            for entry in moving.prefix(30) { lines += describe(entry.name, entry.samples, flipFrom: height) }
            if moving.count > 30 { lines.append("  … \(moving.count - 30) more layers changed") }
        }
        if let match {
            let changed = elementSeries.filter { $0.value.count > 1 }.sorted { $0.key < $1.key }
            if changed.isEmpty {
                lines.append("No SwiftUI element matching \"\(match)\" moved (\(elementSeries.count) found).")
            } else {
                lines.append("SwiftUI elements matching \"\(match)\":")
                for (name, samples) in changed { lines += describe(name, samples, flipFrom: nil) }
            }
        }
        return UntrustedContent.wrap(lines.joined(separator: "\n"), source: "Kite trace")
    }

    /// One line for start → end, then progress samples (at most 40) for the property that changed most.
    private func describe(_ name: String, _ samples: [Sample], flipFrom height: Double?) -> [String] {
        func rect(_ frame: CGRect) -> UIRect {
            // Layer frames are bottom-left in the window; accessibility frames were already converted.
            guard let height else { return UIRect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height) }
            return UIRect(x: frame.minX, y: height - frame.maxY, width: frame.width, height: frame.height)
        }
        let first = samples[0], last = samples[samples.count - 1]
        let a = rect(first.frame), b = rect(last.frame)
        let properties: [(String, (Sample) -> Double)] = [
            ("x", { rect($0.frame).x }), ("y", { rect($0.frame).y }), ("width", { rect($0.frame).width }),
            ("height", { rect($0.frame).height }), ("opacity", { Double($0.opacity) * 100 }),
        ]
        let (property, read) = properties.max { abs($0.1(last) - $0.1(first)) < abs($1.1(last) - $1.1(first)) }!
        let from = read(first), to = read(last)
        var lines = ["  \(name): [\(a.description)] → [\(b.description)]"
            + (first.opacity != last.opacity ? " opacity \(UIReport.number(Double(first.opacity))) → \(UIReport.number(Double(last.opacity)))" : "")
            + ", \(samples.count) samples over \(UIReport.number((last.time - first.time) * 1000)) ms"]
        if from != to {
            let stride = max(1, samples.count / 40)
            let points = Swift.stride(from: 0, to: samples.count, by: stride).map { samples[$0] } + (samples.count % stride == 0 ? [] : [last])
            let progress = points.map { "\(UIReport.number((($0.time - first.time) * 1000)))ms:\(UIReport.number((read($0) - from) / (to - from)))" }
            lines.append("    \(property) \(UIReport.number(property == "opacity" ? from / 100 : from))→\(UIReport.number(property == "opacity" ? to / 100 : to)) p: "
                + progress.joined(separator: " "))
        }
        return lines
    }
}

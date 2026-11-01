import Foundation

/// Arc's Peek: a link opened in a card floating over the current page, with buttons to close it, expand it
/// into a tab, or add it to a split. Not to be confused with the sidebar peek (the hidden sidebar sliding in).
///
/// Numbers come from Arc 1.171's `ModalContent.ModalV2HostView` in the `popover` layout mode (decompiled);
/// see docs/arc-visual-spec.md "Peek".
public enum LinkPeek {
    /// The undo action name for a closed Peek, so Edit shows "Undo Close Peek" (Arc's localized key "Close Peek",
    /// commented "Undo prompt for re-opening a closed Peek").
    public static let closeUndoActionName = "Close Peek"

    /// Settings › Links "Open a Peek window when clicking on links with Shift held": Arc 1.171's defaults key
    /// (inverted, so unset means on).
    public static let shiftClickDisabledKey = "disableShiftClickToOpenLinksInModal"
    /// Settings › Links "Open a Peek window when clicking on links to other sites": Arc 1.171's defaults key
    /// (unset means on).
    public static let otherSitesEnabledKey = "modalEnabled"

    /// The two Links switches, both on by default as in Arc.
    public struct Options: Equatable, Sendable {
        public var shiftClick: Bool
        public var otherSites: Bool
        public init(shiftClick: Bool = true, otherSites: Bool = true) {
            self.shiftClick = shiftClick
            self.otherSites = otherSites
        }

        public init(defaults: UserDefaults) {
            self.init(
                shiftClick: !defaults.bool(forKey: LinkPeek.shiftClickDisabledKey),
                otherSites: defaults.object(forKey: LinkPeek.otherSitesEnabledKey) as? Bool ?? true
            )
        }
    }

    /// Arc's Links settings: "Open a Peek window when clicking on links to other sites" (Favorites and
    /// Pinned tabs only), and "… on links with Shift held" (any tab). A switched-off case leaves the click
    /// to the page's normal handling (a ⇧-click then opens a window, as in Chromium).
    public static func opensInPeek(section: TabSection?, from source: URL?, to target: URL, shift: Bool,
                                   options: Options = Options()) -> Bool {
        guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              target.host() != nil else { return false }
        if shift { return options.shiftClick }
        guard options.otherSites, section == .pinned || section == .favorite else { return false }
        guard let sourceSite = SignInHandoff.site(source?.host()) else { return false }
        return sourceSite != SignInHandoff.site(target.host())
    }

    /// A frame in the host view's flipped coordinates (origin top left).
    public struct Frame: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    /// The card is 80% of the host's width, centred, 12pt below its top and 12pt above its bottom.
    public static let widthFraction = 0.8
    public static let verticalInset = 12.0
    public static let cornerRadius = 8.0
    /// The buttons' column sits this far right of the card, top-aligned with it.
    public static let controlsGap = 13.0
    public static let controlsWidth = 120.0
    /// Each button's row; the column is 90pt with two buttons, 135pt with three (split).
    public static let controlRowHeight = 45.0

    public static func cardFrame(hostWidth: Double, hostHeight: Double) -> Frame {
        let width = (hostWidth * widthFraction).rounded()
        return Frame(
            x: ((hostWidth - width) / 2).rounded(),
            y: verticalInset,
            width: width,
            height: max(0, hostHeight - 2 * verticalInset)
        )
    }

    public static func controlsFrame(card: Frame, buttons: Int) -> Frame {
        Frame(x: card.x + card.width + controlsGap, y: card.y, width: controlsWidth, height: Double(buttons) * controlRowHeight)
    }

    /// Card shadow: black, 30% opacity, 4pt blur, 1pt down.
    public static let shadowOpacity = 0.3
    public static let shadowRadius = 4.0
    public static let shadowOffsetY = 1.0
    /// A hairline outside the card: black at 25%, 0.5pt.
    public static let borderOpacity = 0.25
    public static let borderWidth = 0.5

    /// Arc's spring for the card (`CASpringAnimation` from a damping ratio and a response in seconds).
    public struct Spring: Equatable, Sendable {
        public var dampingRatio: Double
        public var response: Double
        /// Stiffness and damping for unit mass, as Arc derives them.
        public var stiffness: Double { pow(2 * Double.pi / response, 2) }
        public var damping: Double { 4 * Double.pi * dampingRatio / response }
    }

    public static let openSpring = Spring(dampingRatio: 0.865, response: 0.245)
    public static let closeSpring = Spring(dampingRatio: 0.895, response: 0.225)

    // MARK: Tween from the clicked link

    /// Arc opens the card from the element that was clicked (`tweenFromSource`: `sourceRectInWindow`,
    /// `sourceCornerRadius`): the card is scaled uniformly to the source's width and centred on it, then
    /// springs to its own frame. The corner radius is the source's divided by that scale, so it looks like
    /// the source's at the start.
    public struct SourceTween: Equatable, Sendable {
        /// Uniform scale of the card at the start (source width / card width).
        public var scale: Double
        /// Move of the card's centre to the source's centre, in the host's flipped points.
        public var dx, dy: Double
        /// The card layer's corner radius at the start (before the scale is applied).
        public var cornerRadius: Double
    }

    /// The radius Arc gives the source. Arc's page script returns no radius, so it is a constant the
    /// caller sets; its value wasn't found. **[unverified]**
    public static let sourceCornerRadius = 0.0

    /// Nil when the source is too small to tween from (the caller falls back).
    public static func sourceTween(source: Frame, card: Frame, cornerRadius: Double = sourceCornerRadius) -> SourceTween? {
        guard source.width >= 1, source.height >= 1, card.width >= 1 else { return nil }
        let scale = source.width / card.width
        return SourceTween(
            scale: scale,
            dx: (source.x + source.width / 2) - (card.x + card.width / 2),
            dy: (source.y + source.height / 2) - (card.y + card.height / 2),
            cornerRadius: cornerRadius / scale
        )
    }

    /// Page script for the clicked element. Like Arc's `WebContent+HoveredElementRect`: the element under the
    /// pointer (`elementFromPoint` at `point`, in the page's CSS pixels from its top-left corner, mapped
    /// through the visual viewport) and its `getBoundingClientRect`, when it is inside a link to `url`.
    /// Otherwise (the pointer moved off, or the link was opened from the keyboard or by a script) the link
    /// to `url` that has focus, or the first visible one. Returns `{x, y, width, height}` in CSS pixels of
    /// the visible viewport, or null.
    public static func sourceRectScript(point: (x: Double, y: Double)?, url: String) -> String {
        let target = (try? JSONSerialization.data(withJSONObject: [url], options: []))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        let at = point.map { "[\($0.x), \($0.y)]" } ?? "null"
        return """
        (() => {
          const url = \(target)[0], at = \(at);
          const vv = window.visualViewport;
          const s = vv ? vv.scale : 1, ox = vv ? vv.offsetLeft : 0, oy = vv ? vv.offsetTop : 0;
          const goesTo = (el) => { const a = el && el.closest && el.closest('a[href]'); return !!a && a.href === url; };
          const shown = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
          let el = at ? document.elementFromPoint(at[0] / s + ox, at[1] / s + oy) : null;
          if (!goesTo(el)) {
            const links = Array.from(document.querySelectorAll('a[href]')).filter((a) => a.href === url && shown(a));
            el = links.find((a) => a === document.activeElement || a.contains(document.activeElement)) || links[0];
          }
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return {x: (r.left - ox) * s, y: (r.top - oy) * s, width: r.width * s, height: r.height * s};
        })()
        """
    }

    /// The script's result as a frame in the page view's points (`zoom` is the page zoom, 1 = 100%).
    public static func sourceFrame(scriptResult: Any?, zoom: Double) -> Frame? {
        guard let dict = scriptResult as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            switch dict[key] {
            case let value as Double: value
            case let value as Int: Double(value)
            case let value as NSNumber: value.doubleValue
            default: nil
            }
        }
        guard let x = number("x"), let y = number("y"), let w = number("width"), let h = number("height"),
              [x, y, w, h].allSatisfy(\.isFinite), w > 0, h > 0 else { return nil }
        let z = zoom > 0 ? zoom : 1
        return Frame(x: x * z, y: y * z, width: w * z, height: h * z)
    }
}

// MARK: Swipe right to dismiss

extension LinkPeek {
    /// Arc's swipe to dismiss (`DismissMechanism.swipedRightToDismiss`): a two-finger scroll to the right tugs
    /// the card a little way with the fingers; letting go far enough closes the Peek, otherwise the card
    /// springs back. Arc 1.171 `ModalV2HostViewController` (init FUN_1017190e8, scroll handler FUN_10171c0f0)
    /// and `ModalV2HostView` (FUN_1017156ac, FUN_101717730, FUN_101716134, FUN_101717074); see
    /// docs/arc-visual-spec.md "Peek: swipe to dismiss".
    public enum Swipe {
        /// Letting go at least this far right (points of scrolling) closes the Peek while the fingers are
        /// still moving right (`minimumDismissTranslation`).
        public static let minimumDismissTranslation = 75.0
        /// …and this far when they've stopped (`minimumDismissTranslationNoVelocity`). Crossing it while
        /// dragging plays a haptic tap.
        public static let minimumDismissTranslationNoVelocity = 152.0
        /// The card moves this fraction of the scroll (`tugRubberbanding`).
        public static let tugRubberbanding = 0.06
        /// The card shrinks by this fraction per point of tug along the tug's main axis.
        public static let tugScalePerPoint = 0.001
        /// The card's hairline fades out over this much tug (points).
        public static let borderFadeDistance = 44.0
        /// The buttons' column slides back under the card by this much of a horizontal tug (and this much of a
        /// vertical one), relative to the card.
        public static let controlsHorizontalTugFactor = 1.25
        public static let controlsVerticalTugFactor = 0.25
        /// Letting go short of the threshold springs the card back (`contentTugAnimation`).
        public static let tugSpring = Spring(dampingRatio: 0.9, response: 0.6)
        /// Below this speed (points per second) the fingers count as stopped. Arc's `ScrollRecognizer`
        /// classifies its release velocity into a direction; its cut-off wasn't found. **[inferred]**
        public static let restingSpeed = 50.0

        /// A pair of numbers in the host's flipped points (x right, y down).
        public struct Vector: Equatable, Sendable {
            public var x, y: Double
            public init(x: Double, y: Double) {
                self.x = x
                self.y = y
            }
            public static let zero = Vector(x: 0, y: 0)
            public var length: Double { (x * x + y * y).squareRoot() }
            public var isHorizontal: Bool { abs(y) < abs(x) }
        }

        /// Which way the fingers were moving when they let go.
        public enum Release: Equatable, Sendable {
            case right, left, up, down, resting
        }

        public static func release(velocity: Vector) -> Release {
            guard velocity.length >= restingSpeed else { return .resting }
            if velocity.isHorizontal { return velocity.x > 0 ? .right : .left }
            return velocity.y > 0 ? .down : .up
        }

        /// How far the card follows a scroll `translation`.
        public static func tug(translation: Vector) -> Vector {
            Vector(x: translation.x * tugRubberbanding, y: translation.y * tugRubberbanding)
        }

        /// Whether letting go closes the Peek: far enough right, and either still moving right or stopped and
        /// past the farther threshold. Moving any other way springs back.
        public static func dismisses(translationX: Double, release: Release) -> Bool {
            guard translationX >= minimumDismissTranslation else { return false }
            switch release {
            case .right: return true
            case .resting: return translationX >= minimumDismissTranslationNoVelocity
            case .left, .up, .down: return false
            }
        }

        /// A haptic tap when a drag crosses the farther threshold going right.
        public static func crossesHapticThreshold(from previousX: Double, to x: Double) -> Bool {
            previousX < minimumDismissTranslationNoVelocity && x >= minimumDismissTranslationNoVelocity
        }

        /// The card's uniform scale for a tug: it shrinks along the tug's main axis.
        public static func scale(tug: Vector) -> Double {
            1 - (tug.isHorizontal ? tug.x : tug.y) * tugScalePerPoint
        }

        /// The hairline's opacity for a tug.
        public static func borderOpacity(tug: Vector) -> Double {
            max(0, (1 - tug.length / borderFadeDistance) * LinkPeek.borderOpacity)
        }

        /// How far left the buttons' column moves relative to the card.
        public static func controlsOffset(tug: Vector) -> Double {
            tug.isHorizontal ? tug.x * controlsHorizontalTugFactor : tug.y * controlsVerticalTugFactor
        }

        /// Release velocity in points per second from recent scroll samples (time in seconds, deltas in points),
        /// measured over the last `window` seconds before `end`.
        public static func velocity(samples: [(time: Double, dx: Double, dy: Double)], end: Double,
                                    window: Double = 0.1) -> Vector {
            let recent = samples.filter { end - $0.time <= window }
            guard window > 0, !recent.isEmpty else { return .zero }
            let dx = recent.reduce(0) { $0 + $1.dx }, dy = recent.reduce(0) { $0 + $1.dy }
            return Vector(x: dx / window, y: dy / window)
        }
    }
}

extension LinkPeek.Spring {
    /// Where a value released at `value` with `velocity` (per second) is `t` seconds later on its way to 0, and
    /// its velocity then: the damped spring Arc's animator integrates (unit mass, stiffness and damping as above).
    public func settle(value: Double, velocity: Double, after t: Double) -> (value: Double, velocity: Double) {
        let omega = 2 * Double.pi / response
        let zeta = dampingRatio
        if zeta < 1 {
            let wd = omega * (1 - zeta * zeta).squareRoot()
            let decay = exp(-zeta * omega * t)
            let b = (velocity + zeta * omega * value) / wd
            let c = cos(wd * t), s = sin(wd * t)
            let x = decay * (value * c + b * s)
            let v = decay * ((-zeta * omega) * (value * c + b * s) + (-value * wd * s + b * wd * c))
            return (x, v)
        }
        // Critically damped (or over-damped, treated as critical).
        let decay = exp(-omega * t)
        let b = velocity + omega * value
        return (decay * (value + b * t), decay * (b - omega * (value + b * t)))
    }
}

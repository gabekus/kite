import Foundation

/// Arc's Peek: a link opened in a card floating over the current page, with buttons to close it, expand it
/// into a tab, or add it to a split. Not to be confused with the sidebar peek (the hidden sidebar sliding in).
///
/// Numbers come from Arc 1.171's `ModalContent.ModalV2HostView` in the `popover` layout mode (decompiled);
/// see docs/arc-visual-spec.md "Peek".
public enum LinkPeek {
    /// Arc's Links settings: "Open a Peek window when clicking on links to other sites" (Favorites and
    /// Pinned tabs only), and "… on links with Shift held" (any tab).
    public static func opensInPeek(section: TabSection?, from source: URL?, to target: URL, shift: Bool) -> Bool {
        guard let scheme = target.scheme?.lowercased(), scheme == "http" || scheme == "https",
              target.host() != nil else { return false }
        if shift { return true }
        guard section == .pinned || section == .favorite else { return false }
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

import CoreGraphics
import Foundation

/// Two-finger swipe back/forward on Chromium pages: the decisions, kept free of AppKit so
/// they can be tested.
///
/// Evidence (see the PR): Arc ships Chromium's own `HistorySwiper` and
/// `HistoryOverlayController`/`HistoryOverlayView` in ArcCore.framework, hosted in Arc's
/// `PaneHostHistoryOverlayContainerView` (strings and Objective-C type encodings in
/// ArcCore). The overlay numbers below are Chromium's
/// `chrome/browser/ui/cocoa/history_overlay_controller.mm`; the method type encodings in
/// Arc's binary match that file, but the constants themselves weren't read out of Arc.
public enum HistorySwipe {
    public enum Direction: String, Sendable {
        case back, forward
    }

    // MARK: Recognising the gesture

    /// Scroll distance (points) a gesture must cover before its axis is decided.
    /// Unverified: Chromium decides from trackpad touches (any x movement over 0.001 of the
    /// pad's width), which a scroll-event recogniser can't see; this is the scroll-delta stand-in.
    public static let decisionDistance: CGFloat = 6

    /// A gesture stays horizontal only while `|dy| * 1.3 <= |dx|`. Chromium's
    /// `shouldCancelHorizontalSwipeWithCurrentPoint:` ratio (applied there to touch positions).
    public static let verticalRatio: CGFloat = 1.3

    /// Which way a gesture navigates, from its accumulated scrolling deltas (AppKit's
    /// `scrollingDeltaX/Y`, already in content direction). nil while it's undecided or vertical.
    /// Content moving right (dx > 0) is the page being pulled back: Chromium maps
    /// `scrollingDeltaX < 0` to forwards.
    public static func direction(dx: CGFloat, dy: CGFloat) -> Direction? {
        guard abs(dx) + abs(dy) >= decisionDistance, abs(dy) * verticalRatio <= abs(dx) else { return nil }
        return dx > 0 ? .back : .forward
    }

    /// Whether a gesture with these deltas has been decided at all (either axis).
    public static func isDecided(dx: CGFloat, dy: CGFloat) -> Bool {
        abs(dx) + abs(dy) >= decisionDistance
    }

    /// What the page under the pointer can do horizontally, as the renderer reports it.
    public struct PageScroll: Equatable, Sendable {
        /// Some element under the pointer (or the document) can still scroll left / right.
        public var canScrollLeft: Bool
        public var canScrollRight: Bool
        /// `overscroll-behavior-x: none | contain` stops the gesture leaving the page, like
        /// Chromium's `overscroll_behavior.PropagatesXScroll()` check.
        public var blocksOverscroll: Bool

        public init(canScrollLeft: Bool, canScrollRight: Bool, blocksOverscroll: Bool) {
            self.canScrollLeft = canScrollLeft
            self.canScrollRight = canScrollRight
            self.blocksOverscroll = blocksOverscroll
        }

        /// Parses the scrollability script's result.
        public init?(_ value: Any?) {
            guard let object = value as? [String: Any] else { return nil }
            self.init(canScrollLeft: object["left"] as? Bool ?? false,
                      canScrollRight: object["right"] as? Bool ?? false,
                      blocksOverscroll: object["blocked"] as? Bool ?? false)
        }

        /// Navigating back means pulling content right, which the page would use to scroll left.
        public func allowsNavigation(_ direction: Direction) -> Bool {
            if blocksOverscroll { return false }
            return direction == .back ? !canScrollLeft : !canScrollRight
        }
    }

    /// JavaScript returning `{left, right, blocked}` for the element at a point (CSS pixels),
    /// walking up through scrollable ancestors and into same-origin iframes.
    public static func scrollabilityScript(x: CGFloat, y: CGFloat) -> String {
        """
        (() => {
          let doc = document, x = \(Double(x)), y = \(Double(y));
          const out = {left: false, right: false, blocked: false};
          for (let depth = 0; depth < 8 && doc; depth++) {
            let el = doc.elementFromPoint(x, y), next = null;
            if (el && el.tagName === 'IFRAME') {
              try {
                const r = el.getBoundingClientRect();
                if (el.contentDocument) { next = el.contentDocument; x -= r.left + el.clientLeft; y -= r.top + el.clientTop; }
              } catch (e) {}
            }
            const root = doc.scrollingElement || doc.documentElement;
            for (; el; el = el.parentElement) {
              const s = getComputedStyle(el), isRoot = el === root;
              const scrollable = isRoot ? el.scrollWidth > el.clientWidth && s.overflowX !== 'hidden' && s.overflowX !== 'clip'
                                        : (s.overflowX === 'auto' || s.overflowX === 'scroll') && el.scrollWidth > el.clientWidth;
              if (scrollable) {
                if (el.scrollLeft > 0) out.left = true;
                if (el.scrollLeft + el.clientWidth < el.scrollWidth - 1) out.right = true;
              }
              if ((scrollable || isRoot || el === doc.body) && s.overscrollBehaviorX !== 'auto') out.blocked = true;
              if (out.blocked || (out.left && out.right)) return out;
            }
            doc = next;
          }
          return out;
        })()
        """
    }

    // MARK: Progress

    /// The gesture completes at this fraction of the page's width. Unverified for trackpads:
    /// it's the 0.3 `gestureAmount` threshold Chromium's HistorySwiper uses with
    /// `trackSwipeEventWithOptions:` (Magic Mouse); its trackpad path measures 0.08 of the
    /// touch pad's width instead, which scroll events don't report.
    public static let completionFraction: CGFloat = 0.3

    /// Progress 0…1 towards navigating, and whether it's past the threshold.
    public static func progress(dx: CGFloat, direction: Direction, pageWidth: CGFloat) -> (progress: CGFloat, finished: Bool) {
        guard pageWidth > 0 else { return (0, false) }
        let signed = direction == .back ? dx : -dx
        let raw = signed / (pageWidth * completionFraction)
        return (min(max(raw, 0), 1), raw >= 1)
    }

    // MARK: Indicator (Chromium's history overlay)

    /// The shield is a circle of this radius; half of it at most slides in from the edge.
    public static let shieldRadius: CGFloat = 70
    public static let shieldHeight: CGFloat = 140
    /// Added to the height once the gesture will navigate.
    public static let shieldHeightCompletionAdjust: CGFloat = 10
    public static let shieldMinAlpha: CGFloat = 0.25
    public static let shieldMaxAlpha: CGFloat = 0.65
    public static let shieldFinishedAlpha: CGFloat = 0.75
    /// The overlay fades out over this when the gesture ends.
    public static let fadeOutDuration: TimeInterval = 0.4
    /// The arrow sits in the inner half of the circle, inset this much on each side.
    public static let arrowInset: CGFloat = 10

    /// The shield's frame in its container (bottom-left origin, as AppKit's default) and its
    /// black fill alpha. Chromium's `-[HistoryOverlayController setProgress:finished:]`.
    public static func shield(direction: Direction, progress: CGFloat, finished: Bool,
                              in parent: CGRect) -> (frame: CGRect, alpha: CGFloat) {
        var height = shieldHeight
        var alpha = min(shieldMaxAlpha, max(progress, shieldMinAlpha))
        if finished {
            height += shieldHeightCompletionAdjust
            alpha = shieldFinishedAlpha
        }
        let width = min(shieldRadius * progress, shieldRadius)
        let x = direction == .forward ? parent.maxX - width : parent.minX - shieldRadius * 2 + width
        return (CGRect(x: x, y: parent.height / 2 - height / 2, width: shieldRadius * 2, height: height), alpha)
    }
}

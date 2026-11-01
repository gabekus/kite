import Foundation

/// Arc's two ⌘F bars (Arc 1.171 binary, docs/arc-visual-spec.md "Find bar"). With Ask on Page off,
/// Arc shows its AppKit `FindInPageView`; with it on, its SwiftUI `AskInPageView`, a wider card that
/// holds the conversation too. Points.
public enum FindBarStyle: Sendable, Equatable {
    /// Ask on Page off (`FindInPageView`).
    case find
    /// Ask on Page on (`AskInPageView`).
    case ask

    public init(askEnabled: Bool) { self = askEnabled ? .ask : .find }

    /// Preferred width. Arc's width constraint has priority 250, under the 750 of the leading
    /// inset, so a narrow card narrows the bar.
    public var width: Double { self == .find ? 300 : 400 }

    /// Gap to the content card's top and trailing edges, and the least gap to its leading edge
    /// (`WindowContentViewController`: 10 for the find view, 20 for the ask view).
    public var inset: Double { self == .find ? 10 : 20 }

    /// `FindInPageView.updateLayer` sets 5; the ask view's popover background is a 10pt continuous
    /// rounded rectangle.
    public var cornerRadius: Double { self == .find ? 5 : 10 }

    /// The find view appears and goes with `isHidden`; the ask view slides in from above and back up.
    public var slides: Bool { self == .ask }

    /// The ask card is never taller than the content card less this (top and bottom gaps).
    public static let askVerticalMargin: Double = 40

    /// `FindInPageView.layout`: the separator layer is 1pt wide, 7pt from the bar's top, and
    /// 14pt shorter than the bar.
    public static func dividerHeight(barHeight: Double) -> Double { barHeight - 14 }

    /// How far above its place the ask card starts when it slides in.
    public static let askShowOffset: Double = 300

    /// How far up the ask card slides to leave: past the content card's top edge.
    public static func askHiddenOffset(height: Double) -> Double { 20 + height + askVerticalMargin }

    public struct Spring: Sendable, Equatable {
        public var mass: Double
        public var stiffness: Double
        public var damping: Double
    }

    /// Arc's `CASpringAnimation` helper turns a response and damping fraction into stiffness
    /// (2π / response)² · mass and damping 4π · fraction · mass / response; the ask card uses
    /// response 0.28 s and fraction 0.63 both ways.
    public static func spring(response: Double, dampingFraction: Double, mass: Double = 1) -> Spring {
        let omega = 2 * Double.pi / response
        return Spring(mass: mass, stiffness: omega * omega * mass,
                      damping: 4 * Double.pi * dampingFraction * mass / response)
    }

    public static let spring = spring(response: 0.28, dampingFraction: 0.63)
}

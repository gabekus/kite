import AppKit
import KiteCore
import SwiftUI

/// Where the sidebar's space pages sit while two fingers swipe between spaces. The window controller
/// moves it from scroll events; `SpacePages` draws from it.
@MainActor
@Observable
final class SpaceSwipeModel {
    /// Points from rest; positive shows the previous space coming in from the left.
    var offset: CGFloat = 0
    /// While the pages settle after a switch, the space the switch left: its neighbours stay built
    /// until the pages come to rest (`SpaceSwipe.builtPages`).
    var anchor: UUID?
    /// The page width last laid out: the swipe's whole travel.
    var pageWidth: CGFloat = 0
}

/// Arc pages its sidebar horizontally, one page per space, under the favorites, which stay put
/// (`SidebarPagingContainerViewController`; the favorites are their own section of the same
/// collection view, docs/arc-visual-spec.md "Spaces"). Pages are a full sidebar wide.
///
/// Like Arc's clip view, the pages move as one strip: only `PageSlide` reads the offset, so a frame
/// of a swipe moves the strip without rebuilding any page.
struct SpacePages<Page: View>: View {
    private typealias M = ArcMetrics.Sidebar
    let store: BrowserStore
    let swipe: SpaceSwipeModel
    @ViewBuilder let page: (Space) -> Page

    var body: some View {
        let state = store.state
        let selected = state.selectedSpaceIndex
        let built = SpaceSwipe.builtPages(selected: selected, anchor: swipe.anchor.flatMap(state.spaceIndex),
                                          count: state.spaces.count)
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(built.map { state.spaces[$0] }) { space in
                    let index = state.spaceIndex(space.id) ?? selected
                    page(space)
                        .padding(.horizontal, M.padding)
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: CGFloat(index - selected) * width)
                        // Off-page rows mustn't take clicks meant for the current page.
                        .allowsHitTesting(index == selected)
                        // Nor keyboard focus or VoiceOver while they're off to the side.
                        .accessibilityHidden(index != selected)
                }
            }
            .modifier(PageSlide(swipe: swipe))
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            .onAppear { swipe.pageWidth = width }
            .onChange(of: width) { _, new in swipe.pageWidth = new }
        }
        // The pages span the whole sidebar, not just its padded column.
        .padding(.horizontal, -M.padding)
    }
}

/// The swipe's offset, applied to the whole strip of pages. Its own view, so a change re-runs only this
/// body and not the pages'.
private struct PageSlide: ViewModifier {
    let swipe: SpaceSwipeModel

    func body(content: Content) -> some View {
        content.offset(x: swipe.offset)
    }
}

/// The sidebar's hosting view. It clips what it draws to its bounds with a layer mask rather than
/// `clipsToBounds` or a SwiftUI clip: either of those bounds the pages' visible rect, so each page's tab
/// list would drop its rows while it sits off to the side and build them all again on the first frame of
/// a swipe. Masked, the neighbouring pages keep their rows and draw nothing outside the sidebar.
final class SidebarHostingView: NSHostingView<SidebarView> {
    private let clip = CALayer()

    override func layout() {
        super.layout()
        guard let layer else { return }
        if layer.mask !== clip {
            clip.backgroundColor = NSColor.black.cgColor
            layer.mask = clip
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = layer.bounds
        CATransaction.commit()
    }
}

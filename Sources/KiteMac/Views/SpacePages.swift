import KiteCore
import SwiftUI

/// Where the sidebar's space pages sit while two fingers swipe between spaces. The window controller
/// moves it from scroll events; `SpacePages` draws from it.
@MainActor
@Observable
final class SpaceSwipeModel {
    /// Points from rest; positive shows the previous space coming in from the left.
    var offset: CGFloat = 0
    /// The neighbouring pages are drawn only while a swipe or its settle is on screen.
    var showsNeighbours = false
    /// The page width last laid out: the swipe's whole travel.
    var pageWidth: CGFloat = 0
}

/// Arc pages its sidebar horizontally, one page per space, under the favorites, which stay put
/// (`SidebarPagingContainerViewController`; the favorites are their own section of the same
/// collection view, docs/arc-visual-spec.md "Spaces"). Pages are a full sidebar wide.
struct SpacePages<Page: View>: View {
    private typealias M = ArcMetrics.Sidebar
    let store: BrowserStore
    let swipe: SpaceSwipeModel
    @ViewBuilder let page: (Space) -> Page

    var body: some View {
        let state = store.state
        let selected = state.selectedSpaceIndex
        let range = swipe.showsNeighbours
            ? max(selected - 1, 0)...min(selected + 1, state.spaces.count - 1)
            : selected...selected
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .topLeading) {
                ForEach(state.spaces[range]) { space in
                    let index = state.spaceIndex(space.id) ?? selected
                    page(space)
                        .padding(.horizontal, M.padding)
                        .frame(width: width, height: geometry.size.height)
                        .offset(x: CGFloat(index - selected) * width + swipe.offset)
                        // Off-page rows mustn't take clicks meant for the current page.
                        .allowsHitTesting(index == selected)
                }
            }
            .frame(width: width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .onAppear { swipe.pageWidth = width }
            .onChange(of: width) { _, new in swipe.pageWidth = new }
        }
        // The pages span the whole sidebar, not just its padded column.
        .padding(.horizontal, -M.padding)
    }
}

import AppKit
import KiteCore
import Observation
import SwiftUI

/// One window's Library (Window › Open Library… ⇧⌘L): open or not, and the page it shows.
/// Arc keeps it per window (`WindowState+Library`) and remembers the last page for every window
/// (`lastSelectedHomePage`).
@MainActor
@Observable
final class LibraryModel {
    static let lastPageKey = "LibraryLastPage"

    private(set) var isOpen = false
    var page: LibraryPage {
        didSet { UserDefaults.standard.set(page.rawValue, forKey: Self.lastPageKey) }
    }
    @ObservationIgnored var onOpenChange: ((Bool) -> Void)?

    init() {
        page = LibraryPage(stored: UserDefaults.standard.string(forKey: Self.lastPageKey))
    }

    /// Opens on `page`, or on the last page shown.
    func open(_ page: LibraryPage? = nil) {
        if let page { self.page = page }
        guard !isOpen else { return }
        isOpen = true
        onOpenChange?(true)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        onOpenChange?(false)
    }

    func toggle() { isOpen ? close() : open() }
}

/// Arc's Library ("Arc Home", `HomeButton.HomeViewController`): it takes over the window, its pages
/// listed down the sidebar (`PageSidebarItem`) and the chosen page in the card, with a button to
/// exit the Library ("Button; Exit the Library"). Sizes, icons and the exit button's look are
/// Kite's: Arc's Library wasn't measured.
struct LibraryView: View {
    let model: LibraryModel
    let store: BrowserStore
    let sidebarWidth: CGFloat
    let archiveActions: ArchiveActions
    let boostActions: BoostActions

    struct ArchiveActions {
        let open: (URL, _ newTab: Bool) -> Void
        let restore: (UUID) -> Void
    }

    struct BoostActions {
        /// Arc's onSelectBoost: the Boost's site with its editor.
        let open: (Boost) -> Void
        /// The window the rename and delete alerts attach to.
        let window: () -> NSWindow?
    }

    enum Metrics {
        /// Below the traffic lights, like the sidebar's first row.
        static let topInset: CGFloat = 44
        static let rowHeight: CGFloat = 34
        static let rowRadius: CGFloat = 8
        static let sideInset: CGFloat = 8
    }

    var body: some View {
        HStack(spacing: 0) {
            pageList
                .frame(width: sidebarWidth)
            card
                .padding([.top, .bottom, .trailing], ArcMetrics.Content.inset)
        }
        // Under the transparent titlebar, like the sidebar and the card.
        .ignoresSafeArea()
        // The window's material and the space's tint show through around the card.
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Library")
    }

    private var pageList: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(LibraryPage.allCases, id: \.self) { page in
                PageRow(page: page, selected: model.page == page) { model.page = page }
            }
            Spacer(minLength: 0)
            Button { model.close() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left")
                        .frame(width: 18)
                    Text("Exit Library")
                    Spacer(minLength: 0)
                }
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 10)
                .frame(height: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(0.8)
            .help("Exit the Library")
            .accessibilityLabel("Exit the Library")
            .padding(.bottom, 10)
        }
        .padding(.top, Metrics.topInset)
        .padding(.horizontal, Metrics.sideInset)
    }

    private var card: some View {
        Group {
            switch model.page {
            case .downloads:
                DownloadsList()
                    .background(Color(nsColor: .windowBackgroundColor))
            case .archive:
                ArchivePageView(store: store, open: archiveActions.open, restore: archiveActions.restore)
            case .media:
                MediaPageView { url in archiveActions.open(url, false) }
            case .boosts:
                BoostsListView(open: boostActions.open, window: boostActions.window)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: ArcMetrics.Content.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}

private struct PageRow: View {
    let page: LibraryPage
    let selected: Bool
    let select: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: select) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .frame(width: 18)
                Text(page.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: LibraryView.Metrics.rowHeight)
            .background(
                RoundedRectangle(cornerRadius: LibraryView.Metrics.rowRadius, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.15 : hovering ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// Arc animates a Lottie icon per page (downloads-combined, archive-combined); Kite uses SF Symbols:
    /// Arc's own View Downloads menu icon, and a tray for the Archive.
    private var symbol: String {
        switch page {
        case .downloads: "arrow.down.circle"
        case .archive: "tray.full"
        // Arc's welcome-card symbol for the page.
        case .media: "photo.on.rectangle.angled"
        // Arc animates its "boosts" Lottie; its empty state draws the paintbrush symbol.
        case .boosts: "paintbrush"
        }
    }
}

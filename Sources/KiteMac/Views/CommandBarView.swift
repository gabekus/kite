import AppKit
import KiteCore
import SwiftUI

enum CommandSuggestion: Identifiable, Hashable {
    case open(URL)
    case search(String, URL)
    /// A search on one site, after its Site Search shortcut and Tab.
    case siteSearch(SiteSearch, String, URL)
    case switchTab(BrowserTab)
    case history(HistoryEntry)
    case command(MenuCommand)
    /// ⇧⏎ on a search: Arc Max's Instant Links opens the top result(s) instead.
    case instantLinks(String)

    var id: String {
        switch self {
        case .open(let url): "open:\(url.absoluteString)"
        case .search(let query, _): "search:\(query)"
        case .siteSearch(let site, let query, _): "site:\(site.id):\(query)"
        case .switchTab(let tab): "tab:\(tab.id)"
        case .history(let entry): "history:\(entry.url.absoluteString)"
        case .command(let command): "command:\(command.path)/\(command.title)"
        case .instantLinks(let query): "instant:\(query)"
        }
    }
}

private typealias C = ArcMetrics.CommandBar

/// Arc's panel: a dark tint over the blurred page, a hairline border, a wide soft shadow.
/// ⌘J's Claude bar uses the same panel with `accent` set: the border and a faint glow
/// take that colour instead of white.
struct CommandBarPanel: ViewModifier {
    var accent: Color?
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: C.cornerRadius, style: .circular)
        content
            .background {
                ZStack {
                    PanelMaterial(material: scheme == .dark ? .hudWindow : .popover)
                    Color(white: scheme == .dark ? C.darkTint : C.lightTint).opacity(C.tintOpacity)
                }
                .clipShape(shape)
            }
            .overlay(shape.strokeBorder(border, lineWidth: 1))
            // A black hairline just outside the border, which shows on light pages.
            .overlay(
                RoundedRectangle(cornerRadius: C.cornerRadius + C.outlineWidth, style: .circular)
                    .strokeBorder(Color.black, lineWidth: C.outlineWidth)
                    .padding(-C.outlineWidth)
            )
            .shadow(color: .black.opacity(C.shadowOpacity), radius: C.shadowRadius, y: C.shadowY)
            .shadow(color: (accent ?? .clear).opacity(C.accentGlowOpacity), radius: C.accentGlowRadius)
    }

    private var border: Color {
        if let accent { return accent.opacity(C.accentBorderOpacity) }
        return scheme == .dark ? Color.white.opacity(C.borderOpacity) : Color.black.opacity(0.12)
    }
}

/// The blurred page under the panel. Within-window blending samples the web view too,
/// since the window server composites Chromium's layers into the backdrop.
private struct PanelMaterial: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
    }
}


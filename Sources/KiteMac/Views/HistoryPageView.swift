import AppKit
import KiteCore
import SwiftUI

/// Kite's history page (kite://history), opened by ⌘Y in a new tab as Arc opens Chromium's
/// chrome://history. The layout follows Chromium's history page: a search field, one card per
/// day ("Today - Saturday, October 31, 2026"), rows with the time, icon, title and site, and a
/// menu per row with More from This Site and Remove from History. Kite keeps one entry per URL
/// (its last visit), so a page visited on several days is listed once, on the latest.
struct HistoryPageView: View {
    /// nil in incognito windows, which keep no history.
    let store: HistoryStore?
    /// Opens a history entry: in this tab, or (⌘-click) in a new background tab.
    let open: (URL, _ newTab: Bool) -> Void

    @State private var query = ""
    @State private var confirmingClear = false

    enum Metrics {
        static let maxWidth: CGFloat = 960
        static let rowHeight: CGFloat = 40
        static let timeWidth: CGFloat = 76
        static let cardRadius: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let store {
                list(store)
            } else {
                message("Incognito windows don't save history")
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Clear all browsing history?", isPresented: $confirmingClear) {
            Button("Clear History", role: .destructive) { store?.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every page in Kite's history is removed. Open tabs, the archive and site data are kept.")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            Text("History")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 160, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search history", text: $query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("historySearch")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear Search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: 680)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            Spacer(minLength: 0)
            Button("Clear History…") { confirmingClear = true }
                .disabled(store?.history.entries.isEmpty ?? true)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    @ViewBuilder
    private func list(_ store: HistoryStore) -> some View {
        let days = store.history.days(matching: query)
        if days.isEmpty {
            message(query.isEmpty ? "Pages you visit appear here" : "No search results found")
        } else {
            ScrollView {
                LazyVStack(spacing: 16) {
                    ForEach(days, id: \.start) { day in
                        card(day, store: store)
                    }
                }
                .frame(maxWidth: Metrics.maxWidth)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func card(_ day: HistoryDay, store: HistoryStore) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(day.heading())
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 44)
            ForEach(day.entries, id: \.url) { entry in
                HistoryRow(entry: entry, open: open, moreFromSite: { query = $0 }, remove: { store.remove([$0]) })
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let open: (URL, Bool) -> Void
    let moreFromSite: (String) -> Void
    let remove: (URL) -> Void
    @State private var hovered = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var host: String {
        (entry.url.host() ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(Self.time.string(from: entry.lastVisit))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: HistoryPageView.Metrics.timeWidth, alignment: .leading)
            FaviconView(page: entry.url)
            Text(entry.displayTitle)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(host)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Menu {
                menuItems
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Actions")
        }
        .padding(.horizontal, 16)
        .frame(height: HistoryPageView.Metrics.rowHeight)
        .background(hovered ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            open(entry.url, NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu { menuItems }
        .help(entry.url.absoluteString)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isLink)
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Open Link in New Tab") { open(entry.url, true) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.absoluteString, forType: .string)
        }
        Divider()
        Button("More from This Site") { moreFromSite(host) }
            .disabled(host.isEmpty)
        Button("Remove from History") { remove(entry.url) }
    }
}

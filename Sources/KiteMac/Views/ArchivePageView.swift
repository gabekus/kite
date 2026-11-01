import AppKit
import KiteCore
import SwiftUI

/// Arc's archive (Archive › View Archive…), from Arc 1.171's strings: the archived tabs newest first
/// under "Today", "Yesterday" and "Earlier This Week"; a search field; a "Filter Archived Tabs" menu with
/// "Where was the tab?" (a space, or Little Kite: Arc's Little Arc filter) and "How was the tab closed?" (Auto-Closed / Manually Closed), whose
/// picks show as removable chips; Restore and Delete as hover buttons and in each row's context menu; and
/// "Nothing here yet!" when empty. Shown in the Library (`LibraryView`, as in Arc) and as a tab at
/// kite://archive.
struct ArchivePageView: View {
    let store: BrowserStore
    /// Opens an archived tab's page: in this tab, or (⌘-click) in a new background tab.
    let open: (URL, _ newTab: Bool) -> Void
    /// Arc's Restore: the tab goes back to its space. The host shows Arc's "Tab restored to" toast.
    let restore: (UUID) -> Void

    @State private var filter = ArchiveFilter()

    enum Metrics {
        static let maxWidth: CGFloat = 960
        static let rowHeight: CGFloat = 40
        static let cardRadius: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var spaces: [Space] { store.state.spaces }

    private var header: some View {
        HStack(spacing: 16) {
            Text("Archive")
                .font(.system(size: 20, weight: .regular))
                .frame(width: 160, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search archive", text: $filter.query)
                    .textFieldStyle(.plain)
                    .accessibilityIdentifier("archiveSearch")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("Clear Search")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .frame(maxWidth: 680)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
            filterMenu
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 56)
    }

    private var filterMenu: some View {
        Menu {
            Section("Where was the tab?") {
                ForEach(spaces) { space in
                    Toggle("\(space.icon) \(space.name)", isOn: sourceBinding(.space(space.id)))
                }
                // Arc's "Little Arc" filter: pages archived from Little Kite windows.
                Toggle(Self.littleKiteTitle, isOn: sourceBinding(.littleKite))
            }
            Section("How was the tab closed?") {
                ForEach([ArchiveReason.auto, .manual], id: \.self) { reason in
                    Toggle(reason.title, isOn: Binding(
                        get: { filter.reason == reason },
                        set: { filter.reason = $0 ? reason : nil }))
                }
            }
        } label: {
            Image(systemName: filter.source == nil && filter.reason == nil
                  ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                .font(.system(size: 16))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter Archived Tabs")
        .accessibilityLabel("Filter Archived Tabs")
    }

    static let littleKiteTitle = "Little Kite"

    private func sourceBinding(_ source: ArchiveFilter.Source) -> Binding<Bool> {
        Binding(get: { filter.source == source },
                set: { filter.source = $0 ? source : nil })
    }

    private var chips: [(title: String, remove: () -> Void)] {
        var chips: [(String, () -> Void)] = []
        switch filter.source {
        case .space(let id):
            let name = spaces.first { $0.id == id }.map { "\($0.icon) \($0.name)" } ?? "Space"
            chips.append((name, { filter.source = nil }))
        case .littleKite:
            chips.append((Self.littleKiteTitle, { filter.source = nil }))
        case nil:
            break
        }
        if let reason = filter.reason { chips.append((reason.title, { filter.reason = nil })) }
        return chips
    }

    @ViewBuilder
    private var content: some View {
        let sections = store.state.archiveSections(filter)
        VStack(spacing: 0) {
            if !chips.isEmpty {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.title) { chip in
                        Button(action: chip.remove) {
                            HStack(spacing: 4) {
                                Text(chip.title).font(.system(size: 12))
                                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                            }
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                        .help("Remove \(chip.title) Filter")
                    }
                    Spacer()
                }
                .frame(maxWidth: Metrics.maxWidth)
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            if sections.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 16) {
                        ForEach(sections, id: \.bucket) { section in
                            card(section)
                        }
                    }
                    .frame(maxWidth: Metrics.maxWidth)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        VStack(spacing: 6) {
            if !query.isEmpty {
                Text("No results found for \u{201C}\(query)\u{201D}")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            } else if store.state.archived.isEmpty {
                Text("Nothing here yet!")
                    .font(.system(size: 15, weight: .semibold))
                Text("Hover your mouse over a tab and press the \u{00D7} to archive it.")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            } else {
                Text("No archived tabs match these filters")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func card(_ section: ArchiveSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(section.title())
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .frame(height: 44)
            ForEach(section.items, id: \.tab.id) { item in
                ArchiveRow(
                    item: item,
                    space: item.isLittleKite ? nil : spaces.first { $0.id == item.spaceID },
                    open: open,
                    restore: { restore(item.tab.id) },
                    delete: { store.mutate { $0.deleteArchived([item.tab.id]) } })
            }
        }
        .padding(.bottom, 8)
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

private struct ArchiveRow: View {
    let item: ClosedTab
    let space: Space?
    let open: (URL, Bool) -> Void
    let restore: () -> Void
    let delete: () -> Void
    @State private var hovered = false

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private var title: String {
        if !item.tab.title.isEmpty { return item.tab.title }
        return item.tab.url?.absoluteString ?? "Untitled"
    }

    private var subtitle: String {
        let host = (item.tab.url?.host() ?? "").replacingOccurrences(of: "www.", with: "", options: .anchored)
        let place = item.isLittleKite ? ArchivePageView.littleKiteTitle : space.map { "\($0.icon) \($0.name)" }
        return [host, place].compactMap { $0 }.filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            FaviconView(tab: item.tab)
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if hovered {
                accessory("arrow.uturn.left", "Restore", restore)
                accessory("trash", "Delete", delete)
            } else {
                Text(Self.time.string(from: item.archiveDate))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: ArchivePageView.Metrics.rowHeight)
        .background(hovered ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture {
            guard let url = item.tab.url else { return }
            open(url, NSEvent.modifierFlags.contains(.command))
        }
        .contextMenu {
            Button("Restore", action: restore)
            Button("Delete", action: delete)
        }
        .help(item.tab.url?.absoluteString ?? "")
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }

    private func accessory(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(label)
        .accessibilityLabel(label)
    }
}

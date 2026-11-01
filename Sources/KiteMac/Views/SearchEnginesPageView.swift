import AppKit
import KiteCore
import SwiftUI

/// Settings › Profiles › "Search Settings…" (kite://search-engines). Arc's button opens Chromium's
/// "Manage search engines and site search" page (`arc://settings/searchEngines`) in a new tab; Kite
/// draws its own over its Site Search store, laid out like Chromium's: a "Search engines" card with
/// the default marked "(Default)" and a Make default menu, then a "Site search" card with Add and
/// each shortcut's Edit / Delete menu. Add and Edit open Chromium's in-page dialog (Name, Shortcut,
/// "URL with %s in place of query"). Wording from Arc 1.171's Chromium strings (ArcCore locale.pak).
struct SearchEnginesPageView: View {
    let store: BrowserStore

    /// The dialog: nil when closed; `id` nil for Add.
    @State private var editing: Editing?
    /// The header's filter field (Chromium's subpage search field, "Filter sites on page").
    @State private var filter = ""
    /// Chromium shows 5 rows of each site-search list, the rest behind an expand row.
    @State private var showsAllActive = false
    @State private var showsAllInactive = false

    struct Editing: Identifiable {
        var id: UUID?
        var draft: SiteSearchDraft
        var tried = false
    }

    enum Metrics {
        static let maxWidth: CGFloat = 680
        static let rowHeight: CGFloat = 48
        static let cardRadius: CGFloat = 8
        static let dialogWidth: CGFloat = 420
        static let filterWidth: CGFloat = 220
        /// Chromium's `settings-search-engines-list` `visibleEnginesSize`.
        static let visibleRows = 5
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(InternalPage.searchEngines.title).font(.system(size: 20, weight: .regular))
                Spacer(minLength: 0)
                filterField
            }
            .padding(.horizontal, 20)
            .frame(height: 56)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    engines
                    siteSearches
                    inactiveSiteSearches
                }
                .frame(maxWidth: Metrics.maxWidth)
                .padding(.vertical, 24)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay { if editing != nil { dialog } }
    }

    // MARK: Search engines

    private var engines: some View {
        card(title: "Search engines",
             detail: "You can change your default search engine here.") {
            EmptyView()
        } rows: {
            let matching = SearchEngine.allCases.filter {
                SiteSearch.matches(filter, [$0.displayName, $0.searchURL(for: "%s").absoluteString])
            }
            if matching.isEmpty { message(Self.noResults) }
            ForEach(matching, id: \.self) { engine in
                Divider().padding(.leading, 16)
                engineRow(engine)
            }
        }
    }

    private func engineRow(_ engine: SearchEngine) -> some View {
        let isDefault = store.state.searchEngine == engine
        return HStack(spacing: 12) {
            FaviconView(page: engine.searchURL(for: "q"), size: 16)
            Text(isDefault ? "\(engine.displayName) (Default)" : engine.displayName)
                .fontWeight(isDefault ? .medium : .regular)
            Spacer(minLength: 0)
            Menu {
                Button("Make default") { store.mutate { $0.searchEngine = engine } }.disabled(isDefault)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(engine.displayName)")
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("searchEngine-\(engine.rawValue)")
    }

    // MARK: Site search

    private var siteSearches: some View {
        card(title: "Site search",
             detail: "To search a specific site or part of Kite, type its shortcut in the command bar, then press Tab.") {
            Button("Add") { editing = Editing(draft: SiteSearchDraft()) }
                .accessibilityIdentifier("siteSearchAdd")
        } rows: {
            let active = store.state.siteSearches.filter(\.isActive)
            let matching = active.filter { $0.matchesFilter(filter) }
            if active.isEmpty {
                message("No sites added")
            } else if matching.isEmpty {
                message(Self.noResults)
            }
            collapsible(matching, expanded: $showsAllActive, more: "Additional sites", identifier: "siteSearchMore")
        }
    }

    // MARK: Inactive shortcuts

    /// Chromium's "Inactive shortcuts": saved shortcuts Tab doesn't enter, each with Activate.
    private var inactiveSiteSearches: some View {
        card(title: "Inactive shortcuts", detail: nil) {
            EmptyView()
        } rows: {
            let inactive = store.state.siteSearches.filter { !$0.isActive }
            let matching = inactive.filter { $0.matchesFilter(filter) }
            if inactive.isEmpty {
                message("Other saved search engines will appear here")
            } else if matching.isEmpty {
                message(Self.noResults)
            }
            collapsible(matching, expanded: $showsAllInactive, more: "Additional inactive sites",
                        identifier: "inactiveSiteSearchMore")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inactiveShortcuts")
    }

    private static let noResults = "No search results found"

    private func message(_ text: String) -> some View {
        VStack(spacing: 0) {
            Divider()
            Text(text)
                .foregroundStyle(.secondary)
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The first five rows, then an expand row ("Additional sites") over the rest, as Chromium's list.
    @ViewBuilder
    private func collapsible(_ sites: [SiteSearch], expanded: Binding<Bool>, more: String, identifier: String) -> some View {
        let shown = expanded.wrappedValue ? sites : Array(sites.prefix(Metrics.visibleRows))
        ForEach(shown) { site in
            Divider().padding(.leading, 16)
            siteRow(site)
        }
        if sites.count > Metrics.visibleRows {
            Divider().padding(.leading, 16)
            Button { expanded.wrappedValue.toggle() } label: {
                HStack {
                    Text(more)
                    Spacer(minLength: 0)
                    Image(systemName: expanded.wrappedValue ? "chevron.up" : "chevron.down")
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .frame(height: Metrics.rowHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(identifier)
        }
    }

    /// The header's filter field: it narrows every list on the page to entries whose name, shortcut
    /// or URL contains the text.
    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
            TextField("Filter sites on page", text: $filter)
                .textFieldStyle(.plain)
                .accessibilityIdentifier("searchEnginesFilter")
            if !filter.isEmpty {
                Button { filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .frame(width: Metrics.filterWidth, height: 28)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.06)))
    }

    private func siteRow(_ site: SiteSearch) -> some View {
        HStack(spacing: 12) {
            FaviconView(page: site.url(for: "q"), size: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(site.name).lineLimit(1)
                Text(site.urlTemplate).font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if site.isActive {
                Text(site.shortcut).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: 150, alignment: .leading)
            } else {
                Button("Activate") { store.mutate { $0.setSiteSearch(site.id, active: true) } }
                    .accessibilityIdentifier("siteSearchActivate-\(site.shortcut)")
            }
            Menu {
                Button("Edit") { editing = Editing(id: site.id, draft: SiteSearchDraft(site)) }
                if site.isActive {
                    Button("Deactivate") { store.mutate { $0.setSiteSearch(site.id, active: false) } }
                }
                Button("Delete") { store.mutate { $0.removeSiteSearch(site.id) } }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More actions for \(site.name)")
        }
        .padding(.horizontal, 16)
        .frame(height: Metrics.rowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("siteSearch-\(site.shortcut)")
    }

    // MARK: Dialog

    /// Chromium's "Add site search" / "Edit site search" dialog, over the dimmed page.
    @ViewBuilder
    private var dialog: some View {
        if let editing {
            let problems = editing.draft.problems(in: store.state.siteSearches, editing: editing.id)
            ZStack {
                Color.black.opacity(0.3).ignoresSafeArea()
                    .onTapGesture { self.editing = nil }
                VStack(alignment: .leading, spacing: 16) {
                    Text(editing.id == nil ? "Add site search" : "Edit site search")
                        .font(.system(size: 15, weight: .semibold))
                    field("Name", \.name, problems.first { [.emptyName].contains($0) }, id: "siteSearchName")
                    field("Shortcut", \.shortcut, problems.first {
                        if case .emptyName = $0 { return false }
                        if case .invalidURL = $0 { return false }
                        return true
                    }, id: "siteSearchShortcut")
                    field("URL with %s in place of query", \.urlTemplate, problems.first { $0 == .invalidURL }, id: "siteSearchURL")
                    HStack {
                        Spacer()
                        Button("Cancel") { self.editing = nil }
                            .keyboardShortcut(.cancelAction)
                        Button(editing.id == nil ? "Add" : "Save") { save() }
                            .keyboardShortcut(.defaultAction)
                            .disabled(!problems.isEmpty && editing.tried)
                            .accessibilityIdentifier("siteSearchSave")
                    }
                }
                .padding(20)
                .frame(width: Metrics.dialogWidth)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.25), radius: 20, y: 8)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("siteSearchDialog")
            }
        }
    }

    /// A labelled field; its problem shows once Save was tried, or as soon as the field has text.
    private func field(_ label: String, _ key: WritableKeyPath<SiteSearchDraft, String>,
                       _ problem: SiteSearchDraft.Problem?, id: String) -> some View {
        let text = editing?.draft[keyPath: key] ?? ""
        let shown = problem.flatMap { (editing?.tried == true || !text.isEmpty) ? $0 : nil }
        return VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(label, text: Binding(
                get: { editing?.draft[keyPath: key] ?? "" },
                set: { editing?.draft[keyPath: key] = $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .accessibilityIdentifier(id)
            if let shown {
                Text(shown.message).font(.system(size: 11)).foregroundStyle(.red)
                    .accessibilityIdentifier("\(id)Problem")
            }
        }
    }

    private func save() {
        guard var editing else { return }
        var saved = false
        store.mutate { state in
            if let id = editing.id {
                saved = state.updateSiteSearch(id, editing.draft)
            } else {
                saved = state.addSiteSearch(editing.draft) != nil
            }
        }
        if saved {
            self.editing = nil
        } else {
            editing.tried = true
            self.editing = editing
        }
    }

    // MARK: Card

    private func card<Accessory: View, Rows: View>(
        title: String, detail: String?,
        @ViewBuilder accessory: () -> Accessory, @ViewBuilder rows: () -> Rows
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
                accessory()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            rows()
        }
        .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.08)))
    }
}

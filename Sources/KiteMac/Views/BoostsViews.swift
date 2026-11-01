import AppKit
import KiteCore
import SwiftUI

// Boosts, Arc's per-site CSS and JavaScript. Arc edits one in its own window
// (BoostsEditor.BoostsEditorWindowController) and lists them on its Library's Boosts page
// (Window › View Boosts…), `BoostsListView` here, shown by `LibraryView`.

// MARK: - Alerts

@MainActor
enum BoostAlerts {
    /// Arc's "Delete this Boost?" / "Deleting a Boost can't be undone." confirmation.
    static func confirmDelete(_ boost: Boost, in window: NSWindow?, completion: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = "Delete this Boost?"
        alert.informativeText = "Deleting a Boost can’t be undone."
        alert.addButton(withTitle: "Delete").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        run(alert, in: window) { completion($0 == .alertFirstButtonReturn) }
    }

    /// Arc's "Rename this Boost", with the name in Arc's own dialog sheet (`ArcDialog`) rather
    /// than an NSAlert.
    static func rename(_ boost: Boost, in window: NSWindow?, completion: @escaping (String) -> Void) {
        guard let window else { return NSSound.beep() }
        ArcDialog.present(
            on: window,
            title: "Rename this Boost",
            field: .init(text: boost.name, placeholder: ""),
            actions: [.init(title: "Cancel", role: .cancel), .init(title: "Done", role: .primary)]
        ) { action, text in
            if action == 1 { completion(text) }
        }
    }

    private static func run(_ alert: NSAlert, in window: NSWindow?, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        if let window {
            alert.beginSheetModal(for: window, completionHandler: completion)
        } else {
            completion(alert.runModal())
        }
    }
}

// MARK: - Editor

/// One Boost's editor window. Opening a Boost that already has one brings it forward.
@MainActor
final class BoostEditorWindowController: NSWindowController, NSWindowDelegate {
    private static var open: [UUID: BoostEditorWindowController] = [:]
    let boostID: UUID

    /// `refresh` reloads the page the Boost was opened from (the editor's "Refresh this Page");
    /// `browser` is its window, where the Zap tool opens the picker.
    static func show(_ boostID: UUID, refresh: (() -> Void)?, browser: BrowserWindowController? = nil) {
        if let existing = open[boostID] {
            if let browser { existing.zapTool.browser = browser }
            existing.present()
            return
        }
        let controller = BoostEditorWindowController(boostID: boostID, refresh: refresh, browser: browser)
        open[boostID] = controller
        controller.present()
    }

    /// A test run (KITE_DIAGNOSTICS=1 on a throwaway profile) opens it behind other windows, like
    /// its browser windows.
    private func present() {
        if UIDiagnostics.enabledByEnvironment { window?.orderBack(nil) } else { showWindow(nil) }
    }

    /// Closes the Boost's editor, if open (it was deleted).
    static func close(_ boostID: UUID) {
        open[boostID]?.close()
    }

    private let zapTool: BoostZapTool

    private init(boostID: UUID, refresh: (() -> Void)?, browser: BrowserWindowController?) {
        self.boostID = boostID
        zapTool = BoostZapTool(boostID: boostID, browser: browser)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Boost"
        window.minSize = NSSize(width: 420, height: 520)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("BoostEditor")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.delegate = self
        window.contentView = NSHostingView(rootView: BoostEditorView(
            boostID: boostID,
            refresh: refresh,
            zapTool: zapTool,
            delete: { [weak self] in self?.confirmDelete() },
            rename: { [weak self] in self?.rename() }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowWillClose(_ notification: Notification) {
        Self.open[boostID] = nil
        zapTool.close()
    }

    private func confirmDelete() {
        guard let boost = BoostsModel.shared.library.boost(boostID) else { return }
        BoostAlerts.confirmDelete(boost, in: window) { [weak self] delete in
            guard delete, let self else { return }
            BoostsModel.shared.delete(self.boostID)
            self.close()
        }
    }

    private func rename() {
        guard let boost = BoostsModel.shared.library.boost(boostID) else { return }
        BoostAlerts.rename(boost, in: window) { BoostsModel.shared.rename(boost.id, to: $0) }
    }
}

/// The editor's Zap and Pick Selector tools (Arc's selector picker, in its zap and copy selector
/// modes): open or close the picker over the page in the browser window the editor was opened
/// from. Opened from View Boosts…, it has no page.
@MainActor
final class BoostZapTool: ObservableObject {
    let boostID: UUID
    weak var browser: BrowserWindowController? {
        didSet { update() }
    }
    /// The open picker's mode in that window, nil when it's closed.
    @Published private(set) var mode: ZapPicker.Mode?
    var isPicking: Bool { mode != nil }
    private var observer: NSObjectProtocol?

    init(boostID: UUID, browser: BrowserWindowController?) {
        self.boostID = boostID
        self.browser = browser
        observer = NotificationCenter.default.addObserver(forName: .kiteZapPickerChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        update()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// The tools work on a page, and only while Boosts are on (Settings › Advanced).
    var isAvailable: Bool { browser != nil && BoostsModel.shared.isOn }

    /// Opens the picker in `mode`, or closes it when it's already open in that mode. Arc's Pick
    /// Selector and Zap buttons each read "Hide Selector Picker" only while their own mode is open.
    func toggle(_ mode: ZapPicker.Mode = .zap) {
        guard let browser else { return NSSound.beep() }
        let open = browser.zapPickerMode
        browser.hideZapPicker()
        if open != mode { browser.showZapPicker(boostID: boostID, mode: mode) }
        update()
    }

    /// Closes the picker if it's open.
    func close() {
        if isPicking { browser?.hideZapPicker() }
        update()
    }

    private func update() {
        mode = browser?.zapPickerMode
    }
}

/// Arc's Boost editor: the simple controls (colours, font, text size and case) over its code
/// input panel, CSS and JavaScript tabs over one editor.
struct BoostEditorView: View {
    enum CodeType: String, CaseIterable, Identifiable {
        case css = "CSS"
        case js = "JS"
        var id: String { rawValue }
    }

    let boostID: UUID
    let refresh: (() -> Void)?
    @ObservedObject var zapTool: BoostZapTool
    let delete: () -> Void
    let rename: () -> Void
    @State private var codeType: CodeType = .css
    /// The editor's own copies, saved on every change: a binding straight to the model lags
    /// fast typing and the text view jumps back to an older value.
    @State private var css: String
    @State private var js: String
    /// The Boost before each Shuffle or Reset all Edits, newest last, for Arc's Undo. Kept while
    /// the editor is open.
    @State private var undoStack: [Boost] = []
    private var model: BoostsModel { BoostsModel.shared }

    init(
        boostID: UUID, refresh: (() -> Void)?, zapTool: BoostZapTool,
        delete: @escaping () -> Void, rename: @escaping () -> Void
    ) {
        self.boostID = boostID
        self.refresh = refresh
        self.zapTool = zapTool
        self.delete = delete
        self.rename = rename
        let boost = BoostsModel.shared.library.boost(boostID)
        _css = State(initialValue: boost?.css ?? "")
        _js = State(initialValue: boost?.js ?? "")
    }

    var body: some View {
        if let boost = model.library.boost(boostID) {
            VStack(spacing: 0) {
                header(boost)
                Divider()
                BoostStyleControls(boostID: boostID)
                Divider()
                editor(boost)
                if codeType == .js, !js.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   !BoostsModel.isValidJS(BoostScript.wrapped(js)) {
                    Text("This JavaScript has a syntax error, so it won’t run.")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("boostSyntaxError")
                }
            }
            .navigationTitle(boost.name)
            .task { await runTestMenuSteps() }
        } else {
            Text("This Boost was deleted.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(_ boost: Boost) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(boost.name).font(.headline).lineLimit(1)
                Text(boost.domain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Picker("Code", selection: $codeType) {
                ForEach(CodeType.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 100)
            .accessibilityIdentifier("boostCodeType")
            if zapTool.isAvailable {
                // Arc's code toolbar: "Pick Selector", "Hide Selector Picker" while it's open in
                // copy selector mode (arc.s 0x1012b19b4). Its icon is a guess (no asset in Arc).
                let picking = zapTool.mode == .copySelector
                Button(action: { zapTool.toggle(.copySelector) }) {
                    Image(systemName: picking ? "cursorarrow.rays" : "cursorarrow")
                }
                .buttonStyle(.borderless)
                .help(picking ? "Hide Selector Picker" : "Pick Selector")
                .accessibilityLabel(picking ? "Hide Selector Picker" : "Pick Selector")
                .accessibilityIdentifier("boostPickSelector")
                // Arc's Zap tool; its icon isn't in Arc's assets (an SF Symbol is a guess).
                let zapping = zapTool.mode == .zap
                Button(action: { zapTool.toggle(.zap) }) {
                    Image(systemName: zapping ? "bolt.fill" : "bolt")
                }
                .buttonStyle(.borderless)
                .help(zapping ? "Hide Selector Picker" : "Zap")
                .accessibilityLabel(zapping ? "Hide Selector Picker" : "Zap")
                .accessibilityIdentifier("boostZap")
            }
            if let refresh {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh this Page")
                    .accessibilityIdentifier("boostRefresh")
            }
            if !undoStack.isEmpty {
                // Arc's header "Undo" (arrow.counterclockwise, arc.s 0x1012b70a8).
                Button(action: undo) { Image(systemName: "arrow.counterclockwise") }
                    .buttonStyle(.borderless)
                    .help("Undo")
                    .accessibilityLabel("Undo")
                    .accessibilityIdentifier("boostUndo")
            }
            // Arc's header menu, in its order (arc.s 0x1012b7164–0x1012b7590). Report Boost… is
            // left out: it reports to Arc's server.
            Menu {
                Button("Rename this Boost…", action: rename)
                Button("Shuffle", action: shuffle)
                Button("Delete this Boost", action: delete)
                Button("Reset all Edits", action: resetAllEdits)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
            .accessibilityLabel("Boost menu")
            .accessibilityIdentifier("boostMenu")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// A test run (KITE_DIAGNOSTICS=1) can press the menu's items without opening the menu, which
    /// would show over other apps: KITE_TEST_BOOST_MENU is a comma-separated list of shuffle,
    /// reset and undo, done 3 s apart once the editor opens.
    private func runTestMenuSteps() async {
        guard UIDiagnostics.enabledByEnvironment,
              let steps = ProcessInfo.processInfo.environment["KITE_TEST_BOOST_MENU"]?.split(separator: ",") else { return }
        for step in steps {
            try? await Task.sleep(for: .seconds(3))
            switch step {
            case "shuffle": shuffle()
            case "reset": resetAllEdits()
            case "undo": undo()
            default: break
            }
        }
    }

    /// Arc's Shuffle: random colours, font, text size and case (`BoostEdits.shuffled`).
    private func shuffle() {
        guard let boost = model.library.boost(boostID) else { return }
        undoStack.append(boost)
        model.update(boostID) { $0 = BoostEdits.shuffled($0) }
    }

    /// Arc's Reset all Edits: the Boost starts over empty; Undo brings it back.
    private func resetAllEdits() {
        guard let boost = model.library.boost(boostID) else { return }
        undoStack.append(boost)
        model.update(boostID) { $0 = BoostEdits.reset($0) }
        css = ""
        js = ""
    }

    /// Puts back the Boost's data from before the last Shuffle or Reset all Edits (its name and
    /// on/off switch as they are now).
    private func undo() {
        guard let before = undoStack.popLast() else { return }
        model.update(boostID) { boost in
            boost.css = before.css
            boost.js = before.js
            boost.zaps = before.zaps
            boost.fontFamily = before.fontFamily
            boost.textCase = before.textCase
            boost.textZoom = before.textZoom
            boost.colors = before.colors
        }
        css = before.css
        js = before.js
    }

    private func editor(_ boost: Boost) -> some View {
        ZStack(alignment: .topLeading) {
            CodeTextView(text: codeType == .css ? $css : $js, focusToken: codeType.rawValue)
                .accessibilityIdentifier(codeType == .css ? "boostCSS" : "boostJS")
                .onChange(of: css) { _, value in model.update(boostID) { $0.css = value } }
                .onChange(of: js) { _, value in model.update(boostID) { $0.js = value } }
            if codeType == .js, js.isEmpty {
                // Arc's JavaScript placeholder. A CSS one isn't in its binary's strings.
                Text("your javascript here")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .allowsHitTesting(false)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A plain-text code editor: monospaced, with smart quotes, dashes and other substitutions off
/// (SwiftUI's TextEditor turns ' into ‘ ’, which breaks CSS and JavaScript). It takes focus when
/// it appears and whenever `focusToken` changes (switching between CSS and JS).
struct CodeTextView: NSViewRepresentable {
    @Binding var text: String
    var focusToken: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        let textView = scroll.documentView as! NSTextView
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.delegate = context.coordinator
        textView.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text { textView.string = text }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var focusToken: String?
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            text.wrappedValue = textView.string
        }
    }
}

// MARK: - Library page

/// Arc's Library › Boosts page (`HomeButton.BoostsPage`, BoostsContentView / BoostCell): every Boost
/// with an on/off switch (a 36 × 24 `Toggle`), click to edit (`onSelectBoost` →
/// `showBoostsEditorForURL`), Rename and Delete (`showBoostsRenameDialog`,
/// `showBoostsDeleteConfirmationDialog`), and, empty, "Nothing Boosted Yet!". Arc's empty state also links
/// to its Boost Gallery, a page on Arc's site that installs nothing into Kite, so Kite leaves it out. Sizes, colours and the header are Kite's, matching
/// its other Library pages: Arc's page was never on screen.
struct BoostsListView: View {
    /// Arc's onSelectBoost: the Boost's site with its editor.
    let open: (Boost) -> Void
    /// The window alerts attach to.
    var window: () -> NSWindow? = { nil }
    private var model: BoostsModel { BoostsModel.shared }

    enum Metrics {
        static let maxWidth: CGFloat = 960
        static let rowHeight: CGFloat = 44
        static let cardRadius: CGFloat = 8
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Boosts")
                .font(.system(size: 20, weight: .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .frame(height: 56)
            Divider()
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boostsPage")
    }

    @ViewBuilder
    private var content: some View {
        let boosts = model.library.libraryOrder
        if boosts.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(boosts) { boost in
                        BoostRow(
                            boost: boost,
                            open: { open(boost) },
                            rename: { rename(boost) },
                            delete: { delete(boost) })
                        if boost.id != boosts.last?.id {
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("boostsList")
                .background(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08)))
                .frame(maxWidth: Metrics.maxWidth)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Arc's BoostsEmptyStateView: its BoostLarge picture, "Nothing Boosted Yet!", and "Click
    /// [paintbrush] in URL bar to make your own, or grab one from the Boost Gallery." Kite has no
    /// paintbrush in its URL bar, so it names Kite's New Boost instead, and leaves out the gallery.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "paintbrush")
                .font(.system(size: 34))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)
            Text("Nothing Boosted Yet!")
                .font(.system(size: 15, weight: .semibold))
            Text("Choose \(Text("New Boost").bold()) in the command bar to make your own.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boostsEmpty")
    }

    private func rename(_ boost: Boost) {
        BoostAlerts.rename(boost, in: window()) { model.rename(boost.id, to: $0) }
    }

    private func delete(_ boost: Boost) {
        BoostAlerts.confirmDelete(boost, in: window()) { delete in
            guard delete else { return }
            BoostEditorWindowController.close(boost.id)
            model.delete(boost.id)
        }
    }
}

/// One Boost: its site's icon, name and site, Rename and Delete buttons on hover, and the on/off
/// switch, whose tooltip is Arc's Enable / Disable button title.
private struct BoostRow: View {
    let boost: Boost
    let open: () -> Void
    let rename: () -> Void
    let delete: () -> Void
    @State private var hovered = false
    private var model: BoostsModel { BoostsModel.shared }

    var body: some View {
        HStack(spacing: 12) {
            FaviconView(page: URL(string: "https://\(boost.domain)/"), size: 16)
            Text(boost.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text(boost.domain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 8)
            if hovered {
                accessory("pencil", "Rename", rename)
                accessory("trash", "Delete", delete)
            }
            Toggle("", isOn: Binding(
                get: { boost.isEnabled },
                set: { model.setEnabled(boost.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 36, height: 24)
                .help(boost.isEnabled ? "Disable" : "Enable")
                .accessibilityLabel(boost.isEnabled ? "Disable" : "Enable")
                .accessibilityIdentifier("boostToggle")
        }
        .padding(.horizontal, 16)
        .frame(height: BoostsListView.Metrics.rowHeight)
        .background(hovered ? Color.primary.opacity(0.05) : .clear)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture(perform: open)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(boost.name)
        .accessibilityIdentifier("boost-\(boost.id.uuidString.lowercased())")
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

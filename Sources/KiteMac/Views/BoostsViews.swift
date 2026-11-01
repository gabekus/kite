import AppKit
import KiteCore
import SwiftUI

// Boosts, Arc's per-site CSS and JavaScript. Arc edits one in its own window
// (BoostsEditor.BoostsEditorWindowController) and lists them on its Library's Boosts page
// (Window › View Boosts…). Kite has no Library yet, so the list opens in a window of its own;
// `BoostsListView` is self-contained so the Library can show it as a page.

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
            existing.showWindow(nil)
            return
        }
        let controller = BoostEditorWindowController(boostID: boostID, refresh: refresh, browser: browser)
        open[boostID] = controller
        controller.showWindow(nil)
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
        if zapTool.isPicking { zapTool.toggle() }
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

/// The editor's Zap tool (Arc's selector picker): opens or closes the picker over the page in
/// the browser window the editor was opened from. Opened from View Boosts…, it has no page.
@MainActor
final class BoostZapTool: ObservableObject {
    let boostID: UUID
    weak var browser: BrowserWindowController? {
        didSet { update() }
    }
    @Published private(set) var isPicking = false
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

    var isAvailable: Bool { browser != nil }

    func toggle() {
        guard let browser else { return NSSound.beep() }
        if browser.isShowingZapPicker { browser.hideZapPicker() } else { browser.showZapPicker(boostID: boostID) }
        update()
    }

    private func update() {
        isPicking = browser?.isShowingZapPicker ?? false
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
                // Arc's Zap tool; its icon isn't in Arc's assets (an SF Symbol is a guess).
                Button(action: zapTool.toggle) {
                    Image(systemName: zapTool.isPicking ? "bolt.fill" : "bolt")
                }
                .buttonStyle(.borderless)
                .help(zapTool.isPicking ? "Hide Selector Picker" : "Zap")
                .accessibilityLabel(zapTool.isPicking ? "Hide Selector Picker" : "Zap")
                .accessibilityIdentifier("boostZap")
            }
            if let refresh {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh this Page")
                    .accessibilityIdentifier("boostRefresh")
            }
            Button(action: rename) { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Rename this Boost")
                .accessibilityIdentifier("boostRename")
            Button(action: delete) { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete this Boost")
                .accessibilityIdentifier("boostDelete")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
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

// MARK: - List

/// Every Boost, newest first, with Arc's row actions: open in the editor, turn on or off,
/// rename and delete. Empty, it shows Arc's "Nothing Boosted Yet!".
struct BoostsListView: View {
    /// Opens a Boost in its editor.
    let open: (Boost) -> Void
    /// The window alerts attach to.
    var window: () -> NSWindow? = { nil }
    private var model: BoostsModel { BoostsModel.shared }

    var body: some View {
        let boosts = model.library.boosts
        if boosts.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "paintbrush")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text("Nothing Boosted Yet!").font(.headline)
                Text("Choose New Boost in the command bar on a site to make your own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("boostsEmpty")
        } else {
            List(boosts) { boost in
                row(boost)
            }
            .accessibilityIdentifier("boostsList")
        }
    }

    private func row(_ boost: Boost) -> some View {
        HStack(spacing: 10) {
            FaviconView(page: URL(string: "https://\(boost.domain)/"), size: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(boost.name).lineLimit(1)
                Text(boost.domain).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(boost.isEnabled ? "Disable" : "Enable") { model.setEnabled(boost.id, !boost.isEnabled) }
                .buttonStyle(.borderless)
            Button {
                BoostAlerts.rename(boost, in: window()) { model.rename(boost.id, to: $0) }
            } label: { Image(systemName: "pencil") }
                .buttonStyle(.borderless)
                .help("Rename")
            Button {
                BoostAlerts.confirmDelete(boost, in: window()) { delete in
                    guard delete else { return }
                    BoostEditorWindowController.close(boost.id)
                    model.delete(boost.id)
                }
            } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .help("Delete")
        }
        .padding(.vertical, 4)
        .opacity(boost.isEnabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { open(boost) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("boost-\(boost.id.uuidString.lowercased())")
    }
}

/// Window › View Boosts… until the Library exists (Arc opens Library › Boosts).
@MainActor
final class BoostsWindowController: NSWindowController {
    private static var shared: BoostsWindowController?

    static func show() {
        let controller = shared ?? BoostsWindowController()
        shared = controller
        controller.showWindow(nil)
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 420),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Boosts"
        window.minSize = NSSize(width: 320, height: 240)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("Boosts")
        if window.frame.origin == .zero { window.center() }
        super.init(window: window)
        window.contentView = NSHostingView(rootView: BoostsListView(
            open: { BoostEditorWindowController.show($0.id, refresh: nil) },
            window: { [weak window] in window }
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

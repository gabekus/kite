import AppKit
import SwiftUI

/// Arc's in-window dialog (`DialogsClient`, `Dialogs.SheetWindow` holding a SwiftUI `DialogView`),
/// which Arc uses instead of an NSAlert for Rename Tab…, Edit Pinned URL, New Folder… and the like.
/// From Arc's binary: a titled, full-size-content, non-opaque window with a transparent title bar,
/// shown with `beginSheet` on the browser window (so it slides down like any sheet), 450 pt wide
/// unless the dialog says otherwise (Edit Pinned URL: 393). See docs/arc-visual-spec.md, "Dialogs".
@MainActor
final class ArcDialog {
    struct Field {
        var text: String
        var placeholder: String
    }

    struct Action {
        enum Role { case primary, destructive, cancel }
        var title: String
        var role: Role
    }

    /// What was picked: the action's index, and the field's text (empty without a field).
    typealias Completion = (_ action: Int?, _ text: String) -> Void

    private let sheet: SheetWindow
    private weak var parent: NSWindow?
    private var completion: Completion?
    private let model: Model
    /// Holds the dialog while it's up, since callers needn't keep it.
    private var retainedWhileShown: ArcDialog?

    /// Shows the dialog as a sheet on `window`. `completion` runs once, with nil when the dialog
    /// was dismissed without a choice (`dismiss()`, or the window closing).
    @discardableResult
    static func present(
        on window: NSWindow,
        title: String,
        message: String? = nil,
        field: Field? = nil,
        actions: [Action],
        width: CGFloat = ArcDialogMetrics.defaultWidth,
        completion: @escaping Completion
    ) -> ArcDialog {
        let dialog = ArcDialog(title: title, message: message, field: field, actions: actions, width: width,
                               completion: completion)
        dialog.parent = window
        dialog.retainedWhileShown = dialog
        window.beginSheet(dialog.sheet) { _ in }
        return dialog
    }

    private init(title: String, message: String?, field: Field?, actions: [Action], width: CGFloat,
                 completion: @escaping Completion) {
        self.completion = completion
        model = Model(title: title, message: message, field: field, actions: actions)
        sheet = SheetWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: 160),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        sheet.isOpaque = false
        sheet.isReleasedWhenClosed = false
        sheet.titlebarAppearsTransparent = true
        sheet.titleVisibility = .hidden
        sheet.collectionBehavior = .fullScreenAuxiliary
        sheet.setAccessibilityTitle(title)
        model.choose = { [weak self] index in self?.finish(index) }
        let host = NSHostingController(rootView: DialogView(model: model, width: width))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        sheet.onCancel = { [weak self] in self?.finish(self?.model.cancelIndex) }
        sheet.onReturn = { [weak self] in
            guard let self, let index = model.defaultIndex else { return }
            finish(index)
        }
    }

    /// Takes the dialog down with no choice (the page that asked navigated away, say).
    func dismiss() { finish(nil) }

    private func finish(_ index: Int?) {
        guard let completion else { return }
        self.completion = nil
        let text = model.text
        if let parent { parent.endSheet(sheet) } else { sheet.orderOut(nil) }
        retainedWhileShown = nil
        completion(index, text)
    }

    @Observable
    @MainActor
    fileprivate final class Model {
        let title: String
        let message: String?
        let field: Field?
        let actions: [Action]
        var text: String
        var choose: (Int) -> Void = { _ in }

        init(title: String, message: String?, field: Field?, actions: [Action]) {
            self.title = title
            self.message = message
            self.field = field
            self.actions = actions
            text = field?.text ?? ""
        }

        var cancelIndex: Int? { actions.firstIndex { $0.role == .cancel } }
        var defaultIndex: Int? { actions.firstIndex { $0.role != .cancel } }
    }

    /// ↩ picks the default button and esc cancels, wherever focus is (the text field's editor
    /// otherwise keeps both), except while an input method is composing.
    fileprivate final class SheetWindow: NSWindow {
        var onCancel: () -> Void = {}
        var onReturn: () -> Void = {}
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { onCancel() }

        override func sendEvent(_ event: NSEvent) {
            let composing = (firstResponder as? NSTextView)?.hasMarkedText() ?? false
            if event.type == .keyDown, !composing,
               event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                switch event.keyCode {
                case 36, 76: return onReturn()
                case 53: return onCancel()
                default: break
                }
            }
            super.sendEvent(event)
        }
    }
}

/// Arc's `DialogViewBase`, `DialogTitle`, `DialogDetailLabel`, `TextInput` and
/// `DialogButtonStyleView` numbers (static analysis of Arc's binary; not yet checked against a
/// live capture).
enum ArcDialogMetrics {
    static let defaultWidth: CGFloat = 450
    static let horizontalPadding: CGFloat = 28
    static let bottomPadding: CGFloat = 28
    static let titleTopPadding: CGFloat = 27
    static let titleSize: CGFloat = 18
    static let detailSize: CGFloat = 14
    static let detailLineSpacing: CGFloat = 4
    static let stackSpacing: CGFloat = 16
    static let fieldFontSize: CGFloat = 18
    static let fieldCornerRadius: CGFloat = 5
    static let fieldPadding: CGFloat = 5
    static let fieldFocusRing: CGFloat = 3
    static let fieldBottomPadding: CGFloat = 14
    static let buttonHorizontalPadding: CGFloat = 12
    static let buttonVerticalPadding: CGFloat = 10
    static let buttonMinWidth: CGFloat = 62
    static let buttonCornerRadius: CGFloat = 13
    static let buttonSpacing: CGFloat = 8
    static let hintFontSize: CGFloat = 11
    static let hintCornerRadius: CGFloat = 4
}

private typealias M = ArcDialogMetrics

private struct DialogView: View {
    @Bindable var model: ArcDialog.Model
    let width: CGFloat
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.title)
                .font(.system(size: M.titleSize, weight: .bold))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, M.titleTopPadding)
                .accessibilityAddTraits(.isHeader)
            if let message = model.message, !message.isEmpty {
                Text(message)
                    .font(.system(size: M.detailSize))
                    .lineSpacing(M.detailLineSpacing)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }
            if let field = model.field {
                TextField("", text: $model.text, prompt: Text(field.placeholder))
                    .textFieldStyle(.plain)
                    .font(.system(size: M.fieldFontSize, weight: .medium))
                    .focused($fieldFocused)
                    .onSubmit(submit)
                    .padding(M.fieldPadding)
                    .background(
                        RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous)
                            .strokeBorder(Color.accentColor.opacity(fieldFocused ? 0.6 : 0), lineWidth: M.fieldFocusRing)
                    )
                    .padding(.top, M.stackSpacing)
                    .padding(.bottom, M.fieldBottomPadding - M.stackSpacing)
                    .accessibilityLabel(model.title)
                    .onAppear { fieldFocused = true }
            }
            HStack(spacing: M.buttonSpacing) {
                Spacer(minLength: 0)
                ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                    DialogButton(action: action, isDefault: index == model.defaultIndex) { model.choose(index) }
                }
            }
            .padding(.top, M.stackSpacing)
        }
        .padding(.horizontal, M.horizontalPadding)
        .padding(.bottom, M.bottomPadding)
        .frame(width: width, alignment: .leading)
    }

    private func submit() {
        if let index = model.defaultIndex { model.choose(index) }
    }
}

/// Arc's `DialogButtonStyleView`: a 13 pt-radius pill, the primary filled with the accent colour
/// (red when destructive), the others clear with a 1 pt outline, each with its key hint
/// (`ButtonHotkeyHint`: ↩ on the default, esc on Cancel).
private struct DialogButton: View {
    let action: ArcDialog.Action
    let isDefault: Bool
    let perform: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: perform) {
            HStack(spacing: 6) {
                Text(action.title)
                    .font(.system(size: 13, weight: .semibold))
                if let hint {
                    Text(hint)
                        .font(.system(size: M.hintFontSize, weight: .medium))
                        .padding(.vertical, 1)
                        .padding(.horizontal, 5)
                        .overlay(
                            RoundedRectangle(cornerRadius: M.hintCornerRadius, style: .continuous)
                                .strokeBorder(foreground.opacity(0.35), lineWidth: 1)
                        )
                        .opacity(0.75)
                }
            }
            .foregroundStyle(foreground)
            .padding(.horizontal, M.buttonHorizontalPadding)
            .padding(.vertical, M.buttonVerticalPadding)
            .frame(minWidth: M.buttonMinWidth)
            .background(
                RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous)
                    .fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isFilled ? 0 : (hovering ? 0.3 : 0.15)), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut)
        .accessibilityLabel(action.title)
    }

    private var isFilled: Bool { isDefault }
    private var hint: String? { isDefault ? "↩" : action.role == .cancel ? "esc" : nil }
    private var shortcut: KeyboardShortcut? {
        isDefault ? .defaultAction : action.role == .cancel ? .cancelAction : nil
    }
    private var foreground: Color { isFilled ? .white : .primary }
    private var fill: Color {
        guard isFilled else { return .clear }
        let base = action.role == .destructive ? Color.red : Color.accentColor
        return hovering ? base.opacity(0.85) : base
    }
}

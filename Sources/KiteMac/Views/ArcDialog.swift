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
/// Arc's dialog geometry and colours, measured on Arc 1.171's Rename Tab… sheet (window capture at 2×,
/// 1 Nov 2026), with the paddings that agree with `DialogViewBase` in its binary (28 outside, 10 more
/// for the title and field). Arc draws it dark whatever the appearance.
enum ArcDialogMetrics {
    static let defaultWidth: CGFloat = 450
    static let horizontalPadding: CGFloat = 28
    static let contentInset: CGFloat = 10
    static let topPadding: CGFloat = 54
    static let bottomPadding: CGFloat = 27
    static let titleSize: CGFloat = 17
    static let detailSize: CGFloat = 14
    static let detailLineSpacing: CGFloat = 4
    static let titleToField: CGFloat = 25
    static let fieldToButtons: CGFloat = 21.5
    static let fieldHeight: CGFloat = 36
    static let fieldFontSize: CGFloat = 17
    static let fieldCornerRadius: CGFloat = 5
    static let fieldTextInset: CGFloat = 10
    static let buttonHeight: CGFloat = 36
    static let buttonCornerRadius: CGFloat = 8
    static let buttonLeading: CGFloat = 13
    static let buttonTrailing: CGFloat = 12.5
    static let buttonTitleToKey: CGFloat = 9
    static let buttonFontSize: CGFloat = 15
    static let buttonSpacing: CGFloat = 8
    static let keyHeight: CGFloat = 19
    static let keyCornerRadius: CGFloat = 4
    static let keyFontSize: CGFloat = 11

    static let background = rgb(0x1E263D)
    static let fieldFill = rgb(0x494F60)
    static let fieldBorder = rgb(0x6F7380)
    static let secondaryFill = rgb(0x3E4073)
    static let secondaryBorder = rgb(0x7678B7)
    static let secondaryKey = rgb(0x606089)
    static let primaryFill = rgb(0x4155F4)
    static let primaryBorder = rgb(0x7F88F7)
    static let primaryKey = rgb(0x5969F5)
    static let destructiveFill = rgb(0xD8423A)

    private static func rgb(_ hex: Int) -> Color {
        Color(red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

private typealias M = ArcDialogMetrics

private struct DialogView: View {
    @Bindable var model: ArcDialog.Model
    let width: CGFloat
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(model.title)
                    .font(.system(size: M.titleSize, weight: .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if let message = model.message, !message.isEmpty {
                    Text(message)
                        .font(.system(size: M.detailSize))
                        .lineSpacing(M.detailLineSpacing)
                        .foregroundStyle(.white.opacity(0.7))
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                        .padding(.top, 8)
                }
                if let field = model.field {
                    TextField("", text: $model.text, prompt: Text(field.placeholder).foregroundStyle(.white.opacity(0.4)))
                        .textFieldStyle(.plain)
                        .font(.system(size: M.fieldFontSize, weight: .medium))
                        .foregroundStyle(.white)
                        .focused($fieldFocused)
                        .onSubmit(submit)
                        .padding(.horizontal, M.fieldTextInset)
                        .frame(height: M.fieldHeight)
                        .background(RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous).fill(M.fieldFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: M.fieldCornerRadius, style: .continuous)
                                .strokeBorder(M.fieldBorder, lineWidth: 1)
                        )
                        .padding(.top, M.titleToField)
                        .accessibilityLabel(model.title)
                        .onAppear { fieldFocused = true }
                }
            }
            .padding(.horizontal, M.contentInset)
            HStack(spacing: M.buttonSpacing) {
                Spacer(minLength: 0)
                ForEach(Array(model.actions.enumerated()), id: \.offset) { index, action in
                    ArcDialogButton(action.title, role: action.role, isDefault: index == model.defaultIndex) {
                        model.choose(index)
                    }
                }
            }
            .padding(.top, model.field == nil ? M.titleToField : M.fieldToButtons)
        }
        .padding(.top, M.topPadding)
        .padding(.horizontal, M.horizontalPadding)
        .padding(.bottom, M.bottomPadding)
        .frame(width: width, alignment: .leading)
        .background(M.background)
        .environment(\.colorScheme, .dark)
    }

    private func submit() {
        if let index = model.defaultIndex { model.choose(index) }
    }
}

/// Arc's dialog button (`DialogButtonStyleView`): a filled rounded rectangle with a lighter 1 pt edge,
/// its title, and its key in a chip (`ButtonHotkeyHint`): ↩ on the default button, ESC on Cancel.
/// The primary is Arc's blue (red when destructive), the others its muted indigo.
struct ArcDialogButton: View {
    let title: String
    let role: ArcDialog.Action.Role
    let isDefault: Bool
    var isEnabled = true
    let perform: () -> Void
    @State private var hovering = false

    init(_ title: String, role: ArcDialog.Action.Role, isDefault: Bool, isEnabled: Bool = true,
         perform: @escaping () -> Void) {
        self.title = title
        self.role = role
        self.isDefault = isDefault
        self.isEnabled = isEnabled
        self.perform = perform
    }

    var body: some View {
        Button(action: perform) {
            HStack(spacing: M.buttonTitleToKey) {
                Text(title)
                    .font(.system(size: M.buttonFontSize, weight: .medium))
                if let key {
                    Text(key)
                        .font(.system(size: M.keyFontSize, weight: .bold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 6)
                        .frame(height: M.keyHeight)
                        .background(RoundedRectangle(cornerRadius: M.keyCornerRadius, style: .continuous).fill(keyFill))
                        .overlay(
                            RoundedRectangle(cornerRadius: M.keyCornerRadius, style: .continuous)
                                .strokeBorder(isPrimary ? M.primaryBorder : .clear, lineWidth: 1)
                        )
                }
            }
            .foregroundStyle(.white)
            .padding(.leading, M.buttonLeading)
            .padding(.trailing, key == nil ? M.buttonLeading : M.buttonTrailing)
            .frame(height: M.buttonHeight)
            .background(RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous).fill(fill))
            .overlay(
                RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous)
                    .strokeBorder(isPrimary ? M.primaryBorder : M.secondaryBorder, lineWidth: 1)
            )
            .brightness(hovering && isEnabled ? 0.05 : 0)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(RoundedRectangle(cornerRadius: M.buttonCornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering = $0 }
        .keyboardShortcut(shortcut)
        .accessibilityLabel(title)
    }

    private var isPrimary: Bool { isDefault }
    private var key: String? { isDefault ? "↩" : role == .cancel ? "ESC" : nil }
    private var shortcut: KeyboardShortcut? {
        isDefault ? .defaultAction : role == .cancel ? .cancelAction : nil
    }
    private var fill: Color {
        guard isPrimary else { return M.secondaryFill }
        return role == .destructive ? M.destructiveFill : M.primaryFill
    }
    private var keyFill: Color { isPrimary ? M.primaryKey : M.secondaryKey }
}

import AppKit

/// A page's own dialogs (window.alert, confirm and prompt, and "Leave site?" from beforeunload) in
/// Arc's dialog sheet (`ArcDialog`) instead of an NSAlert. Arc takes them over from Chromium the
/// same way (its ADK delegate's willRunJavaScript…Panel and beforeunload panel methods). Arc's
/// wording for them isn't in its binary, so the text is Chrome's.
@MainActor
enum PageDialogs {
    enum Kind { case alert, confirm, prompt, leave, reload }

    /// Shows the dialog on `view`'s window. `completion` gets OK or Cancel and a prompt's text, once.
    /// A page that isn't in a window (a background tab) gets Cancel right away.
    @discardableResult
    static func present(
        _ kind: Kind,
        message: String,
        defaultText: String = "",
        origin: URL?,
        in view: NSView,
        completion: @escaping (_ ok: Bool, _ text: String?) -> Void
    ) -> ArcDialog? {
        guard let window = view.window else {
            completion(kind == .alert, nil)
            return nil
        }
        let cancel = ArcDialog.Action(title: "Cancel", role: .cancel)
        let title: String
        var body: String? = message
        var actions: [ArcDialog.Action]
        switch kind {
        case .alert:
            title = says(origin)
            actions = [.init(title: "OK", role: .primary)]
        case .confirm, .prompt:
            title = says(origin)
            actions = [cancel, .init(title: "OK", role: .primary)]
        case .leave:
            title = "Leave site?"
            body = "Changes you made may not be saved."
            actions = [cancel, .init(title: "Leave", role: .primary)]
        case .reload:
            title = "Reload site?"
            body = "Changes you made may not be saved."
            actions = [cancel, .init(title: "Reload", role: .primary)]
        }
        let field = kind == .prompt ? ArcDialog.Field(text: defaultText, placeholder: "") : nil
        return ArcDialog.present(on: window, title: title, message: body, field: field, actions: actions) { action, text in
            let ok = action.map { actions[$0].role != .cancel } ?? false
            completion(ok, kind == .prompt && ok ? text : nil)
        }
    }

    /// Chrome's "example.com says" (IDS_JAVASCRIPT_MESSAGEBOX_TITLE); "This page says" without a host.
    private static func says(_ origin: URL?) -> String {
        guard let host = origin?.host(), !host.isEmpty else { return "This page says" }
        return "\(host) says"
    }
}

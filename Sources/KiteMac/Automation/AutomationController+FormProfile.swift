import AppKit
import KiteCore

// form_profile: the user's ordinary form details in one place (`FormProfile`), so Claude fills forms from them and
// never from an old email. A change Claude asks for waits for the user's Allow in Kite.

extension AutomationController {
    var formProfileURL: URL { FormProfile.fileURL(supportDirectory: supportDirectory) }

    func formProfile(_ request: FormProfile.Request) async throws -> ToolOutput {
        let profile = FormProfile.load(from: formProfileURL)
        switch request {
        case .get:
            return .text(profile.report)
        case let .check(shown, label):
            return .text(profile.check(shown, against: label))
        case .set(let change):
            guard await allowProfileChange(change) else {
                throw AutomationError(.denied, "The user didn't allow that change to their form details. Ask them in chat what's right.")
            }
            let next = profile.merging(change, confirmed: Date())
            do { try next.save(to: formProfileURL) } catch {
                throw AutomationError(.failed, "Kite couldn't save the form details: \(error.localizedDescription)")
            }
            return .text("Saved. " + next.report)
        }
    }

    /// The user allows (or doesn't) a change to their form details, on a sheet over the window. No answer in two
    /// minutes is a no. A test-safe run shows nothing: it allows only with KITE_TEST_ALLOW_FORM_PROFILE=1.
    private func allowProfileChange(_ change: FormProfile.Change) async -> Bool {
        if WindowPresenter.testSafe {
            NSLog("Kite: diagnostics: form_profile would ask to save:\n%@", change.summary)
            return ProcessInfo.processInfo.environment["KITE_TEST_ALLOW_FORM_PROFILE"] == "1"
        }
        guard let window = host?.window else { return false }
        WindowPresenter.show(window, activate: true)
        let alert = NSAlert()
        alert.messageText = "Save these as your form details?"
        alert.informativeText = change.summary
            + "\n\nClaude fills forms from these. Only allow it if they're right (check the address against your own records)."
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Save")
        let timeout = DispatchWorkItem { [weak window] in window?.endSheet(alert.window, returnCode: .alertFirstButtonReturn) }
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.confirmationWait, execute: timeout)
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        timeout.cancel()
        return response == .alertSecondButtonReturn
    }
}

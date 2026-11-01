// Entry point for Kite's Chromium helper processes (renderer, GPU, network, ...).
// The same binary is copied into each "Kite Helper (…).app" bundle.

#include <unistd.h>

#include "include/cef_app.h"
#include "include/cef_render_process_handler.h"
#include "include/cef_sandbox_mac.h"
#include "include/wrapper/cef_library_loader.h"

namespace {

// Tells the browser process which renderer hosts each tab's main frame, for the Task
// Manager: CEF has no browser-side accessor for a browser's render process id. Sent again
// whenever a main frame gets a new script context, so a navigation that moves the tab to
// another renderer updates it. The name is shared with KCBrowser.mm.
const char kRendererPIDMessage[] = "kite.rendererPID";

class KiteHelperApp : public CefApp, public CefRenderProcessHandler {
 public:
    CefRefPtr<CefRenderProcessHandler> GetRenderProcessHandler() override { return this; }

    void OnContextCreated(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          CefRefPtr<CefV8Context> context) override {
        if (!frame->IsMain()) return;
        CefRefPtr<CefProcessMessage> message = CefProcessMessage::Create(kRendererPIDMessage);
        message->GetArgumentList()->SetInt(0, static_cast<int>(getpid()));
        frame->SendProcessMessage(PID_BROWSER, message);
    }

 private:
    IMPLEMENT_REFCOUNTING(KiteHelperApp);
};

}  // namespace

int main(int argc, char* argv[]) {
    // Enter the Chromium sandbox before the framework loads. The sandbox
    // library ships inside the framework (Libraries/libcef_sandbox.dylib).
    CefScopedSandboxContext sandboxContext;
    if (!sandboxContext.Initialize(argc, argv)) return 1;

    CefScopedLibraryLoader libraryLoader;
    if (!libraryLoader.LoadInHelper()) return 1;
    CefMainArgs mainArgs(argc, argv);
    CefRefPtr<KiteHelperApp> app = new KiteHelperApp();
    return CefExecuteProcess(mainArgs, app, nullptr);
}

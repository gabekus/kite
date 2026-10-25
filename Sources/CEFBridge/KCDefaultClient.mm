// Browsers Chromium creates on its own, outside Kite's tabs: an extension's welcome
// page after install, chrome.windows.create, and the new tab page such a window
// starts with. CEF gives them GetDefaultClient()'s client and a Chrome-style window.
// Kite never shows those windows (KCExtensionWindows.mm keeps them off screen): this
// client cancels each navigation, asks Kite to open the URL as a background tab, and
// closes the browser, which closes its window.

#import "KCInternal.h"

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_client.h"

NSString* const KCRuntimeOpenURLNotification = @"KCRuntimeOpenURLNotification";

namespace {

int gLiveBrowsers = 0;

class DefaultClient : public CefClient, public CefLifeSpanHandler, public CefRequestHandler {
   public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                       const CefString& target_url, const CefString& target_frame_name,
                       cef_window_open_disposition_t target_disposition, bool user_gesture,
                       const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) override {
        OpenInKite(target_url);
        return true;
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        gLiveBrowsers++;
        KCRegisterBrowser(browser);
    }

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                        bool user_gesture, bool is_redirect) override {
        if (!frame->IsMain()) return false;
        // Chrome's own pages (the new tab page) aren't worth a tab; the rest are.
        std::string url = request->GetURL().ToString();
        if (url.rfind("chrome://", 0) != 0 && url.rfind("about:", 0) != 0) OpenInKite(request->GetURL());
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        dispatch_async(dispatch_get_main_queue(), ^{
            host->CloseBrowser(true);
        });
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        gLiveBrowsers--;
        KCUnregisterBrowser(browser);
    }

   private:
    static void OpenInKite(const CefString& url) {
        NSURL* target = [NSURL URLWithString:[NSString stringWithUTF8String:url.ToString().c_str()]];
        if (!target) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSNotificationCenter.defaultCenter postNotificationName:KCRuntimeOpenURLNotification
                                                              object:nil
                                                            userInfo:@{@"url": target}];
        });
    }

    IMPLEMENT_REFCOUNTING(DefaultClient);
};

class App : public CefApp, public CefBrowserProcessHandler {
   public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    CefRefPtr<CefClient> GetDefaultClient() override {
        if (!client_) client_ = new DefaultClient();
        return client_;
    }

   private:
    CefRefPtr<DefaultClient> client_;
    IMPLEMENT_REFCOUNTING(App);
};

}  // namespace

CefRefPtr<CefApp> KCMakeApp() {
    return new App();
}

bool KCHasChromiumCreatedBrowsers() {
    return gLiveBrowsers > 0;
}

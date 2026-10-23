// SPIKE: browsers Chromium creates itself, e.g. an extension's chrome.tabs.create
// when no Chrome-style window exists. CEF gives them GetDefaultClient()'s client;
// this one cancels the navigation, closes the Chrome-style window and posts
// KCRuntimeOpenURLNotification so Kite opens the URL as one of its own tabs.

#import "CEFBridge.h"
#import "KCInternal.h"

#include "include/cef_app.h"
#include "include/cef_browser_process_handler.h"
#include "include/cef_client.h"

NSString* const KCRuntimeOpenURLNotification = @"KCRuntimeOpenURLNotification";

namespace {

void PostOpenURL(const CefString& url) {
    NSURL* target = [NSURL URLWithString:[NSString stringWithUTF8String:url.ToString().c_str()]];
    if (!target) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:KCRuntimeOpenURLNotification
                                                          object:nil
                                                        userInfo:@{@"url": target}];
    });
}

class KCDefaultClient : public CefClient, public CefLifeSpanHandler, public CefRequestHandler {
   public:
    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int popup_id,
                       const CefString& target_url, const CefString& target_frame_name,
                       cef_window_open_disposition_t target_disposition, bool user_gesture,
                       const CefPopupFeatures& popupFeatures, CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client, CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info, bool* no_javascript_access) override {
        NSLog(@"KiteSpike: default client OnBeforePopup %s", target_url.ToString().c_str());
        PostOpenURL(target_url);
        return true;
    }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        NSView* view = (__bridge NSView*)host->GetWindowHandle();
        NSLog(@"KiteSpike: default client OnAfterCreated id=%d style=%d url=%s window=%@ %@ visible=%d",
              browser->GetIdentifier(), (int)host->GetRuntimeStyle(),
              browser->GetMainFrame()->GetURL().ToString().c_str(), view.window.className,
              NSStringFromRect(view.window.frame), view.window.isVisible);
    }

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                        bool user_gesture, bool is_redirect) override {
        if (!frame->IsMain()) return false;
        CefString url = request->GetURL();
        CefRefPtr<CefBrowserHost> host = browser->GetHost();
        NSView* view = (__bridge NSView*)host->GetWindowHandle();
        NSLog(@"KiteSpike: default client OnBeforeBrowse id=%d %s window visible=%d", browser->GetIdentifier(),
              url.ToString().c_str(), view.window.isVisible);
        // Chrome's own pages (the new tab page the window starts with) stay put.
        if (url.ToString().rfind("chrome://", 0) == 0) return false;
        PostOpenURL(url);
        [view.window orderOut:nil];
        dispatch_async(dispatch_get_main_queue(), ^{
            host->CloseBrowser(true);
        });
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        NSLog(@"KiteSpike: default client OnBeforeClose id=%d", browser->GetIdentifier());
    }

   private:
    IMPLEMENT_REFCOUNTING(KCDefaultClient);
};

class KCApp : public CefApp, public CefBrowserProcessHandler {
   public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    CefRefPtr<CefClient> GetDefaultClient() override {
        NSLog(@"KiteSpike: GetDefaultClient");
        if (!client_) client_ = new KCDefaultClient();
        return client_;
    }

   private:
    CefRefPtr<KCDefaultClient> client_;
    IMPLEMENT_REFCOUNTING(KCApp);
};

}  // namespace

CefRefPtr<CefApp> KCMakeApp() {
    return new KCApp();
}

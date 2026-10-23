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

// The hidden Chrome-style window extensions' chrome.tabs.create targets: Kite's tabs
// are Alloy style, so without it Chromium answers "No current window".
int gAnchorID = 0;
bool gAnchorPending = false;
NSSet<NSWindow*>* gWindowsBeforeAnchor;

// Chrome creates the browser window after OnAfterCreated, so watch for it.
void HideAnchorWindow(int attempt) {
    for (NSWindow* window in NSApp.windows) {
        if ([gWindowsBeforeAnchor containsObject:window] || NSWidth(window.frame) < 100) continue;
        if (![NSStringFromClass(window.class) containsString:@"NativeWidgetMacNSWindow"]) continue;
        NSLog(@"KiteSpike: hid extension anchor window \"%@\" %@ visible=%d after %d checks", window.title,
              NSStringFromRect(window.frame), window.isVisible, attempt);
        window.alphaValue = 0;
        window.ignoresMouseEvents = YES;
        [window orderOut:nil];
        return;
    }
    if (attempt >= 200) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        HideAnchorWindow(attempt + 1);
    });
}

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
        KCRegisterBrowser(browser);
        if (gAnchorPending) {
            gAnchorPending = false;
            gAnchorID = browser->GetIdentifier();
            HideAnchorWindow(0);
        }
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
        if (browser->GetIdentifier() == gAnchorID || url.ToString().rfind("about:blank", 0) == 0) return false;
        PostOpenURL(url);
        dispatch_async(dispatch_get_main_queue(), ^{
            host->CloseBrowser(true);
        });
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        NSLog(@"KiteSpike: default client OnBeforeClose id=%d", browser->GetIdentifier());
        if (browser->GetIdentifier() == gAnchorID) gAnchorID = 0;
        KCUnregisterBrowser(browser);
    }

   private:
    IMPLEMENT_REFCOUNTING(KCDefaultClient);
};

CefRefPtr<KCDefaultClient> DefaultClient() {
    static CefRefPtr<KCDefaultClient> client = new KCDefaultClient();
    return client;
}

class KCApp : public CefApp, public CefBrowserProcessHandler {
   public:
    CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }

    CefRefPtr<CefClient> GetDefaultClient() override {
        NSLog(@"KiteSpike: GetDefaultClient");
        return DefaultClient();
    }

    void OnContextInitialized() override {
        // Opt-in: hiding the anchor window is not reliable yet (see HideAnchorWindow).
        if (!NSProcessInfo.processInfo.environment[@"KITE_SPIKE_ANCHOR"]) return;
        CefWindowInfo windowInfo;
        windowInfo.runtime_style = CEF_RUNTIME_STYLE_CHROME;
        windowInfo.bounds = CefRect(-20000, -20000, 400, 300);
        gWindowsBeforeAnchor = [NSSet setWithArray:NSApp.windows];
        gAnchorPending = true;
        CefBrowserHost::CreateBrowser(windowInfo, DefaultClient(), "about:blank", CefBrowserSettings(), nullptr, nullptr);
    }

   private:
    IMPLEMENT_REFCOUNTING(KCApp);
};

}  // namespace

CefRefPtr<CefApp> KCMakeApp() {
    return new KCApp();
}

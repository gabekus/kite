#import "CEFBridge.h"
#import "KCInternal.h"

#include <cmath>
#include <map>

#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_parser.h"

@interface KCBrowser ()
- (instancetype)initPopupWithDelegate:(id<KCBrowserDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)browserDidClose;
- (void)deliverDevToolsResult:(int)messageID success:(bool)success data:(NSData *)data;
- (void)willNavigateMainFrame:(CefRefPtr<CefRequest>)request;
- (void)mainFrameDidStartLoading;
- (NSMutableArray<NSString *> *)documentScriptIdentifiers;
- (void)addDocumentScript:(NSString *)script navigation:(NSUInteger)navigation completion:(nullable void (^)(void))completion;
@property (nonatomic, readwrite) BOOL isLoading;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@end

namespace {

NSString* ToNSString(const CefString& string) {
    return [NSString stringWithUTF8String:string.ToString().c_str()] ?: @"";
}

NSURL* ToNSURL(const CefString& string) {
    if (string.empty()) return nil;
    return [NSURL URLWithString:ToNSString(string)];
}

NSURL* UniqueDownloadURL(NSString* name) {
    NSURL* directory = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    NSString* base = name.stringByDeletingPathExtension;
    NSString* extension = name.pathExtension;
    NSURL* candidate = [directory URLByAppendingPathComponent:name];
    for (int n = 2; [NSFileManager.defaultManager fileExistsAtPath:candidate.path]; n++) {
        NSString* numbered = extension.length ? [NSString stringWithFormat:@"%@ %d.%@", base, n, extension]
                                              : [NSString stringWithFormat:@"%@ %d", base, n];
        candidate = [directory URLByAppendingPathComponent:numbered];
    }
    return candidate;
}

/// Converts Foundation objects to CEF values for DevTools method params.
CefRefPtr<CefValue> ToCefValue(id object) {
    CefRefPtr<CefValue> value = CefValue::Create();
    if ([object isKindOfClass:NSString.class]) {
        value->SetString([(NSString*)object UTF8String]);
    } else if ([object isKindOfClass:NSNumber.class]) {
        NSNumber* number = object;
        if (strcmp(number.objCType, @encode(BOOL)) == 0 || number == (id)kCFBooleanTrue || number == (id)kCFBooleanFalse) {
            value->SetBool(number.boolValue);
        } else if (strcmp(number.objCType, @encode(double)) == 0 || strcmp(number.objCType, @encode(float)) == 0) {
            value->SetDouble(number.doubleValue);
        } else {
            value->SetInt(number.intValue);
        }
    } else if ([object isKindOfClass:NSDictionary.class]) {
        CefRefPtr<CefDictionaryValue> dictionary = CefDictionaryValue::Create();
        [(NSDictionary*)object enumerateKeysAndObjectsUsingBlock:^(NSString* key, id item, BOOL*) {
            dictionary->SetValue(key.UTF8String, ToCefValue(item));
        }];
        value->SetDictionary(dictionary);
    } else if ([object isKindOfClass:NSArray.class]) {
        CefRefPtr<CefListValue> list = CefListValue::Create();
        NSArray* array = object;
        for (NSUInteger i = 0; i < array.count; i++) list->SetValue(i, ToCefValue(array[i]));
        value->SetList(list);
    } else {
        value->SetNull();
    }
    return value;
}

/// Per-browser CEF client: forwards Chromium callbacks to the Objective-C KCBrowser.
class KCClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefDisplayHandler,
                 public CefLoadHandler,
                 public CefRequestHandler,
                 public CefDownloadHandler,
                 public CefDevToolsMessageObserver {
 public:
    explicit KCClient(KCBrowser* owner) : owner_(owner), adblock_(KCAdblockRequestHandler(owner)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }

    // CefLifeSpanHandler

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        KCRegisterBrowser(browser);
        devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
        [owner_ attachBrowser:browser];
    }

    bool OnBeforePopup(CefRefPtr<CefBrowser> browser,
                       CefRefPtr<CefFrame> frame,
                       int popup_id,
                       const CefString& target_url,
                       const CefString& target_frame_name,
                       cef_window_open_disposition_t target_disposition,
                       bool user_gesture,
                       const CefPopupFeatures& popupFeatures,
                       CefWindowInfo& windowInfo,
                       CefRefPtr<CefClient>& client,
                       CefBrowserSettings& settings,
                       CefRefPtr<CefDictionaryValue>& extra_info,
                       bool* no_javascript_access) override {
        KCBrowser* owner = owner_;
        id<KCBrowserDelegate> delegate = owner.delegate;
        if (!delegate) return true;
        // Host the popup in a Kite tab instead of a separate native window.
        KCBrowser* popup = [[KCBrowser alloc] initPopupWithDelegate:delegate];
        NSRect bounds = owner.view.bounds;
        windowInfo.SetAsChild((__bridge CefWindowHandle)popup.view,
                              CefRect(0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)));
        client = new KCClient(popup);
        [delegate browser:owner didCreatePopup:popup url:ToNSURL(target_url)];
        return false;
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        // Returning false would send performClose: to the whole window. Tear down
        // just this tab's view instead, which completes the close.
        NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
        dispatch_async(dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
        });
        return true;
    }

    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
        devtools_registration_ = nullptr;
        [owner_ browserDidClose];
        KCUnregisterBrowser(browser);
    }

    // CefDisplayHandler

    void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString& url) override {
        NSURL* address = ToNSURL(url);
        if (frame->IsMain() && address) [owner_.delegate browser:owner_ addressDidChange:address];
    }

    void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
        [owner_.delegate browser:owner_ titleDidChange:ToNSString(title)];
    }

    void OnFaviconURLChange(CefRefPtr<CefBrowser> browser, const std::vector<CefString>& icon_urls) override {
        [owner_.delegate browser:owner_ faviconDidChange:icon_urls.empty() ? nil : ToNSURL(icon_urls.front())];
    }

    void OnLoadingProgressChange(CefRefPtr<CefBrowser> browser, double progress) override {
        [owner_.delegate browser:owner_ progressDidChange:progress];
    }

    void OnMediaAccessChange(CefRefPtr<CefBrowser> browser, bool has_video_access, bool has_audio_access) override {
        [owner_.delegate browser:owner_ mediaAccessDidChange:has_video_access || has_audio_access];
    }

    // CefLoadHandler

    void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType transition_type) override {
        if (frame->IsMain()) [owner_ mainFrameDidStartLoading];
    }

    void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading, bool canGoBack, bool canGoForward) override {
        KCBrowser* owner = owner_;
        owner.isLoading = isLoading;
        owner.canGoBack = canGoBack;
        owner.canGoForward = canGoForward;
        [owner.delegate browserLoadingStateDidChange:owner];
    }

    // CefRequestHandler

    bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefRequest> request,
                        bool user_gesture,
                        bool is_redirect) override {
        if (frame->IsMain()) [owner_ willNavigateMainFrame:request];
        return false;
    }

    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> browser,
                                                                   CefRefPtr<CefFrame> frame,
                                                                   CefRefPtr<CefRequest> request,
                                                                   bool is_navigation,
                                                                   bool is_download,
                                                                   const CefString& request_initiator,
                                                                   bool& disable_default_handling) override {
        return is_download ? nullptr : adblock_;
    }

    bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefFrame> frame,
                          const CefString& target_url,
                          cef_window_open_disposition_t target_disposition,
                          bool user_gesture) override {
        bool background = target_disposition == CEF_WOD_NEW_BACKGROUND_TAB;
        bool foreground = target_disposition == CEF_WOD_NEW_FOREGROUND_TAB;
        NSURL* url = ToNSURL(target_url);
        if (!user_gesture || !(background || foreground) || !url) return false;
        [owner_.delegate browser:owner_ openURLInNewTab:url foreground:foreground];
        return true;
    }

    // CefDownloadHandler

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDownloadItem> download_item,
                          const CefString& suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        callback->Continue(UniqueDownloadURL(ToNSString(suggested_name)).path.UTF8String, false);
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefDownloadItem> download_item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        if (download_item->IsComplete()) [NSApp requestUserAttention:NSInformationalRequest];
    }

    // CefDevToolsMessageObserver

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                                const void* result, size_t result_size) override {
        NSData* data = [NSData dataWithBytes:result length:result_size];
        [owner_ deliverDevToolsResult:message_id success:success data:data];
    }

 private:
    __weak KCBrowser* owner_;
    CefRefPtr<CefRegistration> devtools_registration_;
    CefRefPtr<CefResourceRequestHandler> adblock_;
    IMPLEMENT_REFCOUNTING(KCClient);
};

}  // namespace

// MARK: - KCBrowser

@implementation KCBrowser {
    CefRefPtr<CefBrowser> _browser;
    NSURL* _pendingURL;
    BOOL _pendingFocus;
    BOOL _hidden;
    double _zoomFactor;
    BOOL _closed;
    int _nextMessageID;
    std::map<int, void (^)(NSDictionary*)>* _pendingDevTools;
    NSInteger _blockedCount;
    BOOL _blockedCountPending;
    /// Page.addScriptToEvaluateOnNewDocument identifiers to remove at the next navigation.
    NSMutableArray<NSString*>* _documentScripts;
    NSUInteger _navigationCount;
    /// The registered document-start script; reloads and same-site links reuse it.
    NSString* _documentScriptSource;
    BOOL _runScriptAtLoadStart;
}

- (instancetype)initWithURL:(NSURL*)url delegate:(id<KCBrowserDelegate>)delegate {
    if ((self = [self initPopupWithDelegate:delegate])) {
        CefWindowInfo windowInfo;
        windowInfo.SetAsChild((__bridge CefWindowHandle)_view, CefRect(0, 0, 800, 600));
        CefBrowserSettings settings;
        // Start empty and load once attached: DevTools calls (dark pages, the ad
        // blocker's document-start script) need the browser before the first navigation.
        _pendingURL = url ?: [NSURL URLWithString:@"about:blank"];
        CefBrowserHost::CreateBrowser(windowInfo, new KCClient(self), "", settings, nullptr, KCAdblockRequestContext());
    }
    return self;
}

- (instancetype)initPopupWithDelegate:(id<KCBrowserDelegate>)delegate {
    if ((self = [super init])) {
        _view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 800, 600)];
        _view.autoresizesSubviews = YES;
        _delegate = delegate;
        _zoomFactor = 1;
        _nextMessageID = 1000;
        _pendingDevTools = new std::map<int, void (^)(NSDictionary*)>();
        _documentScripts = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    delete _pendingDevTools;
}

- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    browserView.frame = _view.bounds;
    browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (_closed) {
        browser->GetHost()->CloseBrowser(true);
        return;
    }
    // Document-start scripts only run in sessions with the Page domain enabled.
    if ([_delegate respondsToSelector:@selector(browser:documentStartScriptForURL:)]) {
        [self executeDevToolsMethod:@"Page.enable" params:nil completion:nil];
    }
    if (_pendingURL) {
        NSURL* url = _pendingURL;
        _pendingURL = nil;
        // A browser that hasn't navigated has no renderer yet, so a script registered
        // now can miss the first document; it runs again at load start (the script
        // guards against running twice).
        NSString* script = [_delegate respondsToSelector:@selector(browser:documentStartScriptForURL:)]
            ? [_delegate browser:self documentStartScriptForURL:url] : nil;
        if (script.length) {
            [self addDocumentScript:script navigation:_navigationCount completion:nil];
            _runScriptAtLoadStart = YES;
        }
        [self loadURL:url];
    }
    if (_zoomFactor != 1) self.zoomFactor = _zoomFactor;
    if (_hidden) browser->GetHost()->WasHidden(true);
    if (_pendingFocus) [self focus];
}

- (void)browserDidClose {
    _browser = nullptr;
    // Not closed by us, so the page closed itself (window.close()).
    // Quitting closes every browser; that mustn't close the tabs in the saved session.
    if (!_closed && !KCRuntimeIsQuitting()) [_delegate browserDidRequestClose:self];
}

- (void)loadURL:(NSURL*)url {
    if (!_browser) {
        _pendingURL = url;
        return;
    }
    _browser->GetMainFrame()->LoadURL(url.absoluteString.UTF8String);
}

- (void)goBack { if (_browser) _browser->GoBack(); }
- (void)goForward { if (_browser) _browser->GoForward(); }
- (void)reload { if (_browser) _browser->Reload(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }

- (void)focus {
    _pendingFocus = !_browser;
    if (_browser) _browser->GetHost()->SetFocus(true);
}

- (void)setHidden:(BOOL)hidden {
    _hidden = hidden;
    if (_browser) _browser->GetHost()->WasHidden(hidden);
}

- (double)zoomFactor {
    return _zoomFactor;
}

- (void)setZoomFactor:(double)zoomFactor {
    _zoomFactor = zoomFactor;
    // Chromium zoom levels are logarithmic: each level is a 20% step.
    if (_browser) _browser->GetHost()->SetZoomLevel(std::log(zoomFactor) / std::log(1.2));
}

- (void)showDevTools {
    if (!_browser) return;
    CefWindowInfo windowInfo;
    CefBrowserSettings settings;
    _browser->GetHost()->ShowDevTools(windowInfo, nullptr, settings, CefPoint());
}

- (void)setForceDark:(BOOL)enabled {
    [self executeDevToolsMethod:@"Emulation.setAutoDarkModeOverride"
                         params:enabled ? @{@"enabled": @YES} : @{}
                     completion:nil];
}

- (void)evaluateJavaScript:(NSString*)script completion:(void (^)(id))completion {
    [self executeDevToolsMethod:@"Runtime.evaluate"
                         params:@{@"expression": script, @"returnByValue": @YES, @"awaitPromise": @YES}
                     completion:^(NSDictionary* result) {
        if (result[@"exceptionDetails"]) {
            completion(nil);
            return;
        }
        completion(result[@"result"][@"value"]);
    }];
}

- (void)executeDevToolsMethod:(NSString*)method
                       params:(NSDictionary<NSString*, id>*)params
                   completion:(void (^)(NSDictionary*))completion {
    if (!_browser) {
        if (completion) completion(nil);
        return;
    }
    int messageID = _nextMessageID++;
    if (completion) (*_pendingDevTools)[messageID] = [completion copy];
    CefRefPtr<CefDictionaryValue> cefParams = params.count ? ToCefValue(params)->GetDictionary() : nullptr;
    if (_browser->GetHost()->ExecuteDevToolsMethod(messageID, method.UTF8String, cefParams) == 0) {
        _pendingDevTools->erase(messageID);
        if (completion) completion(nil);
    }
}

- (void)deliverDevToolsResult:(int)messageID success:(bool)success data:(NSData*)data {
    auto it = _pendingDevTools->find(messageID);
    if (it == _pendingDevTools->end()) return;
    void (^completion)(NSDictionary*) = it->second;
    _pendingDevTools->erase(it);
    id json = success ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    completion([json isKindOfClass:NSDictionary.class] ? json : nil);
}

- (NSInteger)blockedCount {
    return _blockedCount;
}

- (void)noteBlockedRequest {
    _blockedCount++;
    // Pages block in bursts; tell the delegate once per run loop turn.
    if (_blockedCountPending) return;
    _blockedCountPending = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_blockedCountPending = NO;
        if ([self.delegate respondsToSelector:@selector(browser:blockedCountDidChange:)]) {
            [self.delegate browser:self blockedCountDidChange:self->_blockedCount];
        }
    });
}

- (void)mainFrameDidStartLoading {
    if (!_runScriptAtLoadStart) return;
    _runScriptAtLoadStart = NO;
    if (_documentScriptSource) [self evaluateJavaScript:_documentScriptSource completion:^(id) {}];
}

- (void)willNavigateMainFrame:(CefRefPtr<CefRequest>)request {
    NSUInteger navigation = ++_navigationCount;
    _blockedCount = 0;
    if ([_delegate respondsToSelector:@selector(browser:blockedCountDidChange:)]) {
        [_delegate browser:self blockedCountDidChange:0];
    }
    NSURL* url = ToNSURL(request->GetURL());
    NSString* script = url && [_delegate respondsToSelector:@selector(browser:documentStartScriptForURL:)]
        ? [_delegate browser:self documentStartScriptForURL:url] : nil;
    if ((script ?: @"").length == 0 && _documentScriptSource == nil) return;
    if ([script isEqualToString:_documentScriptSource]) return;

    for (NSString* identifier in _documentScripts) {
        [self executeDevToolsMethod:@"Page.removeScriptToEvaluateOnNewDocument" params:@{@"identifier": identifier} completion:nil];
    }
    [_documentScripts removeAllObjects];
    _documentScriptSource = nil;
    // Sent now, before the request starts, so it's registered by the time the new document commits.
    if (script.length) [self addDocumentScript:script navigation:navigation completion:nil];
}

- (void)addDocumentScript:(NSString*)script navigation:(NSUInteger)navigation completion:(void (^)(void))completion {
    _documentScriptSource = script;
    __weak KCBrowser* weakSelf = self;
    [self executeDevToolsMethod:@"Page.addScriptToEvaluateOnNewDocument"
                         params:@{@"source": script}
                     completion:^(NSDictionary* result) {
        NSString* identifier = result[@"identifier"];
        KCBrowser* strongSelf = weakSelf;
        if (strongSelf && [identifier isKindOfClass:NSString.class]) {
            if (strongSelf->_navigationCount == navigation) {
                [strongSelf.documentScriptIdentifiers addObject:identifier];
            } else {
                // A redirect or a quick second navigation already replaced this script.
                [strongSelf executeDevToolsMethod:@"Page.removeScriptToEvaluateOnNewDocument" params:@{@"identifier": identifier} completion:nil];
            }
        }
        if (completion) completion();
    }];
}

- (NSMutableArray<NSString*>*)documentScriptIdentifiers {
    return _documentScripts;
}

- (void)close {
    _closed = YES;
    _delegate = nil;
    if (_browser) _browser->GetHost()->CloseBrowser(true);
}

@end

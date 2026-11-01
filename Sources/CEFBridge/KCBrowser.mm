#import "CEFBridge.h"
#import "KCInternal.h"

#include <cmath>
#include <map>

#include "include/cef_client.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"

@interface KCRequestContext ()
- (instancetype)initPrivate;
- (CefRefPtr<CefRequestContext>)cefContext;
@end

@interface KCBrowser ()
- (instancetype)initPopupWithDelegate:(id<KCBrowserDelegate>)delegate NS_DESIGNATED_INITIALIZER;
- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser;
- (void)browserDidClose;
- (void)deliverDevToolsResult:(int)messageID success:(bool)success data:(NSData *)data;
- (void)willNavigateMainFrame:(CefRefPtr<CefRequest>)request;
- (void)mainFrameDidStartLoading;
- (void)prepareFirstPage:(nullable NSURL *)url;
- (NSMutableArray<NSString *> *)documentScriptIdentifiers;
- (void)addDocumentScript:(NSString *)script navigation:(NSUInteger)navigation completion:(nullable void (^)(void))completion;
- (void)deliverDevToolsEvent:(NSString *)method data:(NSData *)data;
- (BOOL)deliverSessionMessage:(NSData *)data;
@property (nonatomic, readwrite) BOOL isLoading;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@end

NSString* const KCDownloadDidUpdateNotification = @"KCDownloadDidUpdateNotification";

namespace {

NSString* ToNSString(const CefString& string) {
    return [NSString stringWithUTF8String:string.ToString().c_str()] ?: @"";
}

NSURL* ToNSURL(const CefString& string) {
    if (string.empty()) return nil;
    return [NSURL URLWithString:ToNSString(string)];
}

// Live downloads' callbacks, by Chromium's download id, so the downloads list can cancel them.
// Download callbacks run on the main (UI) thread.
std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>>& DownloadCallbacks() {
    static std::map<uint32_t, CefRefPtr<CefDownloadItemCallback>> callbacks;
    return callbacks;
}

NSURL* UniqueDownloadURL(NSString* name) {
    NSURL* directory = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    // Test runs on a throwaway profile save into their own folder, never the user's Downloads.
    NSString* testDirectory = NSProcessInfo.processInfo.environment[@"KITE_TEST_DOWNLOADS_PATH"];
    if (testDirectory.length && NSProcessInfo.processInfo.environment[@"KITE_SUPPORT_PATH"].length) {
        directory = [NSURL fileURLWithPath:testDirectory isDirectory:YES];
    }
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

/// Whether the delegate opens a clicked link in Arc's Peek card instead (it reports the link itself).
static bool AskLinkPeek(KCBrowser* owner, const CefString& target, bool shift) {
    id<KCBrowserDelegate> delegate = owner.delegate;
    NSURL* url = ToNSURL(target);
    if (!url || ![delegate respondsToSelector:@selector(browser:opensLinkInPeek:shift:)]) return false;
    return [delegate browser:owner opensLinkInPeek:url shift:shift];
}

/// Per-browser CEF client: forwards Chromium callbacks to the Objective-C KCBrowser.
class KCClient : public CefClient,
                 public CefLifeSpanHandler,
                 public CefDisplayHandler,
                 public CefLoadHandler,
                 public CefRequestHandler,
                 public CefDownloadHandler,
                 public CefFindHandler,
                 public CefKeyboardHandler,
                 public CefFocusHandler,
                 public CefDevToolsMessageObserver {
 public:
    explicit KCClient(KCBrowser* owner) : owner_(owner), adblock_(KCAdblockRequestHandler(owner)) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }

    // CefFocusHandler

    /// True cancels: the page asked for the keyboard while Kite's own UI holds it.
    bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
        return owner_.focusBlocked;
    }

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
        // A target=_blank link (or ⇧-click) the delegate opens in Arc's Peek card: no popup.
        bool linkClick = target_disposition == CEF_WOD_NEW_FOREGROUND_TAB || target_disposition == CEF_WOD_NEW_WINDOW;
        if (user_gesture && linkClick && AskLinkPeek(owner, target_url, target_disposition == CEF_WOD_NEW_WINDOW)) return true;
        // Host the popup in a Kite tab instead of a separate native window.
        KCBrowser* popup = [[KCBrowser alloc] initPopupWithDelegate:delegate];
        NSRect bounds = owner.view.bounds;
        windowInfo.SetAsChild((__bridge CefWindowHandle)popup.view,
                              CefRect(0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)));
        client = new KCClient(popup);
        [delegate browser:owner didCreatePopup:popup url:ToNSURL(target_url)];
        [popup prepareFirstPage:ToNSURL(target_url)];
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

    void OnStatusMessage(CefRefPtr<CefBrowser> browser, const CefString& value) override {
        KCBrowser* owner = owner_;
        if ([owner.delegate respondsToSelector:@selector(browser:statusMessageDidChange:)]) {
            NSString* message = ToNSString(value);
            [owner.delegate browser:owner statusMessageDidChange:message.length ? message : nil];
        }
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
        if (frame->IsMain() && user_gesture && !is_redirect &&
            (request->GetTransitionType() & TT_SOURCE_MASK) == TT_LINK &&
            AskLinkPeek(owner_, request->GetURL(), false)) {
            return true;
        }
        if (frame->IsMain()) [owner_ willNavigateMainFrame:request];
        return false;
    }

    void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser,
                                   TerminationStatus status,
                                   int error_code,
                                   const CefString& error_string) override {
        KCBrowser* owner = owner_;
        if ([owner.delegate respondsToSelector:@selector(browser:renderProcessDidTerminateWithCode:)]) {
            [owner.delegate browser:owner renderProcessDidTerminateWithCode:error_code];
        }
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
        // ⇧-click: Arc's "Open a Peek window when clicking on links with Shift held".
        if (user_gesture && target_disposition == CEF_WOD_NEW_WINDOW && AskLinkPeek(owner_, target_url, true)) return true;
        if (!user_gesture || !(background || foreground) || !url) return false;
        [owner_.delegate browser:owner_ openURLInNewTab:url foreground:foreground];
        return true;
    }

    // CefDownloadHandler

    bool OnBeforeDownload(CefRefPtr<CefBrowser> browser,
                          CefRefPtr<CefDownloadItem> download_item,
                          const CefString& suggested_name,
                          CefRefPtr<CefBeforeDownloadCallback> callback) override {
        if (IsExtensionPackage(download_item, suggested_name)) {
            // Chromium's installer picks it up from here; it never reaches Downloads.
            NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:@"KiteExtensionInstalls"];
            [NSFileManager.defaultManager createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil];
            NSString* name = [NSString stringWithFormat:@"%u-%@", download_item->GetId(),
                                                       ToNSString(suggested_name).lastPathComponent];
            callback->Continue([directory stringByAppendingPathComponent:name].UTF8String, false);
            return true;
        }
        callback->Continue(UniqueDownloadURL(ToNSString(suggested_name)).path.UTF8String, false);
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefDownloadItem> download_item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        // A store install's package isn't the user's download: no bounce, not listed.
        if (IsExtensionPackage(download_item, download_item->GetSuggestedFileName())) return;
        if (download_item->IsComplete()) [NSApp requestUserAttention:NSInformationalRequest];
        if (download_item->IsInProgress()) DownloadCallbacks()[download_item->GetId()] = callback;
        else DownloadCallbacks().erase(download_item->GetId());
        NSString* state = download_item->IsComplete() ? @"complete"
            : download_item->IsCanceled() ? @"canceled"
            : download_item->IsInterrupted() ? @"interrupted" : @"in-progress";
        [NSNotificationCenter.defaultCenter postNotificationName:KCDownloadDidUpdateNotification object:owner_ userInfo:@{
            @"id": @(download_item->GetId()),
            @"url": ToNSString(download_item->GetOriginalUrl()),
            @"path": ToNSString(download_item->GetFullPath()),
            @"state": state,
            @"receivedBytes": @(download_item->GetReceivedBytes()),
            @"totalBytes": @(download_item->GetTotalBytes()),
            @"speed": @(download_item->GetCurrentSpeed()),
        }];
    }

    bool IsExtensionPackage(CefRefPtr<CefDownloadItem> item, const CefString& suggested_name) {
        id<KCBrowserDelegate> delegate = owner_.delegate;
        if (![delegate respondsToSelector:@selector(browser:isExtensionPackageWithMIMEType:suggestedName:url:)]) return false;
        return [delegate browser:owner_
            isExtensionPackageWithMIMEType:ToNSString(item->GetMimeType())
                             suggestedName:ToNSString(suggested_name)
                                       url:ToNSURL(item->GetOriginalUrl())];
    }

    // CefFindHandler

    void OnFindResult(CefRefPtr<CefBrowser> browser, int identifier, int count, const CefRect& selectionRect,
                      int activeMatchOrdinal, bool finalUpdate) override {
        id<KCBrowserDelegate> delegate = owner_.delegate;
        if ([delegate respondsToSelector:@selector(browser:findResultCount:activeMatch:final:)]) {
            [delegate browser:owner_ findResultCount:count activeMatch:activeMatchOrdinal final:finalUpdate];
        }
    }

    // CefKeyboardHandler

    /// CEF hands every key the page didn't cancel to the main menu, including plain
    /// typing. AppKit then matches a plain E to Edit > Emoji & Symbols (fn E), so every
    /// e typed into a page opened the emoji picker. Only keys with a modifier that can
    /// make a shortcut go on to the menu, as in Chrome.
    bool OnKeyEvent(CefRefPtr<CefBrowser> browser, const CefKeyEvent& event, CefEventHandle os_event) override {
        NSEvent* ns_event = CAST_CEF_EVENT_HANDLE_TO_NSEVENT(os_event);
        if (ns_event.type != NSEventTypeKeyDown) return false;
        NSEventModifierFlags shortcutModifiers =
            NSEventModifierFlagCommand | NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagFunction;
        // true means handled, so CEF skips the menu.
        return (ns_event.modifierFlags & shortcutModifiers) == 0;
    }

    // CefDevToolsMessageObserver

    bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* message, size_t message_size) override {
        KCBrowser* owner = owner_;
        if (!owner.sessionMessageHandler) return false;
        return [owner deliverSessionMessage:[NSData dataWithBytes:message length:message_size]];
    }

    void OnDevToolsMethodResult(CefRefPtr<CefBrowser> browser, int message_id, bool success,
                                const void* result, size_t result_size) override {
        NSData* data = [NSData dataWithBytes:result length:result_size];
        [owner_ deliverDevToolsResult:message_id success:success data:data];
    }

    void OnDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method,
                         const void* params, size_t params_size) override {
        KCBrowser* owner = owner_;
        if (!owner.devToolsEventHandler && !owner.pageFeatureEventHandler) return;
        [owner deliverDevToolsEvent:ToNSString(method) data:[NSData dataWithBytes:params length:params_size]];
    }

 private:
    __weak KCBrowser* owner_;
    CefRefPtr<CefRegistration> devtools_registration_;
    CefRefPtr<CefResourceRequestHandler> adblock_;
    IMPLEMENT_REFCOUNTING(KCClient);
};

}  // namespace

// MARK: - KCRequestContext

@implementation KCRequestContext {
    CefRefPtr<CefRequestContext> _context;
}

+ (instancetype)incognitoContext {
    KCRequestContext* context = [[self alloc] initPrivate];
    // An empty cache_path makes Chromium keep this profile in memory only.
    CefRequestContextSettings settings;
    context->_context = CefRequestContext::CreateContext(settings, KCAdblockContextHandler());
    return context;
}

- (instancetype)initPrivate {
    return [super init];
}

- (CefRefPtr<CefRequestContext>)cefContext {
    return _context;
}

@end

// MARK: - KCBrowser

@implementation KCBrowser {
    CefRefPtr<CefBrowser> _browser;
    NSURL* _pendingURL;
    BOOL _pendingFocus;
    BOOL _hidden;
    double _zoomFactor;
    BOOL _audioMuted;
    BOOL _forceDark;
    BOOL _closed;
    int _nextMessageID;
    std::map<int, void (^)(NSDictionary*, NSString*)>* _pendingDevTools;
    NSInteger _blockedCount;
    BOOL _blockedCountPending;
    /// Page.addScriptToEvaluateOnNewDocument identifiers to remove when the script changes.
    NSMutableArray<NSString*>* _documentScripts;
    NSUInteger _navigationCount;
    /// The registered document-start script; reloads and same-site links reuse it.
    NSString* _documentScriptSource;
    BOOL _runScriptAtLoadStart;
    /// DevTools calls made before the browser exists; sent ahead of the first navigation.
    NSMutableArray<void (^)(void)>* _queuedDevTools;
    BOOL _attached;
}

- (instancetype)initWithURL:(NSURL*)url delegate:(id<KCBrowserDelegate>)delegate {
    return [self initWithURL:url delegate:delegate context:nil];
}

- (instancetype)initWithURL:(NSURL*)url delegate:(id<KCBrowserDelegate>)delegate context:(KCRequestContext*)context {
    if ((self = [self initPopupWithDelegate:delegate])) {
        CefWindowInfo windowInfo;
        windowInfo.SetAsChild((__bridge CefWindowHandle)_view, CefRect(0, 0, 800, 600));
        CefBrowserSettings settings;
        // Start empty and load once attached: DevTools calls (dark pages, the ad
        // blocker's document-start script) need the browser before the first navigation.
        _pendingURL = url ?: [NSURL URLWithString:@"about:blank"];
        CefBrowserHost::CreateBrowser(windowInfo, new KCClient(self), "", settings, nullptr,
                                      context ? context.cefContext : KCAdblockRequestContext());
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
        _pendingDevTools = new std::map<int, void (^)(NSDictionary*, NSString*)>();
        _documentScripts = [NSMutableArray array];
        _queuedDevTools = [NSMutableArray array];
    }
    return self;
}

- (void)dealloc {
    delete _pendingDevTools;
}

- (void)attachBrowser:(CefRefPtr<CefBrowser>)browser {
    _browser = browser;
    _attached = YES;
    NSArray<void (^)(void)>* queued = [_queuedDevTools copy];
    [_queuedDevTools removeAllObjects];
    NSView* browserView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    browserView.frame = _view.bounds;
    browserView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    if (_closed) {
        _browser = nullptr;
        for (void (^call)(void) in queued) call();
        browser->GetHost()->CloseBrowser(true);
        return;
    }
    // Document-start scripts only run in sessions with the Page domain enabled.
    if ([_delegate respondsToSelector:@selector(browser:documentStartScriptForURL:)]) {
        [self executeDevToolsMethod:@"Page.enable" params:nil completion:nil];
    }
    // Before the first load, so a Network.enable made while the tab was opening sees its document.
    for (void (^call)(void) in queued) call();
    if (_documentScriptSource && _documentScripts.count == 0 && !_pendingURL) {
        [self addDocumentScript:_documentScriptSource navigation:_navigationCount completion:nil];
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
    if (_audioMuted) browser->GetHost()->SetAudioMuted(true);
    if (_forceDark) [self applyForceDark];
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
- (void)reloadIgnoringCache { if (_browser) _browser->ReloadIgnoreCache(); }
- (void)stopLoading { if (_browser) _browser->StopLoad(); }

- (void)focus {
    _focusBlocked = NO;
    _pendingFocus = !_browser;
    if (_browser) _browser->GetHost()->SetFocus(true);
}

- (void)blur {
    _focusBlocked = YES;
    _pendingFocus = NO;
    if (_browser) _browser->GetHost()->SetFocus(false);
}

- (void)allowFocus {
    _focusBlocked = NO;
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

- (BOOL)audioMuted {
    return _audioMuted;
}

- (void)setAudioMuted:(BOOL)audioMuted {
    _audioMuted = audioMuted;
    if (_browser) _browser->GetHost()->SetAudioMuted(audioMuted);
}

- (void)showDevTools {
    if (!_browser) return;
    CefWindowInfo windowInfo;
    CefBrowserSettings settings;
    _browser->GetHost()->ShowDevTools(windowInfo, nullptr, settings, CefPoint());
}

- (void)find:(NSString*)text forward:(BOOL)forward findNext:(BOOL)findNext {
    if (_browser) _browser->GetHost()->Find(text.UTF8String, forward, false, findNext);
}

- (void)stopFinding {
    // Keep the active match selected, like Chrome and Arc.
    if (_browser) _browser->GetHost()->StopFinding(false);
}

- (void)print {
    if (_browser) _browser->GetHost()->Print();
}

- (void)setForceDark:(BOOL)enabled {
    if (enabled == _forceDark) return;
    _forceDark = enabled;
    // Before the browser exists (launch, restored tabs) this only records the
    // wish; attachBrowser applies it.
    if (_browser) [self applyForceDark];
}

static cef_content_setting_types_t KCContentSettingType(KCSitePermission permission) {
    switch (permission) {
        case KCSitePermissionCamera: return CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA;
        case KCSitePermissionMicrophone: return CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC;
        case KCSitePermissionLocation: return CEF_CONTENT_SETTING_TYPE_GEOLOCATION;
        case KCSitePermissionNotifications: return CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS;
    }
    return CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS;
}

- (KCSitePermissionValue)sitePermission:(KCSitePermission)permission forURL:(NSURL*)url {
    if (!_browser || !url.absoluteString) return KCSitePermissionValueDefault;
    CefRefPtr<CefRequestContext> context = _browser->GetHost()->GetRequestContext();
    if (!context) return KCSitePermissionValueDefault;
    CefString site(url.absoluteString.UTF8String);
    switch (context->GetContentSetting(site, site, KCContentSettingType(permission))) {
        case CEF_CONTENT_SETTING_VALUE_ALLOW: return KCSitePermissionValueAllow;
        case CEF_CONTENT_SETTING_VALUE_BLOCK: return KCSitePermissionValueBlock;
        case CEF_CONTENT_SETTING_VALUE_ASK: return KCSitePermissionValueAsk;
        default: return KCSitePermissionValueDefault;
    }
}

- (void)setSitePermission:(KCSitePermission)permission value:(KCSitePermissionValue)value forURL:(NSURL*)url {
    if (!_browser || !url.absoluteString) return;
    CefRefPtr<CefRequestContext> context = _browser->GetHost()->GetRequestContext();
    if (!context) return;
    cef_content_setting_values_t setting = CEF_CONTENT_SETTING_VALUE_DEFAULT;
    switch (value) {
        case KCSitePermissionValueAllow: setting = CEF_CONTENT_SETTING_VALUE_ALLOW; break;
        case KCSitePermissionValueBlock: setting = CEF_CONTENT_SETTING_VALUE_BLOCK; break;
        case KCSitePermissionValueAsk: setting = CEF_CONTENT_SETTING_VALUE_ASK; break;
        case KCSitePermissionValueDefault: break;
    }
    CefString site(url.absoluteString.UTF8String);
    context->SetContentSetting(site, site, KCContentSettingType(permission), setting);
}

- (void)applyForceDark {
    [self executeDevToolsMethod:@"Emulation.setAutoDarkModeOverride"
                         params:_forceDark ? @{@"enabled": @YES} : @{}
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
    [self callDevToolsMethod:method params:params completion:^(NSDictionary* result, NSString*) {
        if (completion) completion(result);
    }];
}

- (void)callDevToolsMethod:(NSString*)method
                    params:(NSDictionary<NSString*, id>*)params
                completion:(void (^)(NSDictionary*, NSString*))completion {
    if (!_browser) {
        if (_attached || _closed) {
            completion(nil, @"not-ready");
        } else {
            void (^copied)(NSDictionary*, NSString*) = [completion copy];
            [_queuedDevTools addObject:^{ [self callDevToolsMethod:method params:params completion:copied]; }];
        }
        return;
    }
    int messageID = _nextMessageID++;
    (*_pendingDevTools)[messageID] = [completion copy];
    CefRefPtr<CefDictionaryValue> cefParams = params.count ? ToCefValue(params)->GetDictionary() : nullptr;
    if (_browser->GetHost()->ExecuteDevToolsMethod(messageID, method.UTF8String, cefParams) == 0) {
        _pendingDevTools->erase(messageID);
        completion(nil, @"Chromium couldn't send the DevTools message.");
    }
}

- (BOOL)deliverSessionMessage:(NSData*)data {
    // Cheap check first: most messages belong to the browser's own session.
    static NSData* marker = [@"\"sessionId\"" dataUsingEncoding:NSUTF8StringEncoding];
    if ([data rangeOfData:marker options:0 range:NSMakeRange(0, data.length)].location == NSNotFound) return NO;
    NSDictionary* message = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![message isKindOfClass:NSDictionary.class] || ![message[@"sessionId"] isKindOfClass:NSString.class]) return NO;
    self.sessionMessageHandler(message);
    return YES;
}

- (void)sendDevToolsMessage:(NSDictionary<NSString*, id>*)message {
    if (!_browser) return;
    NSData* data = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    if (data) _browser->GetHost()->SendDevToolsMessage(data.bytes, data.length);
}

- (void)deliverDevToolsResult:(int)messageID success:(bool)success data:(NSData*)data {
    auto it = _pendingDevTools->find(messageID);
    if (it == _pendingDevTools->end()) return;
    void (^completion)(NSDictionary*, NSString*) = it->second;
    _pendingDevTools->erase(it);
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary* object = [json isKindOfClass:NSDictionary.class] ? json : nil;
    if (success) {
        completion(object, object ? nil : @"Unreadable DevTools result.");
    } else {
        // Failures carry the protocol's {code, message}.
        NSString* message = [object[@"message"] isKindOfClass:NSString.class] ? object[@"message"] : @"DevTools method failed.";
        completion(nil, message);
    }
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

/// Popups load their first page as soon as Chromium creates them, possibly before
/// this object has its browser: keep the script now, register it when attached,
/// and run it at load start in case the first document beat it.
- (void)prepareFirstPage:(NSURL*)url {
    if (!url || ![_delegate respondsToSelector:@selector(browser:documentStartScriptForURL:)]) return;
    NSString* script = [_delegate browser:self documentStartScriptForURL:url];
    if (!script.length) return;
    _documentScriptSource = script;
    _runScriptAtLoadStart = YES;
}

- (void)mainFrameDidStartLoading {
    if (!_runScriptAtLoadStart) return;
    _runScriptAtLoadStart = NO;
    if (_documentScriptSource) [self evaluateJavaScript:_documentScriptSource completion:^(id) {}];
}

- (void)willNavigateMainFrame:(CefRefPtr<CefRequest>)request {
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
    // Only a changed script makes registrations still in flight stale.
    NSUInteger navigation = ++_navigationCount;
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

- (void)deliverDevToolsEvent:(NSString*)method data:(NSData*)data {
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSDictionary* params = [json isKindOfClass:NSDictionary.class] ? json : @{};
    if (self.pageFeatureEventHandler) self.pageFeatureEventHandler(method, params);
    if (self.devToolsEventHandler) self.devToolsEventHandler(method, params);
}

- (void)close {
    _closed = YES;
    _delegate = nil;
    if (_browser) _browser->GetHost()->CloseBrowser(true);
}

+ (BOOL)cancelDownloadWithID:(NSInteger)downloadID {
    auto it = DownloadCallbacks().find((uint32_t)downloadID);
    if (it == DownloadCallbacks().end()) return NO;
    it->second->Cancel();
    return YES;
}

@end

#import "CEFBridge.h"
#import "KCInternal.h"

#import <AVFoundation/AVFoundation.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <map>
#include <vector>

#include "include/cef_client.h"
#include "include/cef_cookie.h"
#include "include/cef_context_menu_handler.h"
#include "include/cef_devtools_message_observer.h"
#include "include/cef_jsdialog_handler.h"
#include "include/cef_keyboard_handler.h"
#include "include/cef_parser.h"
#include "include/cef_permission_handler.h"
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
- (void)pageDidLetGo;
/// `close` was called: nothing may ask the person any more.
@property (nonatomic, readonly) BOOL isForceClosing;
- (void)deliverDevToolsResult:(int)messageID success:(bool)success data:(NSData *)data;
- (void)willNavigateMainFrame:(CefRefPtr<CefRequest>)request;
- (void)mainFrameDidStartLoading;
- (void)prepareFirstPage:(nullable NSURL *)url;
- (NSMutableArray<NSString *> *)documentScriptIdentifiers;
- (void)addDocumentScript:(NSString *)script navigation:(NSUInteger)navigation completion:(nullable void (^)(void))completion;
- (void)deliverDevToolsEvent:(NSString *)method data:(NSData *)data;
- (void)devToolsFrontendDidOpen:(CefRefPtr<CefBrowser>)frontend;
- (void)devToolsFrontendDidLoad;
- (void)devToolsFrontendDidClose;
- (BOOL)deliverSessionMessage:(NSData *)data;
- (void)addNetworkBytes:(uint64_t)bytes;
@property (nonatomic, readwrite) BOOL isLoading;
@property (nonatomic, readwrite) BOOL canGoBack;
@property (nonatomic, readwrite) BOOL canGoForward;
@property (nonatomic, readwrite) int renderProcessIdentifier;
@end

NSString* const KCDownloadDidUpdateNotification = @"KCDownloadDidUpdateNotification";

namespace {

/// A beforeunload dialog Kite is showing, waiting for Leave or Cancel.
struct PendingUnloadDialog {
    CefRefPtr<CefJSDialogCallback> callback;
    __weak KCBrowser* owner;
};

/// Each browser's unanswered beforeunload dialog, by browser identifier.
std::map<int, PendingUnloadDialog>& PendingBeforeUnload() {
    static auto* pending = new std::map<int, PendingUnloadDialog>();
    return *pending;
}

}  // namespace

void KCAcceptPendingBeforeUnload(CefRefPtr<CefBrowser> browser) {
    // Collected first: answering runs Chromium code that may touch the map.
    std::vector<PendingUnloadDialog> answered;
    auto& pending = PendingBeforeUnload();
    for (auto it = pending.begin(); it != pending.end();) {
        if (browser && it->first != browser->GetIdentifier()) { ++it; continue; }
        answered.push_back(it->second);
        it = pending.erase(it);
    }
    for (auto& dialog : answered) {
        // First, so the reset Continue brings doesn't read as the person staying.
        KCBrowser* closing = dialog.owner;
        if ([closing.delegate respondsToSelector:@selector(browserWillCloseWithoutAsking:)]) {
            [closing.delegate browserWillCloseWithoutAsking:closing];
        }
        dialog.callback->Continue(true, CefString());
        // Then take Kite's sheet down; its late Cancel reaches a callback that has already run.
        KCBrowser* owner = dialog.owner;
        if ([owner.delegate respondsToSelector:@selector(browserDismissJavaScriptDialogs:)]) {
            [owner.delegate browserDismissJavaScriptDialogs:owner];
        }
    }
}

void KCForgetPendingBeforeUnload() {
    PendingBeforeUnload().clear();
}

namespace {

/// What a tab shows before its page first draws: the dark grey of the card holding it (NSColor.pageBackdrop),
/// not Chromium's white. Chromium also uses it as the page's default background, so
/// attachBrowser puts that back to white.
const cef_color_t KCPageBackdropColor = 0xFF323232;

NSString* ToNSString(const CefString& string) {
    return [NSString stringWithUTF8String:string.ToString().c_str()] ?: @"";
}

NSURL* ToNSURL(const CefString& string) {
    if (string.empty()) return nil;
    return [NSURL URLWithString:ToNSString(string)];
}

/// Counts each tab's network bytes for the Task Manager's Network column, and passes everything
/// else to the tab's ad blocker (null when Kite is built without one). Chromium's task manager
/// gets these numbers from its network service; CEF only reports a request's bytes when it
/// finishes, so a long download or stream counts at its end.
class NetworkCountingHandler : public CefResourceRequestHandler {
 public:
    NetworkCountingHandler(KCBrowser* owner, CefRefPtr<CefResourceRequestHandler> inner) : owner_(owner), inner_(inner) {}

    CefRefPtr<CefCookieAccessFilter> GetCookieAccessFilter(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                                           CefRefPtr<CefRequest> request) override {
        return inner_ ? inner_->GetCookieAccessFilter(browser, frame, request) : nullptr;
    }

    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request, CefRefPtr<CefCallback> callback) override {
        return inner_ ? inner_->OnBeforeResourceLoad(browser, frame, request, callback) : RV_CONTINUE;
    }

    CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                                     CefRefPtr<CefRequest> request) override {
        return inner_ ? inner_->GetResourceHandler(browser, frame, request) : nullptr;
    }

    void OnResourceRedirect(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                            CefRefPtr<CefResponse> response, CefString& new_url) override {
        if (inner_) inner_->OnResourceRedirect(browser, frame, request, response, new_url);
    }

    bool OnResourceResponse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                            CefRefPtr<CefResponse> response) override {
        return inner_ ? inner_->OnResourceResponse(browser, frame, request, response) : false;
    }

    CefRefPtr<CefResponseFilter> GetResourceResponseFilter(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                                                           CefRefPtr<CefRequest> request,
                                                           CefRefPtr<CefResponse> response) override {
        return inner_ ? inner_->GetResourceResponseFilter(browser, frame, request, response) : nullptr;
    }

    void OnResourceLoadComplete(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                                CefRefPtr<CefResponse> response, URLRequestStatus status,
                                int64_t received_content_length) override {
        if (inner_) inner_->OnResourceLoadComplete(browser, frame, request, response, status, received_content_length);
        // Received and sent, as Chromium counts them; uploads are their in-memory bytes.
        uint64_t bytes = received_content_length > 0 ? (uint64_t)received_content_length : 0;
        if (CefRefPtr<CefPostData> post = request ? request->GetPostData() : nullptr) {
            CefPostData::ElementVector elements;
            post->GetElements(elements);
            for (const auto& element : elements) {
                if (element->GetType() == PDE_TYPE_BYTES) bytes += element->GetBytesCount();
            }
        }
        KCBrowser* owner = owner_;
        if (bytes && owner) [owner addNetworkBytes:bytes];
    }

    void OnProtocolExecution(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, CefRefPtr<CefRequest> request,
                             bool& allow_os_execution) override {
        if (inner_) inner_->OnProtocolExecution(browser, frame, request, allow_os_execution);
    }

 private:
    __weak KCBrowser* owner_;
    CefRefPtr<CefResourceRequestHandler> inner_;
    IMPLEMENT_REFCOUNTING(NetworkCountingHandler);
};

/// The on-disk profiles' contexts, by folder name (see contextForProfileDirectory:).
NSMutableDictionary<NSString*, KCRequestContext*>* ProfileContexts() {
    static NSMutableDictionary<NSString*, KCRequestContext*>* contexts = [NSMutableDictionary dictionary];
    return contexts;
}

/// Incognito contexts whose KCRequestContext is still around (weakly held: an incognito
/// window's engine goes when the window closes).
NSHashTable<KCRequestContext*>* IncognitoContexts() {
    static NSHashTable<KCRequestContext*>* contexts = [NSHashTable weakObjectsHashTable];
    return contexts;
}

/// Where a download came from: `key` names its browser context ("" for the default profile, the
/// folder name for another profile, "incognito-N" for an incognito window), `profile` is the
/// folder for a non-default profile.
struct DownloadSource {
    NSString* key = @"";
    NSString* profile = nil;
    bool incognito = false;
};

DownloadSource DownloadSourceOf(CefRefPtr<CefRequestContext> context) {
    DownloadSource source;
    if (!context) return source;
    // The default profile: the global context, or one sharing its storage (the ad blocker's).
    // An Arc sign-in import can also open a "Default" profile context; that's this one too.
    CefRefPtr<CefRequestContext> global = CefRequestContext::GetGlobalContext();
    if (global && (context->IsSame(global) || context->IsSharingWith(global))) return source;
    for (NSString* directory in ProfileContexts()) {
        if ([directory isEqualToString:@"Default"]) continue;
        if (ProfileContexts()[directory].cefContext->IsSame(context)) {
            source.key = directory;
            source.profile = directory;
            return source;
        }
    }
    // An empty cache path is an in-memory (incognito) profile.
    if (context->GetCachePath().empty()) {
        source.incognito = true;
        for (KCRequestContext* incognito in IncognitoContexts()) {
            if (incognito.cefContext->IsSame(context)) { source.key = incognito.downloadContextKey; return source; }
        }
        // Its window has closed and its KCRequestContext has gone with the engine: the session is over.
        source.key = nil;
    }
    return source;
}

/// Incognito sessions whose window has closed (endDownloadsForContextKey:). Their downloads are
/// canceled and never followed again, so nothing keeps their in-memory profile alive.
NSMutableSet<NSString*>* EndedDownloadContexts() {
    static NSMutableSet<NSString*>* keys = [NSMutableSet set];
    return keys;
}

/// An incognito download whose session is over: cancel it, and don't follow or list it.
bool IsEndedSession(const DownloadSource& source) {
    return source.incognito && (!source.key || [EndedDownloadContexts() containsObject:source.key]);
}

/// A download Kite has handed a path to and is still following. Chromium's id restarts at 1 in
/// every browser context (each profile, each incognito window), so a download is its id plus its
/// context. Its source is worked out once, when it starts, and reused for every update: the
/// incognito window's KCRequestContext can go while the download carries on.
/// Download callbacks run on the main (UI) thread.
struct LiveDownload {
    /// Held strongly while followed: an incognito session's are dropped when it ends.
    CefRefPtr<CefRequestContext> context;
    uint32_t id;
    DownloadSource source;
    /// The path it saves to, held so no other download is given it until this one completes
    /// or is canceled (an interrupted one can resume into the same file).
    NSString* path;
    /// Set until it completes or is canceled (interrupted too), so the downloads list or an ending
    /// incognito session can cancel it. Nil only before its first update.
    CefRefPtr<CefDownloadItemCallback> callback;
    bool interrupted;
};

std::vector<LiveDownload>& LiveDownloads() {
    static std::vector<LiveDownload> downloads;
    return downloads;
}

/// Interrupted downloads stay followed (they can resume) and a destroyed browser may never send
/// a final update, so past this many the oldest interrupted one goes, else the oldest.
constexpr size_t kMaxLiveDownloads = 200;

LiveDownload* FindLiveDownload(CefRefPtr<CefRequestContext> context, uint32_t id) {
    for (LiveDownload& download : LiveDownloads()) {
        if (download.id == id && context && download.context && download.context->IsSame(context)) return &download;
    }
    return nullptr;
}

LiveDownload& AddLiveDownload(CefRefPtr<CefRequestContext> context, uint32_t id, const DownloadSource& source) {
    std::vector<LiveDownload>& downloads = LiveDownloads();
    while (downloads.size() >= kMaxLiveDownloads) {
        auto stale = std::find_if(downloads.begin(), downloads.end(), [](const LiveDownload& d) { return d.interrupted; });
        downloads.erase(stale != downloads.end() ? stale : downloads.begin());
    }
    downloads.push_back({context, id, source, nil, nullptr, false});
    return downloads.back();
}

void RemoveLiveDownload(LiveDownload* download) {
    std::vector<LiveDownload>& downloads = LiveDownloads();
    downloads.erase(downloads.begin() + (download - downloads.data()));
}

NSURL* _Nullable (^gDownloadFolderProvider)(NSString* _Nullable, BOOL*);

/// The folder a download from `profile` (nil: the default profile or incognito) saves into, and
/// whether to ask where first: the app's answer for the profile, else Downloads.
NSURL* DownloadFolder(NSString* profile, BOOL* prompt) {
    *prompt = NO;
    if (gDownloadFolderProvider) {
        if (NSURL* folder = gDownloadFolderProvider(profile, prompt)) return folder;
    }
    NSURL* directory = [NSFileManager.defaultManager URLsForDirectory:NSDownloadsDirectory inDomains:NSUserDomainMask].firstObject;
    // Test runs on a throwaway profile save into their own folder, never the user's Downloads.
    NSString* testDirectory = NSProcessInfo.processInfo.environment[@"KITE_TEST_DOWNLOADS_PATH"];
    if (testDirectory.length && NSProcessInfo.processInfo.environment[@"KITE_SUPPORT_PATH"].length) {
        directory = [NSURL fileURLWithPath:testDirectory isDirectory:YES];
    }
    return directory;
}

NSURL* UniqueDownloadURL(NSString* name, NSURL* directory) {
    NSString* base = name.stringByDeletingPathExtension;
    NSString* extension = name.pathExtension;
    // Paths given to downloads still running: Chromium creates the file only once data arrives,
    // so two same-name downloads that start together would both find the name free.
    NSMutableSet<NSString*>* reserved = [NSMutableSet set];
    for (const LiveDownload& download : LiveDownloads()) if (download.path) [reserved addObject:download.path];
    auto taken = [&](NSURL* url) {
        return [reserved containsObject:url.path] || [NSFileManager.defaultManager fileExistsAtPath:url.path];
    };
    NSURL* candidate = [directory URLByAppendingPathComponent:name];
    for (int n = 2; taken(candidate); n++) {
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

/// Client for a tab's DevTools window. It keeps the frontend browser so View ›
/// Developer can pick a panel (showDevToolsRunningFrontendScript:).
class KCDevToolsClient : public CefClient, public CefLifeSpanHandler, public CefLoadHandler {
 public:
    explicit KCDevToolsClient(KCBrowser* owner) : owner_(owner) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override { [owner_ devToolsFrontendDidOpen:browser]; }
    void OnBeforeClose(CefRefPtr<CefBrowser> browser) override { [owner_ devToolsFrontendDidClose]; }
    void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int httpStatusCode) override {
        if (frame->IsMain()) [owner_ devToolsFrontendDidLoad];
    }

 private:
    __weak KCBrowser* owner_;
    IMPLEMENT_REFCOUNTING(KCDevToolsClient);
};

/// A mailto: navigation goes to the default mail app's compose page when the delegate has one
/// (Kite's MailHandlers): the frame loads it instead (a subframe's opens as a tab).
static bool RouteMailto(KCBrowser* owner, CefRefPtr<CefFrame> frame, const CefString& target) {
    id<KCBrowserDelegate> delegate = owner.delegate;
    NSURL* url = ToNSURL(target);
    if (!url || ![url.scheme.lowercaseString isEqualToString:@"mailto"] ||
        ![delegate respondsToSelector:@selector(browser:mailtoDestinationForURL:)]) return false;
    NSURL* compose = [delegate browser:owner mailtoDestinationForURL:url];
    if (!compose) return false;
    if (frame->IsMain()) {
        std::string spec = compose.absoluteString.UTF8String;
        dispatch_async(dispatch_get_main_queue(), ^{
            frame->LoadURL(spec);
        });
    } else {
        [delegate browser:owner openURLInNewTab:compose foreground:YES];
    }
    return true;
}

/// Chromium's own schemes, which load in the page; anything else may belong to another app.
static bool IsInPageScheme(NSString* scheme) {
    static NSSet<NSString*>* schemes = [NSSet setWithArray:@[
        @"http", @"https", @"about", @"blob", @"data", @"file", @"javascript", @"chrome", @"chrome-extension",
        @"devtools", @"view-source", @"ws", @"wss", @"filesystem"
    ]];
    return [schemes containsObject:scheme.lowercaseString];
}

/// t3code:, zoommtg:, etc. go to the app that claims them, as in WebKitEngine (an OAuth callback
/// is a redirect to one). Chromium would show ERR_UNKNOWN_URL_SCHEME instead.
static bool RouteExternalScheme(const CefString& target) {
    NSURL* url = ToNSURL(target);
    if (!url.scheme || IsInPageScheme(url.scheme)) return false;
    NSURL* app = [NSWorkspace.sharedWorkspace URLForApplicationToOpenURL:url];
    if (!app || [[NSBundle bundleWithURL:app].bundleIdentifier isEqualToString:NSBundle.mainBundle.bundleIdentifier]) {
        return false;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSWorkspace.sharedWorkspace openURL:url];
    });
    return true;
}

/// Whether the delegate opens a clicked link in Arc's Peek card instead (it reports the link itself).
static bool AskLinkPeek(KCBrowser* owner, const CefString& target, bool shift) {
    id<KCBrowserDelegate> delegate = owner.delegate;
    NSURL* url = ToNSURL(target);
    if (!url || ![delegate respondsToSelector:@selector(browser:opensLinkInPeek:shift:)]) return false;
    return [delegate browser:owner opensLinkInPeek:url shift:shift];
}

/// Asks the delegate about a site's permission request. `done` runs at most once, with the
/// answer already stored for the site (Allow or Block; Dismiss stores nothing). False when the
/// delegate doesn't show prompts, so Chromium's default applies.
static bool AskPermissions(KCBrowser* owner, NSArray<NSNumber*>* permissions, NSURL* origin, NSInteger promptID,
                           void (^done)(KCPermissionDecision)) {
    id<KCBrowserDelegate> delegate = owner.delegate;
    SEL ask = @selector(browser:requestsPermissions:origin:promptID:decisionHandler:);
    if (!owner || !origin || !permissions.count || ![delegate respondsToSelector:ask]) return false;
    __weak KCBrowser* weakOwner = owner;
    __block bool answered = false;
    [delegate browser:owner requestsPermissions:permissions origin:origin promptID:promptID
      decisionHandler:^(KCPermissionDecision decision) {
        if (answered) return;
        answered = true;
        KCBrowser* browser = weakOwner;
        if (browser && decision != KCPermissionDecisionDismiss) {
            KCSitePermissionValue value = decision == KCPermissionDecisionAllow ? KCSitePermissionValueAllow
                                                                                : KCSitePermissionValueBlock;
            for (NSNumber* permission in permissions) {
                [browser setSitePermission:(KCSitePermission)permission.integerValue value:value forURL:origin];
            }
        }
        done(decision);
    }];
    return true;
}

/// Whether macOS lets Kite use `type`, asking the first time (on the main thread, like `then`).
static void RequestSystemAccess(AVMediaType type, bool wanted, void (^then)(bool allowed)) {
    if (!wanted) return then(true);
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:type];
    if (status != AVAuthorizationStatusNotDetermined) return then(status == AVAuthorizationStatusAuthorized);
    [AVCaptureDevice requestAccessForMediaType:type completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{ then(granted); });
    }];
}

/// The CEF media bits in `requested` that macOS lets Kite use. Chromium (Alloy) never asks macOS
/// itself, so without this macOS never lists Kite under Privacy & Security and capture fails
/// with no way to turn it on. Asked the first time a site is given either, as Chrome does; the
/// owner hears which ones macOS has turned off.
static void WithSystemMediaAccess(KCBrowser* owner, uint32_t requested, void (^done)(uint32_t allowed)) {
    const uint32_t audio = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
    const uint32_t video = CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
    __weak KCBrowser* weakOwner = owner;
    RequestSystemAccess(AVMediaTypeAudio, requested & audio, ^(bool microphone) {
        RequestSystemAccess(AVMediaTypeVideo, requested & video, ^(bool camera) {
            uint32_t allowed = requested;
            NSMutableArray<NSNumber*>* off = [NSMutableArray array];
            if (!camera) { allowed &= ~video; [off addObject:@(KCSitePermissionCamera)]; }
            if (!microphone) { allowed &= ~audio; [off addObject:@(KCSitePermissionMicrophone)]; }
            KCBrowser* browser = weakOwner;
            id<KCBrowserDelegate> delegate = browser.delegate;
            if (browser && off.count && [delegate respondsToSelector:@selector(browser:systemBlocksPermissions:)]) {
                [delegate browser:browser systemBlocksPermissions:off];
            }
            done(allowed);
        });
    });
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
                 public CefContextMenuHandler,
                 public CefPermissionHandler,
                 public CefJSDialogHandler,
                 public CefDevToolsMessageObserver {
 public:
    explicit KCClient(KCBrowser* owner) : owner_(owner), container_(owner.view), requests_(new NetworkCountingHandler(owner, KCAdblockRequestHandler(owner))) {}

    CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
    CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
    CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
    CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
    CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
    CefRefPtr<CefFindHandler> GetFindHandler() override { return this; }
    CefRefPtr<CefKeyboardHandler> GetKeyboardHandler() override { return this; }
    CefRefPtr<CefFocusHandler> GetFocusHandler() override { return this; }
    CefRefPtr<CefContextMenuHandler> GetContextMenuHandler() override { return this; }
    CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
    CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }

    // CefPermissionHandler: Kite's own prompt (Arc's) for camera, microphone, location and
    // notifications. Anything else keeps Chromium's default.

    /// getUserMedia. A site with a stored answer isn't asked again.
    bool OnRequestMediaAccessPermission(CefRefPtr<CefBrowser> browser,
                                        CefRefPtr<CefFrame> frame,
                                        const CefString& requesting_origin,
                                        uint32_t requested_permissions,
                                        CefRefPtr<CefMediaAccessCallback> callback) override {
        const uint32_t audio = CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE;
        const uint32_t video = CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE;
        if (!requested_permissions || (requested_permissions & ~(audio | video))) return false;
        KCBrowser* owner = owner_;
        NSURL* origin = ToNSURL(requesting_origin);
        if (!owner || !origin) return false;
        NSMutableArray<NSNumber*>* permissions = [NSMutableArray array];
        if (requested_permissions & video) [permissions addObject:@(KCSitePermissionCamera)];
        if (requested_permissions & audio) [permissions addObject:@(KCSitePermissionMicrophone)];
        bool allAllowed = true;
        for (NSNumber* permission in permissions) {
            KCSitePermissionValue stored = [owner sitePermission:(KCSitePermission)permission.integerValue forURL:origin];
            if (stored == KCSitePermissionValueBlock) {
                callback->Continue(CEF_MEDIA_PERMISSION_NONE);
                return true;
            }
            allAllowed = allAllowed && stored == KCSitePermissionValueAllow;
        }
        if (allAllowed) {
            WithSystemMediaAccess(owner, requested_permissions, ^(uint32_t allowed) { callback->Continue(allowed); });
            return true;
        }
        __weak KCBrowser* weakOwner = owner;
        return AskPermissions(owner, permissions, origin, --media_prompt_id_, ^(KCPermissionDecision decision) {
            if (decision != KCPermissionDecisionAllow) return callback->Continue(CEF_MEDIA_PERMISSION_NONE);
            WithSystemMediaAccess(weakOwner, requested_permissions, ^(uint32_t allowed) { callback->Continue(allowed); });
        });
    }

    /// Geolocation, notifications (and camera or mic when Chromium routes them here). Chromium
    /// itself only asks when nothing is stored for the site.
    bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                uint64_t prompt_id,
                                const CefString& requesting_origin,
                                uint32_t requested_permissions,
                                CefRefPtr<CefPermissionPromptCallback> callback) override {
        const uint32_t camera = CEF_PERMISSION_TYPE_CAMERA_STREAM, mic = CEF_PERMISSION_TYPE_MIC_STREAM;
        const uint32_t location = CEF_PERMISSION_TYPE_GEOLOCATION, notifications = CEF_PERMISSION_TYPE_NOTIFICATIONS;
        if (!requested_permissions || (requested_permissions & ~(camera | mic | location | notifications))) return false;
        NSMutableArray<NSNumber*>* permissions = [NSMutableArray array];
        if (requested_permissions & camera) [permissions addObject:@(KCSitePermissionCamera)];
        if (requested_permissions & mic) [permissions addObject:@(KCSitePermissionMicrophone)];
        if (requested_permissions & location) [permissions addObject:@(KCSitePermissionLocation)];
        if (requested_permissions & notifications) [permissions addObject:@(KCSitePermissionNotifications)];
        __weak KCBrowser* weakOwner = owner_;
        uint32_t media = (requested_permissions & camera ? CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE : 0)
                       | (requested_permissions & mic ? CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE : 0);
        return AskPermissions(owner_, permissions, ToNSURL(requesting_origin), (NSInteger)prompt_id,
                              ^(KCPermissionDecision decision) {
            switch (decision) {
                case KCPermissionDecisionAllow: {
                    // The site's answer stands; macOS is asked here so the capture that follows works.
                    if (!media) { callback->Continue(CEF_PERMISSION_RESULT_ACCEPT); break; }
                    WithSystemMediaAccess(weakOwner, media, ^(uint32_t) { callback->Continue(CEF_PERMISSION_RESULT_ACCEPT); });
                    break;
                }
                case KCPermissionDecisionBlock: callback->Continue(CEF_PERMISSION_RESULT_DENY); break;
                case KCPermissionDecisionDismiss: callback->Continue(CEF_PERMISSION_RESULT_DISMISS); break;
            }
        });
    }

    /// window.alert, confirm and prompt go to Kite's own dialog (Arc's willRunJavaScript…Panel)
    /// instead of Chromium's NSAlert.
    bool OnJSDialog(CefRefPtr<CefBrowser> browser,
                    const CefString& origin_url,
                    JSDialogType dialog_type,
                    const CefString& message_text,
                    const CefString& default_prompt_text,
                    CefRefPtr<CefJSDialogCallback> callback,
                    bool& suppress_message) override {
        KCJavaScriptDialogKind kind = dialog_type == JSDIALOGTYPE_CONFIRM ? KCJavaScriptDialogKindConfirm
                                    : dialog_type == JSDIALOGTYPE_PROMPT ? KCJavaScriptDialogKindPrompt
                                    : KCJavaScriptDialogKindAlert;
        return RunDialog(kind, ToNSString(message_text), ToNSString(default_prompt_text), ToNSURL(origin_url), callback);
    }

    bool OnBeforeUnloadDialog(CefRefPtr<CefBrowser> browser,
                              const CefString& message_text,
                              bool is_reload,
                              CefRefPtr<CefJSDialogCallback> callback) override {
        KCBrowser* owner = owner_;
        // A forced close (quitting, hibernation) still asks: the page leaves without a dialog,
        // which would hold up the quit. Answered on a later turn: answering inside this call
        // slowed Chromium's teardown.
        if (KCRuntimeIsQuitting() || !owner || owner.isForceClosing) {
            dispatch_async(dispatch_get_main_queue(), ^{ callback->Continue(true, CefString()); });
            return true;
        }
        NSURL* origin = ToNSURL(browser->GetMainFrame()->GetURL());
        int identifier = browser->GetIdentifier();
        // Recorded before the dialog shows, so quitting can answer it.
        PendingBeforeUnload()[identifier] = {callback, owner};
        bool shown = RunDialog(is_reload ? KCJavaScriptDialogKindReload : KCJavaScriptDialogKindLeave, @"", @"", origin, callback,
                               ^(bool) { PendingBeforeUnload().erase(identifier); });
        if (!shown) PendingBeforeUnload().erase(identifier);
        return shown;
    }

    void OnResetDialogState(CefRefPtr<CefBrowser> browser) override {
        KCBrowser* owner = owner_;
        PendingBeforeUnload().erase(browser->GetIdentifier());
        if ([owner.delegate respondsToSelector:@selector(browserDismissJavaScriptDialogs:)]) {
            [owner.delegate browserDismissJavaScriptDialogs:owner];
        }
    }

    bool RunDialog(KCJavaScriptDialogKind kind, NSString* message, NSString* defaultText, NSURL* origin,
                   CefRefPtr<CefJSDialogCallback> callback, void (^answered_)(bool ok) = nil) {
        KCBrowser* owner = owner_;
        id<KCBrowserDelegate> delegate = owner.delegate;
        SEL run = @selector(browser:runJavaScriptDialog:message:defaultText:origin:completion:);
        if (!owner || ![delegate respondsToSelector:run]) return false;
        __block bool answered = false;
        [delegate browser:owner runJavaScriptDialog:kind message:message ?: @"" defaultText:defaultText ?: @""
                   origin:origin completion:^(BOOL ok, NSString* text) {
            if (answered) return;
            answered = true;
            if (answered_) answered_(ok);
            callback->Continue(ok, CefString(text.UTF8String ?: ""));
        }];
        return true;
    }

    void OnDismissPermissionPrompt(CefRefPtr<CefBrowser> browser,
                                   uint64_t prompt_id,
                                   cef_permission_request_result_t result) override {
        KCBrowser* owner = owner_;
        if ([owner.delegate respondsToSelector:@selector(browser:permissionPromptDidCancel:)]) {
            [owner.delegate browser:owner permissionPromptDidCancel:(NSInteger)prompt_id];
        }
    }

    // CefClient

    /// The renderer reports its pid for the Task Manager (KiteHelper's kite.rendererPID).
    bool OnProcessMessageReceived(CefRefPtr<CefBrowser> browser,
                                  CefRefPtr<CefFrame> frame,
                                  CefProcessId source_process,
                                  CefRefPtr<CefProcessMessage> message) override {
        if (message->GetName() != "kite.rendererPID" || !frame->IsMain()) return false;
        owner_.renderProcessIdentifier = message->GetArgumentList()->GetInt(0);
        return true;
    }

    // CefFocusHandler

    /// True cancels: the page asked for the keyboard while Kite's own UI holds it.
    bool OnSetFocus(CefRefPtr<CefBrowser> browser, FocusSource source) override {
        return owner_.focusBlocked;
    }

    // CefLifeSpanHandler

    void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
        KCRegisterBrowser(browser);
        devtools_registration_ = browser->GetHost()->AddDevToolsMessageObserver(this);
        KCBrowser* owner = owner_;
        // Its KCBrowser went away while Chromium was making it: nothing would ever close it.
        if (!owner) return browser->GetHost()->CloseBrowser(true);
        [owner attachBrowser:browser];
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
        if (!delegate || KCRuntimeIsQuitting()) return true;
        // A target=_blank link (or ⇧-click) the delegate opens in Arc's Peek card: no popup. Not a named
        // window (window.open(url, "AppleAuthentication")): a Peek has no window.opener, so the result of
        // a sign-in popup would never reach the page.
        bool linkClick = (target_disposition == CEF_WOD_NEW_FOREGROUND_TAB || target_disposition == CEF_WOD_NEW_WINDOW) &&
                         target_frame_name.empty();
        if (user_gesture && linkClick && AskLinkPeek(owner, target_url, target_disposition == CEF_WOD_NEW_WINDOW)) return true;
        // Host the popup in a Kite tab instead of a separate native window. Asked first: a page nobody
        // shows (a background reader, an install or verification page) has nowhere to put one, so the
        // popup is cancelled (window.open returns null) rather than built into a view that's going away.
        KCBrowser* popup = [[KCBrowser alloc] initPopupWithDelegate:delegate];
        if (![delegate browser:owner didCreatePopup:popup url:ToNSURL(target_url)]) {
            [popup close];
            return true;
        }
        NSRect bounds = owner.view.bounds;
        windowInfo.SetAsChild((__bridge CefWindowHandle)popup.view,
                              CefRect(0, 0, (int)NSWidth(bounds), (int)NSHeight(bounds)));
        client = new KCClient(popup);
        settings.background_color = KCPageBackdropColor;
        [popup prepareFirstPage:ToNSURL(target_url)];
        return false;
    }

    bool DoClose(CefRefPtr<CefBrowser> browser) override {
        // The page's beforeunload let a close the person asked for go ahead.
        [owner_ pageDidLetGo];
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
        PendingBeforeUnload().erase(browser->GetIdentifier());
        [owner_ browserDidClose];
        KCUnregisterBrowser(browser);
        container_ = nil;
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

    bool OnAutoResize(CefRefPtr<CefBrowser> browser, const CefSize& new_size) override {
        KCBrowser* owner = owner_;
        if (!owner.autoResizeHandler) return false;
        owner.autoResizeHandler(NSMakeSize(new_size.width, new_size.height));
        return true;
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
        if (RouteMailto(owner_, frame, request->GetURL())) return true;
        if (RouteExternalScheme(request->GetURL())) return true;
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
        owner.renderProcessIdentifier = 0;
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
        return is_download ? nullptr : requests_;
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
        CefRefPtr<CefRequestContext> context = browser->GetHost()->GetRequestContext();
        LiveDownload* live = FindLiveDownload(context, download_item->GetId());
        if (!live) {
            DownloadSource source = DownloadSourceOf(context);
            if (IsEndedSession(source)) {
                // Its incognito window has closed: canceled at its first update, never followed.
                NSString* name = [NSString stringWithFormat:@"KiteEndedIncognito-%@", NSUUID.UUID.UUIDString];
                callback->Continue([NSTemporaryDirectory() stringByAppendingPathComponent:name].UTF8String, false);
                return true;
            }
            live = &AddLiveDownload(context, download_item->GetId(), source);
        }
        // Asked again for the same download (Chromium restarting an interrupted one): its own
        // reservation doesn't count against it.
        live->path = nil;
        BOOL prompt = NO;
        NSURL* folder = DownloadFolder(live->source.profile, &prompt);
        NSString* path = UniqueDownloadURL(ToNSString(suggested_name), folder).path;
        live->path = path;
        // With `prompt`, Chromium's Save panel opens in the folder with the name filled in.
        callback->Continue(path.UTF8String, prompt);
        return true;
    }

    void OnDownloadUpdated(CefRefPtr<CefBrowser> browser,
                           CefRefPtr<CefDownloadItem> download_item,
                           CefRefPtr<CefDownloadItemCallback> callback) override {
        // A store install's package isn't the user's download: no bounce, not listed.
        if (IsExtensionPackage(download_item, download_item->GetSuggestedFileName())) return;
        CefRefPtr<CefRequestContext> context = browser->GetHost()->GetRequestContext();
        LiveDownload* live = FindLiveDownload(context, download_item->GetId());
        // A repeat after the download finished (Kite already let it go): nothing new to report.
        if (!live && !download_item->IsInProgress() && !download_item->IsInterrupted()) return;
        if (!live) {
            DownloadSource source = DownloadSourceOf(context);
            if (IsEndedSession(source)) {
                if (download_item->IsInProgress() || download_item->IsInterrupted()) callback->Cancel();
                return;
            }
            live = &AddLiveDownload(context, download_item->GetId(), source);
        }
        if (download_item->IsComplete()) [NSApp requestUserAttention:NSInformationalRequest];
        DownloadSource source = live->source;
        // The Save panel may have put it somewhere else: hold the path it really uses.
        NSString* fullPath = ToNSString(download_item->GetFullPath());
        if (fullPath.length) live->path = fullPath;
        bool finished = download_item->IsComplete() || download_item->IsCanceled();
        live->callback = callback;
        live->interrupted = download_item->IsInterrupted();
        if (finished) RemoveLiveDownload(live);
        NSString* state = download_item->IsComplete() ? @"complete"
            : download_item->IsCanceled() ? @"canceled"
            : download_item->IsInterrupted() ? @"interrupted" : @"in-progress";
        NSMutableDictionary* info = [@{
            @"id": @(download_item->GetId()),
            @"context": source.key,
            @"incognito": @(source.incognito),
            @"url": ToNSString(download_item->GetOriginalUrl()),
            @"path": fullPath,
            @"state": state,
            @"receivedBytes": @(download_item->GetReceivedBytes()),
            @"totalBytes": @(download_item->GetTotalBytes()),
            @"speed": @(download_item->GetCurrentSpeed()),
        } mutableCopy];
        if (source.profile) info[@"profileDirectory"] = source.profile;
        [NSNotificationCenter.defaultCenter postNotificationName:KCDownloadDidUpdateNotification object:owner_ userInfo:info];
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

    // CefContextMenuHandler

    /// What was right-clicked, for the delegate: "linkURL", "imageURL" (a media image's source),
    /// "selectionText", "editable", "pageURL" and the point ("x", "y", view points from the top left).
    static NSDictionary<NSString*, id>* MenuParams(CefRefPtr<CefContextMenuParams> params) {
        NSMutableDictionary<NSString*, id>* info = [NSMutableDictionary dictionary];
        if (NSURL* link = ToNSURL(params->GetLinkUrl())) info[@"linkURL"] = link;
        if (params->GetMediaType() == CM_MEDIATYPE_IMAGE) {
            if (NSURL* image = ToNSURL(params->GetSourceUrl())) info[@"imageURL"] = image;
        }
        if (NSURL* page = ToNSURL(params->GetPageUrl())) info[@"pageURL"] = page;
        info[@"selectionText"] = ToNSString(params->GetSelectionText()) ?: @"";
        info[@"editable"] = @((params->GetTypeFlags() & CM_TYPEFLAG_EDITABLE) != 0);
        info[@"x"] = @(params->GetXCoord());
        info[@"y"] = @(params->GetYCoord());
        return info;
    }

    static void AddMenuEntries(CefRefPtr<CefMenuModel> model, NSArray<NSDictionary<NSString*, id>*>* items) {
        for (NSDictionary<NSString*, id>* item in items) {
            int command = [item[@"id"] intValue];
            if (command == 0) {
                model->AddSeparator();
                continue;
            }
            NSString* title = item[@"title"] ?: @"";
            NSArray* children = item[@"children"];
            if (children.count) {
                CefRefPtr<CefMenuModel> submenu = model->AddSubMenu(MENU_ID_USER_FIRST + command, title.UTF8String);
                AddMenuEntries(submenu, children);
            } else {
                model->AddItem(MENU_ID_USER_FIRST + command, title.UTF8String);
            }
            model->SetEnabled(MENU_ID_USER_FIRST + command, [item[@"enabled"] boolValue]);
        }
    }

    /// Arc's menu (from the delegate) in place of Alloy's, except in editable content, on video,
    /// audio and plugins, and in a plugin's own menu, which keep Chromium's.
    void OnBeforeContextMenu(CefRefPtr<CefBrowser> browser,
                             CefRefPtr<CefFrame> frame,
                             CefRefPtr<CefContextMenuParams> params,
                             CefRefPtr<CefMenuModel> model) override {
        KCBrowser* owner = owner_;
        id<KCBrowserDelegate> delegate = owner.delegate;
        CefContextMenuParams::MediaType media = params->GetMediaType();
        if (params->IsCustomMenu() || (media != CM_MEDIATYPE_NONE && media != CM_MEDIATYPE_IMAGE) ||
            ![delegate respondsToSelector:@selector(browser:contextMenuItemsForParams:)]) {
            return;
        }
        NSArray<NSDictionary<NSString*, id>*>* items = [delegate browser:owner contextMenuItemsForParams:MenuParams(params)];
        if (!items.count) return;
        model->Clear();
        AddMenuEntries(model, items);
    }

    /// The delegate may answer the menu itself (Kite's test hook): it returns the command to run,
    /// -1 to cancel, or nil to let Chromium show the menu.
    static void AppendForTest(CefRefPtr<CefMenuModel> model, NSMutableArray<NSDictionary<NSString*, id>*>* entries) {
        for (size_t i = 0; i < model->GetCount(); i++) {
            if (model->GetTypeAt(i) == MENUITEMTYPE_SEPARATOR) {
                [entries addObject:@{}];
                continue;
            }
            [entries addObject:@{@"id": @(model->GetCommandIdAt(i)),
                                 @"title": ToNSString(model->GetLabelAt(i)) ?: @"",
                                 @"enabled": @(model->IsEnabledAt(i))}];
            if (CefRefPtr<CefMenuModel> submenu = model->GetSubMenuAt(i)) AppendForTest(submenu, entries);
        }
    }

    bool RunContextMenu(CefRefPtr<CefBrowser> browser,
                        CefRefPtr<CefFrame> frame,
                        CefRefPtr<CefContextMenuParams> params,
                        CefRefPtr<CefMenuModel> model,
                        CefRefPtr<CefRunContextMenuCallback> callback) override {
        KCBrowser* owner = owner_;
        id<KCBrowserDelegate> delegate = owner.delegate;
        if (![delegate respondsToSelector:@selector(browser:answerContextMenuForTest:)]) return false;
        NSMutableArray<NSDictionary<NSString*, id>*>* entries = [NSMutableArray array];
        AppendForTest(model, entries);
        NSNumber* pick = [delegate browser:owner answerContextMenuForTest:entries];
        if (!pick) return false;
        if (pick.intValue < 0) callback->Cancel();
        else callback->Continue(pick.intValue, EVENTFLAG_NONE);
        return true;
    }

    bool OnContextMenuCommand(CefRefPtr<CefBrowser> browser,
                              CefRefPtr<CefFrame> frame,
                              CefRefPtr<CefContextMenuParams> params,
                              int command_id,
                              EventFlags event_flags) override {
        if (command_id < MENU_ID_USER_FIRST || command_id > MENU_ID_USER_LAST) return false;
        KCBrowser* owner = owner_;
        id<KCBrowserDelegate> delegate = owner.delegate;
        if ([delegate respondsToSelector:@selector(browser:performContextMenuItem:params:)]) {
            [delegate browser:owner performContextMenuItem:command_id - MENU_ID_USER_FIRST params:MenuParams(params)];
        }
        return true;
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
    /// The view Chromium builds the browser into (`SetAsChild`), which holds Chromium's own view: kept
    /// until the browser closes, so a KCBrowser released early (a page dropped without `close`, or
    /// before Chromium made it) never leaves Chromium with a freed parent.
    NSView* container_;
    /// Ids for getUserMedia prompts, counting down so they never meet Chromium's prompt ids.
    NSInteger media_prompt_id_ = 0;
    CefRefPtr<CefRegistration> devtools_registration_;
    CefRefPtr<CefResourceRequestHandler> requests_;
    IMPLEMENT_REFCOUNTING(KCClient);
};

}  // namespace

// MARK: - KCRequestContext

@implementation KCRequestContext {
    CefRefPtr<CefRequestContext> _context;
    NSString* _downloadKey;
}

+ (instancetype)incognitoContext {
    static NSInteger count = 0;
    KCRequestContext* context = [[self alloc] initPrivate];
    // An empty cache_path makes Chromium keep this profile in memory only.
    CefRequestContextSettings settings;
    context->_context = CefRequestContext::CreateContext(settings, KCAdblockContextHandler());
    context->_downloadKey = [NSString stringWithFormat:@"incognito-%ld", (long)++count];
    [IncognitoContexts() addObject:context];
    return context;
}

- (NSString*)downloadContextKey {
    return _downloadKey;
}

+ (instancetype)contextForProfileDirectory:(NSString*)directory {
    NSMutableDictionary<NSString*, KCRequestContext*>* contexts = ProfileContexts();
    if (KCRequestContext* existing = contexts[directory]) return existing;
    KCRequestContext* context = [[self alloc] initPrivate];
    CefRequestContextSettings settings;
    settings.persist_session_cookies = true;
    // A cache_path inside root_cache_path is a full Chromium profile: Chromium keeps one
    // per folder, with its own extensions, prefs and history.
    CefString(&settings.cache_path) = [KCRootCachePath() stringByAppendingPathComponent:directory].UTF8String;
    context->_context = CefRequestContext::CreateContext(settings, KCAdblockContextHandler());
    // "Default" (an Arc sign-in import's) is the default profile, whose downloads are keyed "".
    context->_downloadKey = [directory isEqualToString:@"Default"] ? @"" : directory;
    contexts[directory] = context;
    return context;
}

- (instancetype)initPrivate {
    return [super init];
}

- (CefRefPtr<CefRequestContext>)cefContext {
    return _context;
}

namespace {
// Counts SetCookie answers; the last one calls back with how many succeeded.
class CookieBatch : public CefSetCookieCallback {
public:
    CookieBatch(NSInteger total, void (^completion)(NSInteger)) : remaining_(total), completion_([completion copy]) {}
    // CEF dropped callbacks it never ran (it shut down first): answer with what did go in.
    ~CookieBatch() override {
        if (remaining_.exchange(0) > 0) Finish();
    }
    void OnComplete(bool success) override {
        if (success) succeeded_++;
        if (remaining_.fetch_sub(1) == 1) Finish();
    }
    void Finish() {
        void (^completion)(NSInteger) = completion_;
        NSInteger succeeded = succeeded_;
        dispatch_async(dispatch_get_main_queue(), ^{ completion(succeeded); });
    }
private:
    std::atomic<NSInteger> remaining_;
    std::atomic<NSInteger> succeeded_{0};
    void (^completion_)(NSInteger);
    IMPLEMENT_REFCOUNTING(CookieBatch);
};

NSString* CookieString(NSDictionary* cookie, NSString* key) {
    id value = cookie[key];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
}  // namespace

- (void)setCookies:(NSArray<NSDictionary<NSString*, id>*>*)cookies completion:(void (^)(NSInteger))completion {
    CefRefPtr<CefCookieManager> manager = _context ? _context->GetCookieManager(nullptr) : nullptr;
    if (!manager || cookies.count == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(0); });
        return;
    }
    CefRefPtr<CookieBatch> batch = new CookieBatch(cookies.count, completion);
    for (NSDictionary* item in cookies) {
        NSURL* url = [item[@"url"] isKindOfClass:NSURL.class] ? item[@"url"] : nil;
        CefCookie cookie;
        CefString(&cookie.name) = CookieString(item, @"name").UTF8String;
        CefString(&cookie.value) = CookieString(item, @"value").UTF8String;
        CefString(&cookie.domain) = CookieString(item, @"domain").UTF8String;
        CefString(&cookie.path) = CookieString(item, @"path").UTF8String;
        cookie.secure = [item[@"secure"] boolValue];
        cookie.httponly = [item[@"httpOnly"] boolValue];
        int64_t expires = [item[@"expires"] longLongValue];
        cookie.has_expires = expires != 0;
        cookie.expires.val = expires;
        cookie.same_site = static_cast<cef_cookie_same_site_t>([item[@"sameSite"] intValue]);
        cookie.priority = static_cast<cef_cookie_priority_t>([item[@"priority"] intValue]);
        // False when it couldn't even be tried (a bad URL): no answer will come, so count it here.
        if (!url || !manager->SetCookie(url.absoluteString.UTF8String, cookie, batch)) batch->OnComplete(false);
    }
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
    BOOL _autoResize;
    NSSize _autoResizeMinSize;
    NSSize _autoResizeMaxSize;
    BOOL _closed;
    /// beginUnloadClose started a close the page hasn't answered yet.
    BOOL _unloadClosing;
    /// The page let that close go ahead and Chromium is closing it already.
    BOOL _closeApproved;
    /// `close` was called.
    BOOL _forceClosed;
    int _nextMessageID;
    std::map<int, void (^)(NSDictionary*, NSString*)>* _pendingDevTools;
    NSInteger _blockedCount;
    /// Network bytes so far (NetworkCountingHandler adds to it on Chromium's IO thread).
    std::atomic<uint64_t> _networkBytes;
    /// Page.addScriptToEvaluateOnNewDocument identifiers to remove when the script changes.
    NSMutableArray<NSString*>* _documentScripts;
    NSUInteger _navigationCount;
    /// The registered document-start script; reloads and same-site links reuse it.
    NSString* _documentScriptSource;
    BOOL _runScriptAtLoadStart;
    /// DevTools calls made before the browser exists; sent ahead of the first navigation.
    NSMutableArray<void (^)(void)>* _queuedDevTools;
    BOOL _attached;
    /// The DevTools window's frontend, while it's open and Kite opened it.
    CefRefPtr<CefBrowser> _devToolsFrontend;
    BOOL _devToolsFrontendLoaded;
    /// Runs in the frontend once it has loaded.
    NSString* _pendingFrontendScript;
}

- (instancetype)initWithURL:(NSURL*)url delegate:(id<KCBrowserDelegate>)delegate {
    return [self initWithURL:url delegate:delegate context:nil];
}

- (instancetype)initWithURL:(NSURL*)url delegate:(id<KCBrowserDelegate>)delegate context:(KCRequestContext*)context {
    if ((self = [self initPopupWithDelegate:delegate])) {
        CefWindowInfo windowInfo;
        windowInfo.SetAsChild((__bridge CefWindowHandle)_view, CefRect(0, 0, 800, 600));
        CefBrowserSettings settings;
        settings.background_color = KCPageBackdropColor;
        // Start empty and load once attached: DevTools calls (dark pages, the ad
        // blocker's document-start script) need the browser before the first navigation.
        _pendingURL = url ?: [NSURL URLWithString:@"about:blank"];
        // Quitting waits for every browser to close: a new one would hold it up for good.
        if (KCRuntimeIsQuitting()) return self;
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
    // Dropped without `close` (no tab took it): close it now, or its renderer keeps running, and
    // playing, with nothing on screen. The client keeps the container view until Chromium is done.
    if (_browser && !_closed && !KCRuntimeIsQuitting()) {
        CefRefPtr<CefBrowser> browser = _browser;
        _browser = nullptr;
        KCAcceptPendingBeforeUnload(browser);
        browser->GetHost()->CloseBrowser(true);
    }
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
    // The dark backdrop covers only the moments before a page draws: a page that sets no background
    // of its own still gets Chromium's white (dark pages darken it as before).
    [self executeDevToolsMethod:@"Emulation.setDefaultBackgroundColorOverride"
                         params:@{@"color": @{@"r": @255, @"g": @255, @"b": @255, @"a": @1}}
                     completion:nil];
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
    if (_autoResize) [self enableAutoResizeWithMinSize:_autoResizeMinSize maxSize:_autoResizeMaxSize];
    if (_forceDark) [self applyForceDark];
    if (_hidden) {
        browser->GetHost()->WasHidden(true);
        [self applyHidden];
    }
    if (_pendingFocus) [self focus];
}

- (void)browserDidClose {
    _browser = nullptr;
    // Nothing answers DevTools calls any more. Answered on a later turn, out of OnBeforeClose.
    NSMutableArray<void (^)(NSDictionary*, NSString*)>* unanswered = [NSMutableArray array];
    for (auto& [messageID, completion] : *_pendingDevTools) [unanswered addObject:completion];
    _pendingDevTools->clear();
    if (unanswered.count) {
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^completion)(NSDictionary*, NSString*) in unanswered) completion(nil, @"closed");
        });
    }
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
- (void)downloadURL:(NSURL *)url { if (_browser) _browser->GetHost()->StartDownload(url.absoluteString.UTF8String); }
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
    if (!_browser) return;
    _browser->GetHost()->WasHidden(hidden);
    [self applyHidden];
}

/// WasHidden only counts for windowless browsers (cef_browser.h). A windowed one goes by its view:
/// Chromium reports a hidden view (or one with a hidden ancestor) as hidden and throttles it, as it does
/// a tab out of the window. So a page still in the window but covered (under the Library) stops drawing.
- (void)applyHidden {
    NSView* browserView = (__bridge NSView*)_browser->GetHost()->GetWindowHandle();
    if (browserView && browserView.hidden != _hidden) browserView.hidden = _hidden;
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

- (void)enableAutoResizeWithMinSize:(NSSize)minSize maxSize:(NSSize)maxSize {
    _autoResize = YES;
    _autoResizeMinSize = minSize;
    _autoResizeMaxSize = maxSize;
    if (!_browser) return;
    _browser->GetHost()->SetAutoResizeEnabled(true, CefSize((int)minSize.width, (int)minSize.height),
                                              CefSize((int)maxSize.width, (int)maxSize.height));
}

- (void)showDevToolsRunningFrontendScript:(NSString*)frontendScript {
    if (!_browser) return;
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    CefWindowInfo windowInfo;
    CefBrowserSettings settings;
    if (_devToolsFrontend && host->HasDevTools()) {
        // Already open: ShowDevTools just brings it forward.
        host->ShowDevTools(windowInfo, nullptr, settings, CefPoint());
        if (!frontendScript) return;
        if (_devToolsFrontendLoaded) [self runFrontendScript:frontendScript];
        else _pendingFrontendScript = frontendScript;
        return;
    }
    _pendingFrontendScript = frontendScript;
    _devToolsFrontendLoaded = NO;
    host->ShowDevTools(windowInfo, new KCDevToolsClient(self), settings, CefPoint());
}

- (void)runFrontendScript:(NSString*)script {
    if (!_devToolsFrontend) return;
    CefRefPtr<CefFrame> frame = _devToolsFrontend->GetMainFrame();
    if (frame) frame->ExecuteJavaScript(script.UTF8String, frame->GetURL(), 0);
}

- (void)devToolsFrontendDidOpen:(CefRefPtr<CefBrowser>)frontend {
    _devToolsFrontend = frontend;
}

- (void)devToolsFrontendDidLoad {
    _devToolsFrontendLoaded = YES;
    NSString* script = _pendingFrontendScript;
    _pendingFrontendScript = nil;
    if (script) [self runFrontendScript:script];
}

- (void)devToolsFrontendDidClose {
    _devToolsFrontend = nullptr;
    _devToolsFrontendLoaded = NO;
    _pendingFrontendScript = nil;
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

- (void)copySelection {
    if (!_browser) return;
    CefRefPtr<CefFrame> frame = _browser->GetFocusedFrame();
    if (!frame) frame = _browser->GetMainFrame();
    if (frame) frame->Copy();
}

- (void)inspectElementAtPoint:(NSPoint)point {
    if (!_browser) return;
    CefWindowInfo windowInfo;
    CefBrowserSettings settings;
    CefPoint at((int)point.x, (int)point.y);
    CefRefPtr<CefBrowserHost> host = _browser->GetHost();
    if (_devToolsFrontend && host->HasDevTools()) {
        host->ShowDevTools(windowInfo, nullptr, settings, at);
        return;
    }
    _pendingFrontendScript = nil;
    _devToolsFrontendLoaded = NO;
    host->ShowDevTools(windowInfo, new KCDevToolsClient(self), settings, at);
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

static cef_content_setting_values_t KCContentSettingValue(KCSitePermissionValue value) {
    switch (value) {
        case KCSitePermissionValueAllow: return CEF_CONTENT_SETTING_VALUE_ALLOW;
        case KCSitePermissionValueBlock: return CEF_CONTENT_SETTING_VALUE_BLOCK;
        case KCSitePermissionValueAsk: return CEF_CONTENT_SETTING_VALUE_ASK;
        case KCSitePermissionValueDefault: return CEF_CONTENT_SETTING_VALUE_DEFAULT;
    }
    return CEF_CONTENT_SETTING_VALUE_DEFAULT;
}

// Empty URLs read and write the content type's default (CefRequestContext).
- (KCSitePermissionValue)defaultSitePermission:(KCSitePermission)permission {
    if (!_browser) return KCSitePermissionValueDefault;
    CefRefPtr<CefRequestContext> context = _browser->GetHost()->GetRequestContext();
    if (!context) return KCSitePermissionValueDefault;
    switch (context->GetContentSetting(CefString(), CefString(), KCContentSettingType(permission))) {
        case CEF_CONTENT_SETTING_VALUE_ALLOW: return KCSitePermissionValueAllow;
        case CEF_CONTENT_SETTING_VALUE_BLOCK: return KCSitePermissionValueBlock;
        case CEF_CONTENT_SETTING_VALUE_ASK: return KCSitePermissionValueAsk;
        default: return KCSitePermissionValueDefault;
    }
}

- (void)setDefaultSitePermission:(KCSitePermission)permission value:(KCSitePermissionValue)value {
    if (!_browser) return;
    CefRefPtr<CefRequestContext> context = _browser->GetHost()->GetRequestContext();
    if (!context) return;
    context->SetContentSetting(CefString(), CefString(), KCContentSettingType(permission), KCContentSettingValue(value));
}

static id KCFoundationValue(CefRefPtr<CefValue> value) {
    if (!value) return nil;
    switch (value->GetType()) {
        case VTYPE_NULL: return NSNull.null;
        case VTYPE_BOOL: return @(value->GetBool());
        case VTYPE_INT: return @(value->GetInt());
        case VTYPE_DOUBLE: return @(value->GetDouble());
        case VTYPE_STRING: return [NSString stringWithUTF8String:value->GetString().ToString().c_str()];
        case VTYPE_DICTIONARY: {
            CefRefPtr<CefDictionaryValue> dictionary = value->GetDictionary();
            CefDictionaryValue::KeyList keys;
            dictionary->GetKeys(keys);
            NSMutableDictionary* result = [NSMutableDictionary dictionaryWithCapacity:keys.size()];
            for (const CefString& key : keys) {
                id item = KCFoundationValue(dictionary->GetValue(key));
                if (item) result[[NSString stringWithUTF8String:key.ToString().c_str()]] = item;
            }
            return result;
        }
        case VTYPE_LIST: {
            CefRefPtr<CefListValue> list = value->GetList();
            NSMutableArray* result = [NSMutableArray arrayWithCapacity:list->GetSize()];
            for (size_t i = 0; i < list->GetSize(); i++) {
                id item = KCFoundationValue(list->GetValue(i));
                [result addObject:item ?: NSNull.null];
            }
            return result;
        }
        default: return nil;
    }
}

static CefRefPtr<CefValue> KCCefValue(id object) {
    CefRefPtr<CefValue> value = CefValue::Create();
    if ([object isKindOfClass:NSNumber.class]) {
        NSNumber* number = object;
        if (CFGetTypeID((__bridge CFTypeRef)number) == CFBooleanGetTypeID()) {
            value->SetBool(number.boolValue);
        } else if (strcmp(number.objCType, @encode(double)) == 0 || strcmp(number.objCType, @encode(float)) == 0) {
            value->SetDouble(number.doubleValue);
        } else {
            value->SetInt(number.intValue);
        }
    } else if ([object isKindOfClass:NSString.class]) {
        value->SetString(((NSString*)object).UTF8String);
    } else if ([object isKindOfClass:NSDictionary.class]) {
        CefRefPtr<CefDictionaryValue> dictionary = CefDictionaryValue::Create();
        [(NSDictionary*)object enumerateKeysAndObjectsUsingBlock:^(id key, id item, BOOL*) {
            if ([key isKindOfClass:NSString.class]) dictionary->SetValue(((NSString*)key).UTF8String, KCCefValue(item));
        }];
        value->SetDictionary(dictionary);
    } else if ([object isKindOfClass:NSArray.class]) {
        CefRefPtr<CefListValue> list = CefListValue::Create();
        NSArray* array = object;
        for (NSUInteger i = 0; i < array.count; i++) list->SetValue(i, KCCefValue(array[i]));
        value->SetList(list);
    } else {
        value->SetNull();
    }
    return value;
}

- (id)preferenceNamed:(NSString*)name {
    if (!_browser) return nil;
    CefRefPtr<CefRequestContext> context = _browser->GetHost()->GetRequestContext();
    if (!context || !context->HasPreference(name.UTF8String)) return nil;
    return KCFoundationValue(context->GetPreference(name.UTF8String));
}

- (BOOL)setPreferenceNamed:(NSString*)name value:(id)value {
    if (!_browser) return NO;
    CefRefPtr<CefRequestContext> context = _browser->GetHost()->GetRequestContext();
    if (!context || !context->CanSetPreference(name.UTF8String)) return NO;
    CefString error;
    bool ok = context->SetPreference(name.UTF8String, value ? KCCefValue(value) : nullptr, error);
    if (!ok) NSLog(@"Kite: couldn't set %@: %s", name, error.ToString().c_str());
    return ok;
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
    if (_closed && _attached) return completion(nil, @"closed");
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

- (uint64_t)networkBytes {
    return _networkBytes.load(std::memory_order_relaxed);
}

- (void)addNetworkBytes:(uint64_t)bytes {
    _networkBytes.fetch_add(bytes, std::memory_order_relaxed);
}

- (NSInteger)blockedCount {
    return _blockedCount;
}

- (void)noteBlockedRequests:(NSInteger)count {
    // The ad blocker already batches these per burst (KCAdblock.mm).
    _blockedCount += count;
    if ([self.delegate respondsToSelector:@selector(browser:blockedCountDidChange:)]) {
        [self.delegate browser:self blockedCountDidChange:_blockedCount];
    }
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
    if ([_delegate respondsToSelector:@selector(browserMainFrameDidStartLoading:)]) [_delegate browserMainFrameDidStartLoading:self];
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

- (BOOL)beginUnloadClose {
    if (!_browser || _closed) return NO;
    _unloadClosing = YES;
    // Not forced: Chromium runs beforeunload (OnBeforeUnloadDialog) and calls DoClose only if the
    // page lets go. Without a handler that's right away, inside this call. A second call while one
    // is pending is ignored by CEF.
    _browser->GetHost()->CloseBrowser(false);
    return YES;
}

- (void)stopScriptOfClosingPage {
    if (!_browser) return;
    _browser->GetHost()->ExecuteDevToolsMethod(_nextMessageID++, "Runtime.terminateExecution", nullptr);
}

- (void)cancelUnloadClose {
    if (!_closeApproved) _unloadClosing = NO;
}

- (void)pageDidLetGo {
    if (!_unloadClosing || _closed) return;
    // Closed by us: OnBeforeClose mustn't report the page closing itself.
    _closed = YES;
    _closeApproved = YES;
    // Out of DoClose before Kite tears the tab down.
    dispatch_async(dispatch_get_main_queue(), ^{
        if ([self->_delegate respondsToSelector:@selector(browserDidLetGo:)]) [self->_delegate browserDidLetGo:self];
    });
}

- (BOOL)isForceClosing {
    return _forceClosed && !_closeApproved;
}

- (void)close {
    _closed = YES;
    _forceClosed = YES;
    _delegate = nil;
    if (_browser && !_closeApproved) {
        KCAcceptPendingBeforeUnload(_browser);
        _browser->GetHost()->CloseBrowser(true);
    }
    // Calls waiting for a browser that may never come (a cancelled popup) answer on a later turn;
    // until then they hold this object.
    if (!_attached && _queuedDevTools.count) {
        NSArray<void (^)(void)>* queued = [_queuedDevTools copy];
        [_queuedDevTools removeAllObjects];
        dispatch_async(dispatch_get_main_queue(), ^{
            for (void (^call)(void) in queued) call();
        });
    }
}

+ (NSURL* _Nullable (^)(NSString* _Nullable, BOOL*))downloadFolderProvider {
    return gDownloadFolderProvider;
}

+ (void)setDownloadFolderProvider:(NSURL* _Nullable (^)(NSString* _Nullable, BOOL*))provider {
    gDownloadFolderProvider = [provider copy];
}

+ (BOOL)cancelDownloadWithID:(NSInteger)downloadID contextKey:(NSString*)contextKey {
    for (LiveDownload& download : LiveDownloads()) {
        if (download.id != (uint32_t)downloadID || ![download.source.key isEqualToString:contextKey]) continue;
        if (!download.callback) return NO;
        download.callback->Cancel();
        return YES;
    }
    return NO;
}

+ (NSInteger)endDownloadsForContextKey:(NSString*)contextKey {
    [EndedDownloadContexts() addObject:contextKey];
    // Copy: a cancel can call back into OnDownloadUpdated, which edits the list.
    std::vector<LiveDownload> ending;
    std::vector<LiveDownload>& downloads = LiveDownloads();
    for (auto it = downloads.begin(); it != downloads.end();) {
        if ([it->source.key isEqualToString:contextKey]) {
            ending.push_back(*it);
            it = downloads.erase(it);
        } else {
            ++it;
        }
    }
    for (LiveDownload& download : ending) if (download.callback) download.callback->Cancel();
    return (NSInteger)ending.size();
}

+ (NSInteger)liveDownloadCountForContextKey:(NSString*)contextKey {
    NSInteger count = 0;
    for (const LiveDownload& download : LiveDownloads()) count += [download.source.key isEqualToString:contextKey];
    return count;
}

@end

/// Drops the downloads Kite follows, and their CEF references, before CefShutdown.
void KCClearLiveDownloads() {
    LiveDownloads().clear();
}

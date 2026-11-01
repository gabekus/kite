// Objective-C face of Kite's Chromium (CEF) engine. Everything C++ stays in the
// .mm files so Swift only ever sees these classes.

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// NSApplication subclass CEF requires on macOS (it implements CefAppProtocol).
/// Kite always runs as this class, whichever engine is active.
@interface KCApplication : NSApplication
/// Called from -terminate: so the app can save state before browsers close.
@property (nonatomic, copy, nullable) void (^willTerminate)(void);
@end

@interface KCRuntimeSettings : NSObject
/// Profile directory (cookies, local storage, cache).
@property (nonatomic, copy) NSString *profilePath;
/// 0 disables the Chrome DevTools Protocol port. When set, any local process can
/// drive the browser, so keep it off unless you're using it.
@property (nonatomic) int remoteDebuggingPort;
/// Chromium's --use-mock-keychain: cookies and saved passwords are encrypted with
/// a fixed key instead of one from the login keychain, so there's no keychain
/// prompt. Only for throwaway test profiles, never for real browsing data.
@property (nonatomic) BOOL useMockKeychain;
/// Extra Chromium switches, e.g. "--disable-backgrounding-occluded-windows".
@property (nonatomic, copy) NSArray<NSString *> *extraSwitches;
/// Unpacked extensions loaded at launch (Kite's helper), merged into any
/// --load-extension switch Kite was started with.
@property (nonatomic, copy) NSArray<NSString *> *extensionDirectories;
@end

@interface KCRuntime : NSObject
/// True when running from a Kite.app bundle that contains the Chromium framework.
@property (class, nonatomic, readonly) BOOL isAvailable;
@property (class, nonatomic, readonly) BOOL isInitialized;
+ (BOOL)initializeWithSettings:(KCRuntimeSettings *)settings;
/// Chromium's Energy Saver, which drops pages to 30fps on battery below 20%.
/// Off by default so pages run at the display's full rate. Can be set before
/// or after initializing.
@property (class, nonatomic) BOOL energySaverEnabled;
/// Runs the Cocoa event loop with CEF integrated. Returns after quit.
+ (void)runMessageLoop;
/// Closes every browser, then ends the message loop.
+ (void)closeAllBrowsersAndQuit;
+ (void)shutdown;
@end

/// Kite's ad blocker on Chromium's network thread. A no-op when Kite is built
/// without it (scripts/build-adblock.sh).
@interface KCRuntime (Adblock)
@property (class, nonatomic, readonly) BOOL supportsAdblock;
/// `engine` is a `KAEngine *`. Chromium checks requests on another thread, so it
/// holds `owner` (which frees the engine) until no request still uses it. Nil stops blocking.
+ (void)setAdblockEngine:(nullable void *)engine owner:(nullable id)owner;
/// Global on/off plus the sites the shield turned off (lowercase hosts).
+ (void)setAdblockEnabled:(BOOL)enabled allowedHosts:(NSSet<NSString *> *)hosts;
@end

/// Posted on the main thread as a download progresses. `object` is the KCBrowser; userInfo has
/// id, url, path, state (in-progress, complete, canceled, interrupted), receivedBytes, totalBytes,
/// speed (bytes per second).
extern NSString * const KCDownloadDidUpdateNotification;

/// Posted on the main thread when Chromium opened a page outside Kite's tabs (an
/// extension's welcome page, chrome.windows.create). userInfo["url"] is the NSURL;
/// Chromium's own window for it is never shown.
extern NSString * const KCRuntimeOpenURLNotification;

/// Posted on the main thread when Chrome's extension install dialog closes, whether
/// the extension was added or not.
extern NSString * const KCExtensionInstallDialogDidCloseNotification;

@interface KCRuntime (ExtensionWindows)
/// Where Chrome's install dialog hangs: the web area of a Kite window, in that
/// window's coordinates (empty for the whole window). The dialog is centred on it,
/// just below its top edge.
@property (class, nonatomic, copy, nullable) NSRect (^extensionDialogAnchor)(NSWindow *window);
@end

@class KCBrowser;

/// Per-site permissions Chromium stores as content settings (Site Controls).
typedef NS_ENUM(NSInteger, KCSitePermission) {
    KCSitePermissionCamera,
    KCSitePermissionMicrophone,
    KCSitePermissionLocation,
    KCSitePermissionNotifications,
};

/// A content setting's value; Default means nothing is set for the site (it has to ask).
typedef NS_ENUM(NSInteger, KCSitePermissionValue) {
    KCSitePermissionValueDefault,
    KCSitePermissionValueAllow,
    KCSitePermissionValueBlock,
    KCSitePermissionValueAsk,
};

/// A Chromium profile for a set of browsers. `incognitoContext` keeps cookies,
/// cache and storage in memory only; they vanish when the last browser using it closes.
NS_SWIFT_UI_ACTOR
@interface KCRequestContext : NSObject
+ (instancetype)incognitoContext NS_SWIFT_NAME(incognito());
- (instancetype)init NS_UNAVAILABLE;
@end

// CEF's UI thread is the main thread, so Swift can treat these as main-actor types.
NS_SWIFT_UI_ACTOR
@protocol KCBrowserDelegate <NSObject>
- (void)browser:(KCBrowser *)browser titleDidChange:(NSString *)title;
- (void)browser:(KCBrowser *)browser addressDidChange:(NSURL *)url;
- (void)browser:(KCBrowser *)browser faviconDidChange:(nullable NSURL *)url;
- (void)browser:(KCBrowser *)browser progressDidChange:(double)progress;
- (void)browserLoadingStateDidChange:(KCBrowser *)browser;
- (void)browser:(KCBrowser *)browser mediaAccessDidChange:(BOOL)inUse;
/// ⌘-click and middle-click.
- (void)browser:(KCBrowser *)browser openURLInNewTab:(NSURL *)url foreground:(BOOL)foreground;
/// window.open / target=_blank. The popup keeps window.opener, so OAuth works.
- (void)browser:(KCBrowser *)browser didCreatePopup:(KCBrowser *)popup url:(nullable NSURL *)url;
/// The page called window.close().
- (void)browserDidRequestClose:(KCBrowser *)browser;
@optional
/// A link the user clicked to `url` (in the page, target=_blank, or ⇧-click when `shift`): YES means the
/// delegate opens it in Arc's Peek card, and the click goes no further.
- (BOOL)browser:(KCBrowser *)browser opensLinkInPeek:(NSURL *)url shift:(BOOL)shift;
/// Requests blocked since the page started loading.
- (void)browser:(KCBrowser *)browser blockedCountDidChange:(NSInteger)count;
/// Asked before each main-frame navigation; the script runs at document start
/// in every new document until the next navigation.
- (nullable NSString *)browser:(KCBrowser *)browser documentStartScriptForURL:(NSURL *)url;
/// Find-in-page results; `activeMatch` is 1-based. Arrives several times per search.
- (void)browser:(KCBrowser *)browser findResultCount:(int)count activeMatch:(int)activeMatch final:(BOOL)final;
/// The page's renderer crashed or was killed; `code` is its exit code (11 for a segfault).
- (void)browser:(KCBrowser *)browser renderProcessDidTerminateWithCode:(int)code;
/// The status text changed. While the pointer is over a link it's the link's URL; nil when it clears.
- (void)browser:(KCBrowser *)browser statusMessageDidChange:(nullable NSString *)message;
/// YES for a store install's extension package (.crx): it's saved to a temporary
/// folder for Chromium's installer and isn't reported as a download.
- (BOOL)browser:(KCBrowser *)browser
    isExtensionPackageWithMIMEType:(NSString *)mimeType
                     suggestedName:(NSString *)suggestedName
                               url:(nullable NSURL *)url;
@end

/// One Chromium browser (one tab), hosted in `view`.
NS_SWIFT_UI_ACTOR
@interface KCBrowser : NSObject
- (instancetype)initWithURL:(nullable NSURL *)url delegate:(id<KCBrowserDelegate>)delegate;
/// `context` nil means the app's persistent profile.
- (instancetype)initWithURL:(nullable NSURL *)url
                   delegate:(id<KCBrowserDelegate>)delegate
                    context:(nullable KCRequestContext *)context;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSView *view;
@property (nonatomic, weak, nullable) id<KCBrowserDelegate> delegate;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
/// 1.0 = 100%.
@property (nonatomic) double zoomFactor;
/// Mutes the tab's audio in the browser (Chromium's tab mute); the page isn't told.
@property (nonatomic) BOOL audioMuted;
/// Requests the ad blocker stopped since the page started loading.
@property (nonatomic, readonly) NSInteger blockedCount;
/// The pid of the renderer showing the main frame, as the renderer last reported it; 0 when
/// unknown (no page has run yet, or the renderer died).
@property (nonatomic, readonly) int renderProcessIdentifier;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)focus;
/// Kite's own UI has the keyboard (the command bar): tells Chromium the page lost it, and
/// refuses the page's own focus requests (on navigation, or once a new page starts up)
/// until `focus` or `allowFocus`.
- (void)blur;
- (void)allowFocus;
@property (nonatomic, readonly) BOOL focusBlocked;
/// Tells Chromium the tab is offscreen so it throttles rendering and timers.
- (void)setHidden:(BOOL)hidden;
/// Opens (or brings forward) Chrome DevTools in its own window, then runs `frontendScript` in the DevTools
/// frontend page: on its load event when it opens, right away when it's already open.
- (void)showDevToolsRunningFrontendScript:(nullable NSString *)frontendScript;
/// `findNext` continues through the same search; results arrive on the delegate.
- (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding;
/// Chromium's print dialog for the page.
- (void)print;
/// Chromium's auto dark mode for this tab's pages.
- (void)setForceDark:(BOOL)enabled;
/// The permission stored for `url`'s site in this browser's profile; Default before the
/// browser exists.
- (KCSitePermissionValue)sitePermission:(KCSitePermission)permission forURL:(NSURL *)url;
/// Stores a permission for `url`'s site in this browser's profile (Default clears it).
- (void)setSitePermission:(KCSitePermission)permission value:(KCSitePermissionValue)value forURL:(NSURL *)url;
/// Runs JavaScript in the main frame via the DevTools protocol. `result` is the
/// JSON-decoded return value, or nil on error.
- (void)evaluateJavaScript:(NSString *)script completion:(void (NS_SWIFT_UI_ACTOR ^)(id _Nullable result))completion;
/// Calls any DevTools protocol method; `result` is the decoded JSON result.
- (void)executeDevToolsMethod:(NSString *)method
                       params:(nullable NSDictionary<NSString *, id> *)params
                   completion:(nullable void (NS_SWIFT_UI_ACTOR ^)(NSDictionary * _Nullable result))completion;
/// DevTools protocol events (after a domain's `enable`), on the main thread. Nil to stop.
@property (nonatomic, copy, nullable) void (NS_SWIFT_UI_ACTOR ^devToolsEventHandler)(NSString *method, NSDictionary *params);
/// The same events for Kite's own page features (such as Google's Add to Kite
/// buttons), kept apart from devToolsEventHandler, which automation takes over.
@property (nonatomic, copy, nullable) void (NS_SWIFT_UI_ACTOR ^pageFeatureEventHandler)(NSString *method, NSDictionary *params);
/// Like executeDevToolsMethod, but a failure comes back as the protocol's error
/// message. `error` is "not-ready" until the browser exists.
- (void)callDevToolsMethod:(NSString *)method
                    params:(nullable NSDictionary<NSString *, id> *)params
                completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary * _Nullable result, NSString * _Nullable error))completion;
/// Messages for DevTools sessions attached with Target.attachToTarget (flatten): each
/// carries its "sessionId". Kite's tabs bridge uses them to reach extension service
/// workers. Set, they no longer reach the result and event callbacks above.
@property (nonatomic, copy, nullable) void (NS_SWIFT_UI_ACTOR ^sessionMessageHandler)(NSDictionary *message);
/// Sends a raw DevTools message, such as one to an attached session.
- (void)sendDevToolsMessage:(NSDictionary<NSString *, id> *)message;
- (void)close;
/// Cancels a live download by the id in KCDownloadDidUpdateNotification. Returns NO when
/// Chromium no longer has it.
+ (BOOL)cancelDownloadWithID:(NSInteger)downloadID;
@end

NS_ASSUME_NONNULL_END

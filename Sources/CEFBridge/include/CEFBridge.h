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
/// id, url, path, state (in-progress, complete, canceled, interrupted), receivedBytes, totalBytes.
extern NSString * const KCDownloadDidUpdateNotification;

@class KCBrowser;

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
/// Requests blocked since the page started loading.
- (void)browser:(KCBrowser *)browser blockedCountDidChange:(NSInteger)count;
/// Asked before each main-frame navigation; the script runs at document start
/// in every new document until the next navigation.
- (nullable NSString *)browser:(KCBrowser *)browser documentStartScriptForURL:(NSURL *)url;
/// Find-in-page results; `activeMatch` is 1-based. Arrives several times per search.
- (void)browser:(KCBrowser *)browser findResultCount:(int)count activeMatch:(int)activeMatch final:(BOOL)final;
/// The page's renderer crashed or was killed; `code` is its exit code (11 for a segfault).
- (void)browser:(KCBrowser *)browser renderProcessDidTerminateWithCode:(int)code;
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
/// Requests the ad blocker stopped since the page started loading.
@property (nonatomic, readonly) NSInteger blockedCount;

- (void)loadURL:(NSURL *)url;
- (void)goBack;
- (void)goForward;
- (void)reload;
- (void)reloadIgnoringCache;
- (void)stopLoading;
- (void)focus;
/// Tells Chromium the tab is offscreen so it throttles rendering and timers.
- (void)setHidden:(BOOL)hidden;
/// Opens Chrome DevTools in its own window.
- (void)showDevTools;
/// `findNext` continues through the same search; results arrive on the delegate.
- (void)find:(NSString *)text forward:(BOOL)forward findNext:(BOOL)findNext;
- (void)stopFinding;
/// Chromium's print dialog for the page.
- (void)print;
/// Chromium's auto dark mode for this tab's pages.
- (void)setForceDark:(BOOL)enabled;
/// Runs JavaScript in the main frame via the DevTools protocol. `result` is the
/// JSON-decoded return value, or nil on error.
- (void)evaluateJavaScript:(NSString *)script completion:(void (NS_SWIFT_UI_ACTOR ^)(id _Nullable result))completion;
/// Calls any DevTools protocol method; `result` is the decoded JSON result.
- (void)executeDevToolsMethod:(NSString *)method
                       params:(nullable NSDictionary<NSString *, id> *)params
                   completion:(nullable void (NS_SWIFT_UI_ACTOR ^)(NSDictionary * _Nullable result))completion;
/// DevTools protocol events (after a domain's `enable`), on the main thread. Nil to stop.
@property (nonatomic, copy, nullable) void (NS_SWIFT_UI_ACTOR ^devToolsEventHandler)(NSString *method, NSDictionary *params);
/// Like executeDevToolsMethod, but a failure comes back as the protocol's error
/// message. `error` is "not-ready" until the browser exists.
- (void)callDevToolsMethod:(NSString *)method
                    params:(nullable NSDictionary<NSString *, id> *)params
                completion:(void (NS_SWIFT_UI_ACTOR ^)(NSDictionary * _Nullable result, NSString * _Nullable error))completion;
- (void)close;
@end

NS_ASSUME_NONNULL_END

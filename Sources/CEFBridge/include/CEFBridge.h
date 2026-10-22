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
/// Runs the Cocoa event loop with CEF integrated. Returns after quit.
+ (void)runMessageLoop;
/// Closes every browser, then ends the message loop.
+ (void)closeAllBrowsersAndQuit;
+ (void)shutdown;
@end

/// Posted on the main thread as a download progresses. `object` is the KCBrowser; userInfo has
/// id, url, path, state (in-progress, complete, canceled, interrupted), receivedBytes, totalBytes.
extern NSString * const KCDownloadDidUpdateNotification;

@class KCBrowser;

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
/// Find-in-page results; `activeMatch` is 1-based. Arrives several times per search.
- (void)browser:(KCBrowser *)browser findResultCount:(int)count activeMatch:(int)activeMatch final:(BOOL)final;
@end

/// One Chromium browser (one tab), hosted in `view`.
NS_SWIFT_UI_ACTOR
@interface KCBrowser : NSObject
- (instancetype)initWithURL:(nullable NSURL *)url delegate:(id<KCBrowserDelegate>)delegate;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) NSView *view;
@property (nonatomic, weak, nullable) id<KCBrowserDelegate> delegate;
@property (nonatomic, readonly) BOOL isLoading;
@property (nonatomic, readonly) BOOL canGoBack;
@property (nonatomic, readonly) BOOL canGoForward;
/// 1.0 = 100%.
@property (nonatomic) double zoomFactor;

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

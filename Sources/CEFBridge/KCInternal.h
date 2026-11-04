#pragma once

#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"

#import "CEFBridge.h"

// Live-browser bookkeeping shared by KCRuntime and KCBrowser, so quitting can
// wait for every browser to finish closing.
void KCRegisterBrowser(CefRefPtr<CefBrowser> browser);
void KCUnregisterBrowser(CefRefPtr<CefBrowser> browser);
bool KCRuntimeIsQuitting();
/// Answers Leave to a "Leave site?" dialog still waiting in `browser` (every browser when null), so a
/// forced close can finish: Chromium keeps the page until its beforeunload hears back.
void KCAcceptPendingBeforeUnload(CefRefPtr<CefBrowser> browser);
/// Drops the record of those dialogs before CefShutdown.
void KCForgetPendingBeforeUnload();
/// CefSettings.root_cache_path: every profile folder sits directly inside it.
NSString* KCRootCachePath();

// Browsers Chromium creates itself (KCDefaultClient.mm). The app's CefApp gives them
// a client that sends their pages to Kite tabs and closes them.
CefRefPtr<CefApp> KCMakeApp();
/// While any exist, Chrome-style browser windows are theirs and stay off screen.
bool KCHasChromiumCreatedBrowsers();
// Chrome's extension windows: install dialog, "added" bubble (KCExtensionWindows.mm).
void KCInstallExtensionWindowHooks();

/// Drops the downloads KCBrowser follows (KCBrowser.mm), and the CEF references they hold.
/// KCRuntime calls it before CefShutdown.
void KCClearLiveDownloads();

// The ad blocker (KCAdblock.mm). Both return null when Kite is built without it.
CefRefPtr<CefResourceRequestHandler> KCAdblockRequestHandler(KCBrowser* owner);
/// The context every tab uses, so requests no tab makes are checked too.
CefRefPtr<CefRequestContext> KCAdblockRequestContext();
/// The same checks for another context, such as an incognito window's.
CefRefPtr<CefRequestContextHandler> KCAdblockContextHandler();

@interface KCBrowser (Internal)
/// Called on the main thread with the requests blocked since the last call.
- (void)noteBlockedRequests:(NSInteger)count;
@end

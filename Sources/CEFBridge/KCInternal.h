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

// Browsers Chromium creates itself (KCDefaultClient.mm). The app's CefApp gives them
// a client that sends their pages to Kite tabs and closes them.
CefRefPtr<CefApp> KCMakeApp();
/// While any exist, Chrome-style browser windows are theirs and stay off screen.
bool KCHasChromiumCreatedBrowsers();
// Chrome's extension windows: install dialog, "added" bubble (KCExtensionWindows.mm).
void KCInstallExtensionWindowHooks();

// The ad blocker (KCAdblock.mm). Both return null when Kite is built without it.
CefRefPtr<CefResourceRequestHandler> KCAdblockRequestHandler(KCBrowser* owner);
/// The context every tab uses, so requests no tab makes are checked too.
CefRefPtr<CefRequestContext> KCAdblockRequestContext();
/// The same checks for another context, such as an incognito window's.
CefRefPtr<CefRequestContextHandler> KCAdblockContextHandler();

@interface KCBrowser (Internal)
/// Called on the main thread for each blocked request.
- (void)noteBlockedRequest;
@end

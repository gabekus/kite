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

// SPIKE (KCDefaultClient.mm): the browser-process CefApp, whose default client
// catches browsers Chromium creates itself.
CefRefPtr<CefApp> KCMakeApp();

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

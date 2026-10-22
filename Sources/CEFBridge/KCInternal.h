#pragma once

#include "include/cef_browser.h"

// Live-browser bookkeeping shared by KCRuntime and KCBrowser, so quitting can
// wait for every browser to finish closing.
void KCRegisterBrowser(CefRefPtr<CefBrowser> browser);
void KCUnregisterBrowser(CefRefPtr<CefBrowser> browser);
bool KCRuntimeIsQuitting();

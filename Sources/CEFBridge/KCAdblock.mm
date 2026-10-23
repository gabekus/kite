#import "CEFBridge.h"
#import "KCInternal.h"

#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <string>

#include "include/cef_parser.h"
#include "include/cef_request_context.h"
#include "include/cef_request_context_handler.h"
#include "include/cef_resource_request_handler.h"
#include "include/cef_stream.h"
#include "include/wrapper/cef_stream_resource_handler.h"

#if __has_include(<kite_adblock.h>)
#include <kite_adblock.h>
#define KC_HAS_ADBLOCK 1
#endif

// Ad blocking on Chromium's network (IO) thread. Swift owns the engine and swaps
// it in whole when lists update; requests already in flight finish on the old one.

namespace {

#if KC_HAS_ADBLOCK

struct AdblockState {
    std::mutex lock;
    std::shared_ptr<KAEngine> engine;
    bool enabled = true;
    std::set<std::string> allowedHosts;
    /// `$redirect` bodies chosen in OnBeforeResourceLoad, served by GetResourceHandler.
    std::map<uint64_t, std::string> redirects;
};

AdblockState& State() {
    static AdblockState* state = new AdblockState();
    return *state;
}

/// webRequest type names, which adblock-rust's `$script`, `$image`… options use.
const char* RequestType(cef_resource_type_t type) {
    switch (type) {
        case RT_MAIN_FRAME:
        case RT_NAVIGATION_PRELOAD_MAIN_FRAME: return "document";
        case RT_SUB_FRAME:
        case RT_NAVIGATION_PRELOAD_SUB_FRAME: return "subdocument";
        case RT_STYLESHEET: return "stylesheet";
        case RT_SCRIPT:
        case RT_WORKER:
        case RT_SHARED_WORKER:
        case RT_SERVICE_WORKER: return "script";
        case RT_IMAGE:
        case RT_FAVICON: return "image";
        case RT_FONT_RESOURCE: return "font";
        case RT_OBJECT:
        case RT_PLUGIN_RESOURCE: return "object";
        case RT_MEDIA: return "media";
        case RT_XHR: return "xmlhttprequest";
        case RT_PING: return "ping";
        case RT_CSP_REPORT: return "csp";
        default: return "other";
    }
}

bool IsWebURL(const std::string& url) {
    return url.rfind("https:", 0) == 0 || url.rfind("http:", 0) == 0 || url.rfind("wss:", 0) == 0 || url.rfind("ws:", 0) == 0;
}

std::string LowercaseHost(const std::string& url) {
    CefURLParts parts;
    if (!CefParseURL(url, parts)) return "";
    std::string host = CefString(&parts.host).ToString();
    for (auto& c : host) c = (char)tolower((unsigned char)c);
    return host;
}

/// Blocks, redirects or strips tracking parameters. One handler per tab, plus one
/// without an owner for requests no tab makes (service workers, prefetches).
class AdblockHandler : public CefResourceRequestHandler {
 public:
    explicit AdblockHandler(KCBrowser* owner) : owner_(owner) {}

    ReturnValue OnBeforeResourceLoad(CefRefPtr<CefBrowser> browser,
                                     CefRefPtr<CefFrame> frame,
                                     CefRefPtr<CefRequest> request,
                                     CefRefPtr<CefCallback> callback) override {
        cef_resource_type_t type = request->GetResourceType();
        // Pages themselves always load; the shield can turn blocking off for them.
        if (type == RT_MAIN_FRAME || type == RT_NAVIGATION_PRELOAD_MAIN_FRAME) return RV_CONTINUE;
        std::string url = request->GetURL().ToString();
        if (!IsWebURL(url)) return RV_CONTINUE;

        CefRefPtr<CefFrame> top = browser ? browser->GetMainFrame() : nullptr;
        std::string page = top ? top->GetURL().ToString() : request->GetReferrerURL().ToString();
        if (!IsWebURL(page)) return RV_CONTINUE;
        bool subdocument = type == RT_SUB_FRAME || type == RT_NAVIGATION_PRELOAD_SUB_FRAME;
        std::string source = (frame && !subdocument) ? frame->GetURL().ToString() : page;
        if (!IsWebURL(source)) source = page;

        std::shared_ptr<KAEngine> engine;
        {
            AdblockState& state = State();
            std::lock_guard<std::mutex> guard(state.lock);
            if (!state.enabled || !state.engine) return RV_CONTINUE;
            if (state.allowedHosts.count(LowercaseHost(page))) return RV_CONTINUE;
            engine = state.engine;
        }

        KACheckResult result = ka_engine_check(engine.get(), url.c_str(), source.c_str(), RequestType(type));
        ReturnValue verdict = RV_CONTINUE;
        if (result.blocked && result.redirect) {
            AdblockState& state = State();
            std::lock_guard<std::mutex> guard(state.lock);
            state.redirects[request->GetIdentifier()] = result.redirect;
            NoteBlocked();
        } else if (result.blocked) {
            verdict = RV_CANCEL;
            NoteBlocked();
        } else if (result.rewritten_url) {
            request->SetURL(result.rewritten_url);
        }
        ka_check_result_free(&result);
        return verdict;
    }

    CefRefPtr<CefResourceHandler> GetResourceHandler(CefRefPtr<CefBrowser> browser,
                                                     CefRefPtr<CefFrame> frame,
                                                     CefRefPtr<CefRequest> request) override {
        std::string redirect;
        {
            AdblockState& state = State();
            std::lock_guard<std::mutex> guard(state.lock);
            auto it = state.redirects.find(request->GetIdentifier());
            if (it == state.redirects.end()) return nullptr;
            redirect = std::move(it->second);
            state.redirects.erase(it);
        }
        // adblock-rust gives "data:<mime>;base64,<body>".
        size_t semicolon = redirect.find(';');
        size_t comma = redirect.find(',');
        if (redirect.rfind("data:", 0) != 0 || semicolon == std::string::npos || comma == std::string::npos) return nullptr;
        std::string mime = redirect.substr(5, semicolon - 5);
        CefRefPtr<CefBinaryValue> body = CefBase64Decode(redirect.substr(comma + 1));
        std::string bytes(body ? body->GetSize() : 0, '\0');
        if (body && !bytes.empty()) body->GetData(bytes.data(), bytes.size(), 0);
        auto data = std::make_shared<std::string>(std::move(bytes));
        CefRefPtr<CefStreamReader> stream = CefStreamReader::CreateForData(data->data(), data->size());
        return new RedirectHandler(mime, stream, data);
    }

 private:
    /// Keeps the decoded body alive as long as the stream reading it.
    class RedirectHandler : public CefStreamResourceHandler {
     public:
        RedirectHandler(const std::string& mime, CefRefPtr<CefStreamReader> stream, std::shared_ptr<std::string> data)
            : CefStreamResourceHandler(mime, stream), data_(std::move(data)) {}
     private:
        std::shared_ptr<std::string> data_;
    };

    void NoteBlocked() {
        __weak KCBrowser* owner = owner_;
        if (!owner) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            [owner noteBlockedRequest];
        });
    }

    __weak KCBrowser* owner_;
    IMPLEMENT_REFCOUNTING(AdblockHandler);
};

class AdblockContextHandler : public CefRequestContextHandler {
 public:
    CefRefPtr<CefResourceRequestHandler> GetResourceRequestHandler(CefRefPtr<CefBrowser> browser,
                                                                   CefRefPtr<CefFrame> frame,
                                                                   CefRefPtr<CefRequest> request,
                                                                   bool is_navigation,
                                                                   bool is_download,
                                                                   const CefString& request_initiator,
                                                                   bool& disable_default_handling) override {
        return is_download ? nullptr : handler_;
    }

 private:
    CefRefPtr<AdblockHandler> handler_ = new AdblockHandler(nil);
    IMPLEMENT_REFCOUNTING(AdblockContextHandler);
};

#endif

}  // namespace

CefRefPtr<CefResourceRequestHandler> KCAdblockRequestHandler(KCBrowser* owner) {
#if KC_HAS_ADBLOCK
    return new AdblockHandler(owner);
#else
    return nullptr;
#endif
}

CefRefPtr<CefRequestContextHandler> KCAdblockContextHandler() {
#if KC_HAS_ADBLOCK
    return new AdblockContextHandler();
#else
    return nullptr;
#endif
}

CefRefPtr<CefRequestContext> KCAdblockRequestContext() {
#if KC_HAS_ADBLOCK
    // Shares cookies and storage with the global context; only adds the handler.
    static CefRefPtr<CefRequestContext> context;
    if (!context) context = CefRequestContext::CreateContext(CefRequestContext::GetGlobalContext(), new AdblockContextHandler());
    return context;
#else
    return nullptr;
#endif
}

@implementation KCRuntime (Adblock)

+ (BOOL)supportsAdblock {
#if KC_HAS_ADBLOCK
    return YES;
#else
    return NO;
#endif
}

+ (void)setAdblockEngine:(void*)engine owner:(id)owner {
#if KC_HAS_ADBLOCK
    // The deleter only drops `owner`, which frees the engine once nothing uses it.
    std::shared_ptr<KAEngine> shared;
    if (engine) shared = std::shared_ptr<KAEngine>((KAEngine*)engine, [owner](KAEngine*) {});
    AdblockState& state = State();
    std::lock_guard<std::mutex> guard(state.lock);
    state.engine = std::move(shared);
#endif
}

+ (void)setAdblockEnabled:(BOOL)enabled allowedHosts:(NSSet<NSString*>*)hosts {
#if KC_HAS_ADBLOCK
    std::set<std::string> allowed;
    for (NSString* host in hosts) allowed.insert(host.lowercaseString.UTF8String);
    AdblockState& state = State();
    std::lock_guard<std::mutex> guard(state.lock);
    state.enabled = enabled;
    state.allowedHosts = std::move(allowed);
#endif
}

@end

#import "CEFBridge.h"
#import "KCInternal.h"

#include "include/cef_callback.h"
#include "include/cef_trace.h"

// Help › Troubleshooting › Record Trace: Chromium's own tracing (CefBeginTracing /
// CefEndTracing), written to a local file. Kite never uploads it.

namespace {

class TraceStarted : public CefCompletionCallback {
public:
    explicit TraceStarted(void (^completion)(void)) : completion_([completion copy]) {}
    void OnComplete() override {
        void (^completion)(void) = completion_;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(); });
    }

private:
    void (^completion_)(void);
    IMPLEMENT_REFCOUNTING(TraceStarted);
};

class TraceEnded : public CefEndTracingCallback {
public:
    TraceEnded(void (^completion)(NSString *), bool discard) : completion_([completion copy]), discard_(discard) {}
    void OnEndTracingComplete(const CefString &tracing_file) override {
        NSString *path = [NSString stringWithUTF8String:tracing_file.ToString().c_str()];
        if (discard_ && path.length) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        void (^completion)(NSString *) = completion_;
        NSString *result = discard_ ? nil : path;
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
    }

private:
    void (^completion_)(NSString *);
    bool discard_;
    IMPLEMENT_REFCOUNTING(TraceEnded);
};

}  // namespace

@implementation KCRuntime (Tracing)

+ (BOOL)beginTracingWithCategories:(NSString *)categories completion:(void (^)(void))completion {
    if (!KCRuntime.isInitialized) return NO;
    CefRefPtr<TraceStarted> callback = completion ? new TraceStarted(completion) : nullptr;
    return CefBeginTracing(CefString(categories.UTF8String), callback);
}

+ (BOOL)endTracingToPath:(NSString *)path discard:(BOOL)discard completion:(void (^)(NSString *))completion {
    if (!KCRuntime.isInitialized) return NO;
    // CEF writes nothing without a callback, so there's always one.
    CefRefPtr<TraceEnded> callback = new TraceEnded(completion, discard);
    return CefEndTracing(CefString(path.UTF8String), callback);
}

@end

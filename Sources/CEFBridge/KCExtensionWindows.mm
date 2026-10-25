// Chrome's own windows around extension installs, made to fit Kite. Chromium shows
// them itself (Views windows), so this watches windows being ordered in:
//
// - Chrome-style browser windows (tab strip, omnibox) opened for browsers Chromium
//   created itself never appear; KCDefaultClient sends their pages to Kite tabs.
// - The "X has been added to Chromium" bubble never appears; Kite says so itself.

#import "KCInternal.h"

#import <objc/runtime.h>

namespace {

BOOL IsViewsWindow(NSWindow* window) {
    return [window isKindOfClass:NSClassFromString(@"NativeWidgetMacNSWindow")];
}

// Views windows often leave NSWindow.title empty and name themselves for accessibility.
NSString* TitleOf(NSWindow* window) {
    if (window.title.length) return window.title;
    id title = window.accessibilityTitle;
    return [title isKindOfClass:NSString.class] ? title : @"";
}

BOOL IsChromeBrowserWindow(NSWindow* window) {
    return [window isKindOfClass:NSClassFromString(@"BrowserNativeWidgetWindow")] && KCHasChromiumCreatedBrowsers();
}

BOOL IsInstalledBubble(NSWindow* window) {
    return IsViewsWindow(window) && [TitleOf(window) hasSuffix:@" has been added to Chromium"];
}

/// NO keeps the window off screen.
BOOL ShouldOrderIn(NSWindow* window) {
    if (!IsViewsWindow(window)) return YES;
    if (IsChromeBrowserWindow(window)) return NO;
    if (IsInstalledBubble(window)) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [window close];
        });
        return NO;
    }
    return YES;
}

void Swizzle(SEL selector, IMP (^make)(IMP original)) {
    Method method = class_getInstanceMethod(NSWindow.class, selector);
    method_setImplementation(method, make(method_getImplementation(method)));
}

}  // namespace

void KCInstallExtensionWindowHooks() {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Swizzle(@selector(orderWindow:relativeTo:), ^IMP(IMP original) {
            return imp_implementationWithBlock(^(NSWindow* window, NSWindowOrderingMode place, NSInteger other) {
                if (place != NSWindowOut && !ShouldOrderIn(window)) return;
                ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))original)(window, @selector(orderWindow:relativeTo:), place, other);
            });
        });
        for (NSString* name in @[@"makeKeyAndOrderFront:", @"orderFront:"]) {
            SEL selector = NSSelectorFromString(name);
            Swizzle(selector, ^IMP(IMP original) {
                return imp_implementationWithBlock(^(NSWindow* window, id sender) {
                    if (!ShouldOrderIn(window)) return;
                    ((void (*)(id, SEL, id))original)(window, selector, sender);
                });
            });
        }
        Swizzle(@selector(orderFrontRegardless), ^IMP(IMP original) {
            return imp_implementationWithBlock(^(NSWindow* window) {
                if (!ShouldOrderIn(window)) return;
                ((void (*)(id, SEL))original)(window, @selector(orderFrontRegardless));
            });
        });
    });
}

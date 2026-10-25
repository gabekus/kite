// Chrome's own windows around extension installs, made to fit Kite. Chromium shows
// them itself (Views windows), so this watches windows being ordered in:
//
// - Chrome-style browser windows (tab strip, omnibox) opened for browsers Chromium
//   created itself never appear; KCDefaultClient sends their pages to Kite tabs.
// - The "X has been added to Chromium" bubble never appears; Kite says so itself.
// - The "Add "X"?" install dialog stays Chrome's own: its text, buttons and click
//   protection are untouched (Chrome won't enable its button while the dialog is
//   hidden, and fades it back in, so it can't be replaced). It becomes a child of the
//   front Kite window, placed like a sheet at the top of the web area, so it moves
//   with Kite and never floats over other apps, and its blank title strip goes.

#import "KCInternal.h"

#import <objc/runtime.h>

#include <initializer_list>

NSString* const KCExtensionInstallDialogDidCloseNotification = @"KCExtensionInstallDialogDidCloseNotification";

static NSRect (^gDialogAnchor)(NSWindow*);

@implementation KCRuntime (ExtensionWindows)

+ (NSRect (^)(NSWindow*))extensionDialogAnchor {
    return gDialogAnchor;
}

+ (void)setExtensionDialogAnchor:(NSRect (^)(NSWindow*))anchor {
    gDialogAnchor = [anchor copy];
}

@end

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

BOOL IsInstallDialog(NSWindow* window) {
    NSString* title = TitleOf(window);
    return IsViewsWindow(window) && ([title hasPrefix:@"Add “"] || [title hasPrefix:@"Add \""]) && [title hasSuffix:@"?"];
}

/// The Kite window in front: key or main, else the frontmost that isn't Chrome's.
NSWindow* FrontKiteWindow() {
    for (NSWindow* window in @[NSApp.keyWindow ?: (id)NSNull.null, NSApp.mainWindow ?: (id)NSNull.null]) {
        if ([window isKindOfClass:NSWindow.class] && !IsViewsWindow(window) && window.isVisible) return window;
    }
    for (NSWindow* window in NSApp.orderedWindows) {
        if (!IsViewsWindow(window) && window.isVisible && window.canBecomeMainWindow) return window;
    }
    return nil;
}

void AttachInstallDialog(NSWindow* dialog) {
    // Chrome lays the dialog out without AppKit's title bar, which otherwise covers
    // its heading with a blank strip: let the content run to the top edge.
    dialog.styleMask |= NSWindowStyleMaskFullSizeContentView;
    dialog.titlebarAppearsTransparent = YES;
    dialog.titleVisibility = NSWindowTitleHidden;
    for (NSWindowButton kind : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
        [dialog standardWindowButton:kind].hidden = YES;
    }
    NSWindow* parent = FrontKiteWindow();
    if (!parent) return;
    NSRect area = gDialogAnchor ? gDialogAnchor(parent) : NSZeroRect;
    if (NSIsEmptyRect(area)) area = [parent contentRectForFrameRect:parent.frame];
    else area = [parent convertRectToScreen:area];
    // Centred on the web area, hanging just below its top edge like a sheet.
    NSRect frame = dialog.frame;
    frame.origin.x = round(NSMidX(area) - NSWidth(frame) / 2);
    frame.origin.y = round(NSMaxY(area) - 8 - NSHeight(frame));
    [dialog setFrame:frame display:NO];
    [parent addChildWindow:dialog ordered:NSWindowAbove];
    __block id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowWillCloseNotification
                    object:dialog
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                    [NSNotificationCenter.defaultCenter removeObserver:observer];
                    [NSNotificationCenter.defaultCenter postNotificationName:KCExtensionInstallDialogDidCloseNotification object:nil];
                }];
}

char kAttachedKey;

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
    if (!objc_getAssociatedObject(window, &kAttachedKey) && IsInstallDialog(window)) {
        objc_setAssociatedObject(window, &kAttachedKey, @YES, OBJC_ASSOCIATION_RETAIN);
        AttachInstallDialog(window);
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

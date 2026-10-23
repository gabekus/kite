// SPIKE: Chrome's extension windows, made to fit Kite.
//
// - The "Add "X"?" install dialog stays Chrome's own (its text, buttons and click
//   protection untouched). It becomes a child of the front Kite window, placed like
//   a sheet, so it moves with Kite and never floats over other apps, and its blank
//   title strip goes away.
// - The "X has been added to Chromium" bubble and Chrome-style browser windows
//   (opened for an extension's welcome page) are never ordered in; KCDefaultClient
//   sends their pages to Kite tabs and closes them.

#import "CEFBridge.h"

#import <objc/runtime.h>

#include <initializer_list>

NSString* const KCExtensionInstallDialogDidCloseNotification = @"KCExtensionInstallDialogDidCloseNotification";

static char kSeenKey;

static BOOL IsViewsWindow(NSWindow* window) {
    return [NSStringFromClass(window.class) containsString:@"NativeWidgetMacNSWindow"];
}

// Views dialogs leave NSWindow.title empty and name themselves for accessibility.
static NSString* TitleOf(NSWindow* window) {
    if (window.title.length) return window.title;
    NSString* title = window.accessibilityTitle;
    return [title isKindOfClass:NSString.class] ? title : @"";
}

static BOOL IsInstallDialog(NSWindow* window) {
    NSString* title = TitleOf(window);
    return IsViewsWindow(window) && ([title hasPrefix:@"Add “"] || [title hasPrefix:@"Add \""]) &&
           [title hasSuffix:@"?"];
}

static BOOL IsInstalledBubble(NSWindow* window) {
    return IsViewsWindow(window) && [TitleOf(window) hasSuffix:@" has been added to Chromium"];
}

/// A Chrome-style browser window (tab strip, omnibox) Chromium opened itself.
static BOOL IsChromeBrowserWindow(NSWindow* window) {
    // DevTools (⌥⌘I) is a Views window too, and is Kite's to show.
    if ([TitleOf(window) hasPrefix:@"DevTools"]) return NO;
    return IsViewsWindow(window) && NSWidth(window.frame) >= 500 && NSHeight(window.frame) >= 400 &&
           (window.styleMask & NSWindowStyleMaskTitled);
}

/// The Kite browser window in front: the key or main window that isn't one of Chrome's.
static NSWindow* FrontKiteWindow() {
    for (NSWindow* window in @[NSApp.keyWindow ?: NSNull.null, NSApp.mainWindow ?: NSNull.null]) {
        if ([window isKindOfClass:NSWindow.class] && !IsViewsWindow(window) && window.isVisible) return window;
    }
    for (NSWindow* window in NSApp.orderedWindows) {
        if (!IsViewsWindow(window) && window.isVisible && window.canBecomeMainWindow) return window;
    }
    return nil;
}

namespace {

void AttachInstallDialog(NSWindow* dialog) {
    // Content up to the top edge: Chrome sized the dialog without AppKit's title
    // bar, which otherwise covers its heading with a blank strip.
    dialog.styleMask |= NSWindowStyleMaskFullSizeContentView;
    dialog.titlebarAppearsTransparent = YES;
    dialog.titleVisibility = NSWindowTitleHidden;
    for (NSWindowButton kind : {NSWindowCloseButton, NSWindowMiniaturizeButton, NSWindowZoomButton}) {
        [dialog standardWindowButton:kind].hidden = YES;
    }
    NSWindow* parent = FrontKiteWindow();
    NSLog(@"KiteSpike: install dialog \"%@\" %@ -> child of \"%@\"", TitleOf(dialog), NSStringFromRect(dialog.frame),
          parent.title ?: @"(no Kite window)");
    if (!parent) return;
    // Centred, just under the top of the window, like a sheet.
    NSRect area = [parent contentRectForFrameRect:parent.frame];
    NSRect frame = dialog.frame;
    frame.origin.x = round(NSMidX(area) - NSWidth(frame) / 2);
    frame.origin.y = NSMaxY(area) - 52 - NSHeight(frame);
    [dialog setFrame:frame display:NO];
    [parent addChildWindow:dialog ordered:NSWindowAbove];
    __block id observer = [NSNotificationCenter.defaultCenter
        addObserverForName:NSWindowWillCloseNotification
                    object:dialog
                     queue:NSOperationQueue.mainQueue
                usingBlock:^(NSNotification*) {
                    NSLog(@"KiteSpike: install dialog closed");
                    [NSNotificationCenter.defaultCenter removeObserver:observer];
                    [NSNotificationCenter.defaultCenter postNotificationName:KCExtensionInstallDialogDidCloseNotification object:nil];
                }];
}

/// Called before a window is ordered in. NO keeps it off screen entirely.
BOOL WillOrderIn(NSWindow* window) {
    if (!IsViewsWindow(window)) return YES;
    if (IsInstalledBubble(window)) {
        NSLog(@"KiteSpike: dropping \"%@\"", TitleOf(window));
        dispatch_async(dispatch_get_main_queue(), ^{
            [window close];
        });
        return NO;
    }
    if (IsChromeBrowserWindow(window)) {
        NSLog(@"KiteSpike: keeping Chrome-style window \"%@\" %@ off screen", TitleOf(window), NSStringFromRect(window.frame));
        return NO;
    }
    if (!objc_getAssociatedObject(window, &kSeenKey) && IsInstallDialog(window)) {
        objc_setAssociatedObject(window, &kSeenKey, @YES, OBJC_ASSOCIATION_RETAIN);
        AttachInstallDialog(window);
    }
    return YES;
}

void Swizzle(SEL selector, IMP (^make)(IMP original)) {
    Method method = class_getInstanceMethod(NSWindow.class, selector);
    method_setImplementation(method, make(method_getImplementation(method)));
}

}  // namespace

@implementation KCRuntime (ExtensionWindows)

+ (void)installExtensionWindowHooks {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Swizzle(@selector(orderWindow:relativeTo:), ^IMP(IMP original) {
            return imp_implementationWithBlock(^(NSWindow* window, NSWindowOrderingMode place, NSInteger other) {
                if (place != NSWindowOut && !WillOrderIn(window)) return;
                ((void (*)(id, SEL, NSWindowOrderingMode, NSInteger))original)(window, @selector(orderWindow:relativeTo:), place, other);
            });
        });
        Swizzle(@selector(makeKeyAndOrderFront:), ^IMP(IMP original) {
            return imp_implementationWithBlock(^(NSWindow* window, id sender) {
                if (!WillOrderIn(window)) return;
                ((void (*)(id, SEL, id))original)(window, @selector(makeKeyAndOrderFront:), sender);
            });
        });
        Swizzle(@selector(orderFront:), ^IMP(IMP original) {
            return imp_implementationWithBlock(^(NSWindow* window, id sender) {
                if (!WillOrderIn(window)) return;
                ((void (*)(id, SEL, id))original)(window, @selector(orderFront:), sender);
            });
        });
        Swizzle(@selector(orderFrontRegardless), ^IMP(IMP original) {
            return imp_implementationWithBlock(^(NSWindow* window) {
                if (!WillOrderIn(window)) return;
                ((void (*)(id, SEL))original)(window, @selector(orderFrontRegardless));
            });
        });
    });
}

@end

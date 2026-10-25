#import "CEFBridge.h"
#import "KCInternal.h"

#include <memory>
#include <set>

#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_preference.h"
#include "include/wrapper/cef_library_loader.h"

// MARK: - KCApplication

@interface KCApplication () <CefAppProtocol>
@end

@implementation KCApplication {
    BOOL _handlingSendEvent;
}

- (BOOL)isHandlingSendEvent {
    return _handlingSendEvent;
}

- (void)setHandlingSendEvent:(BOOL)handlingSendEvent {
    _handlingSendEvent = handlingSendEvent;
}

- (void)sendEvent:(NSEvent *)event {
    CefScopedSendingEvent sendingEvent;
    [super sendEvent:event];
}

- (void)terminate:(id)sender {
    if (!KCRuntime.isInitialized) {
        if (self.willTerminate) self.willTerminate();
        [super terminate:sender];
        return;
    }
    // CEF quits only after every browser has closed; main() then calls shutdown.
    if (self.willTerminate) self.willTerminate();
    [KCRuntime closeAllBrowsersAndQuit];
}

@end

// MARK: - State

namespace {

std::unique_ptr<CefScopedLibraryLoader> gLibraryLoader;
std::set<CefRefPtr<CefBrowser>>* gBrowsers;
bool gInitialized = false;
bool gQuitting = false;
bool gEnergySaverEnabled = false;
bool gEnergySaverApplied = false;

// Chromium's BatterySaverModeState: 0 = disabled, 1 = on battery below 20% (Chrome's default).
const char kEnergySaverPref[] = "performance_tuning.battery_saver_mode.state";

// Needs the browser context, which may not exist yet right after CefInitialize,
// so it's retried when the first browser is created.
void ApplyEnergySaver() {
    CefRefPtr<CefPreferenceManager> prefs = CefPreferenceManager::GetGlobalPreferenceManager();
    if (!prefs) return;
    gEnergySaverApplied = true;
    if (!prefs->HasPreference(kEnergySaverPref)) {
        NSLog(@"Kite: Chromium has no %s preference; Energy Saver left as is", kEnergySaverPref);
        return;
    }
    CefRefPtr<CefValue> value = CefValue::Create();
    value->SetInt(gEnergySaverEnabled ? 1 : 0);
    CefString error;
    if (!prefs->SetPreference(kEnergySaverPref, value, error)) {
        NSLog(@"Kite: couldn't set Energy Saver: %s", error.ToString().c_str());
    }
}

}  // namespace

void KCRegisterBrowser(CefRefPtr<CefBrowser> browser) {
    if (!gEnergySaverApplied) ApplyEnergySaver();
    if (!gBrowsers) gBrowsers = new std::set<CefRefPtr<CefBrowser>>();
    gBrowsers->insert(browser);
}

void KCUnregisterBrowser(CefRefPtr<CefBrowser> browser) {
    if (!gBrowsers) return;
    for (auto it = gBrowsers->begin(); it != gBrowsers->end(); ++it) {
        if ((*it)->IsSame(browser)) {
            gBrowsers->erase(it);
            break;
        }
    }
    if (gQuitting && gBrowsers->empty()) CefQuitMessageLoop();
}

bool KCRuntimeIsQuitting() {
    return gQuitting;
}

// MARK: - KCRuntime

@implementation KCRuntimeSettings
- (instancetype)init {
    if ((self = [super init])) {
        _profilePath = @"";
    }
    return self;
}
@end

@implementation KCRuntime

+ (NSString *)frameworkPath {
    return [NSBundle.mainBundle.privateFrameworksPath
        stringByAppendingPathComponent:@"Chromium Embedded Framework.framework"];
}

+ (BOOL)isAvailable {
    return [NSFileManager.defaultManager fileExistsAtPath:[self frameworkPath]];
}

+ (BOOL)isInitialized {
    return gInitialized;
}

+ (BOOL)initializeWithSettings:(KCRuntimeSettings *)settings {
    if (gInitialized) return YES;
    gLibraryLoader = std::make_unique<CefScopedLibraryLoader>();
    if (!gLibraryLoader->LoadInMain()) {
        NSLog(@"Kite: failed to load the Chromium framework");
        return NO;
    }

    // Chromium keeps only the last --load-extension, so Kite's own extensions join any
    // given on the command line.
    NSMutableArray<NSString *> *arguments = [NSProcessInfo.processInfo.arguments mutableCopy];
    if (settings.extensionDirectories.count) {
        NSString *prefix = @"--load-extension=";
        NSMutableArray<NSString *> *directories = [NSMutableArray array];
        for (NSString *argument in [arguments copy]) {
            if (![argument hasPrefix:prefix]) continue;
            [directories addObjectsFromArray:[[argument substringFromIndex:prefix.length] componentsSeparatedByString:@","]];
            [arguments removeObject:argument];
        }
        [directories addObjectsFromArray:settings.extensionDirectories];
        [arguments addObject:[prefix stringByAppendingString:[directories componentsJoinedByString:@","]]];
    }
    std::vector<char *> argv;
    for (NSString *argument in arguments) argv.push_back(strdup(argument.UTF8String));
    if (settings.useMockKeychain) argv.push_back(strdup("--use-mock-keychain"));
    for (NSString *argument in settings.extraSwitches) argv.push_back(strdup(argument.UTF8String));
    CefMainArgs mainArgs((int)argv.size(), argv.data());

    CefSettings cefSettings;
    // The Chromium sandbox is on: each helper enters it in KiteHelper/main.mm.
    cefSettings.remote_debugging_port = settings.remoteDebuggingPort;
    cefSettings.log_severity = LOGSEVERITY_WARNING;
    cefSettings.persist_session_cookies = true;
    CefString(&cefSettings.root_cache_path) = settings.profilePath.UTF8String;
    CefString(&cefSettings.cache_path) = [settings.profilePath stringByAppendingPathComponent:@"Default"].UTF8String;
    CefString(&cefSettings.log_file) = [settings.profilePath stringByAppendingPathComponent:@"chromium.log"].UTF8String;

    KCInstallExtensionWindowHooks();
    gInitialized = CefInitialize(mainArgs, cefSettings, KCMakeApp(), nullptr);
    if (!gInitialized) NSLog(@"Kite: CefInitialize failed (exit code %d)", CefGetExitCode());
    else ApplyEnergySaver();
    return gInitialized;
}

+ (BOOL)energySaverEnabled {
    return gEnergySaverEnabled;
}

+ (void)setEnergySaverEnabled:(BOOL)enabled {
    gEnergySaverEnabled = enabled;
    if (gInitialized) ApplyEnergySaver();
}

+ (void)runMessageLoop {
    CefRunMessageLoop();
}

+ (void)closeAllBrowsersAndQuit {
    gQuitting = true;
    if (!gBrowsers || gBrowsers->empty()) {
        CefQuitMessageLoop();
        return;
    }
    // Copy: closing mutates the set.
    std::set<CefRefPtr<CefBrowser>> browsers = *gBrowsers;
    for (auto& browser : browsers) browser->GetHost()->CloseBrowser(true);
}

+ (void)shutdown {
    if (!gInitialized) return;
    CefShutdown();
    gInitialized = false;
    gLibraryLoader.reset();
}

@end

#pragma once
// What Chromium's sandbox did to one of Kite's processes, read from outside it: its token's
// integrity level, whether the token is restricted or an AppContainer's, and whether it can
// reach win32k (the window manager). --smoke-test checks the first page's renderer with it
// (W6b), the way chrome://sandbox lists Chrome's processes; Alloy-style CEF has no such page.

#include <windows.h>

#include <optional>
#include <string>

namespace kite {

struct ProcessSandbox {
    DWORD integrity = 0;  // the token's mandatory label RID: SECURITY_MANDATORY_*_RID
    bool restricted = false;    // a restricted token (restricting SIDs), as Chromium's lockdown token has
    bool appContainer = false;  // an AppContainer token (Chromium's LPAC helpers)
    bool win32kLockdown = false;  // win32k system calls disabled (no user32 or gdi32)
};

// Reads `pid`'s sandbox, or nullopt with `error` (the process is gone, or Kite can't see it).
std::optional<ProcessSandbox> InspectSandbox(DWORD pid, std::wstring& error);

// What's missing for a renderer to count as sandboxed, as Chromium sandboxes one on Windows:
// below medium integrity, a restricted or AppContainer token, and no win32k. Empty when it is.
std::wstring RendererSandboxProblem(const ProcessSandbox& sandbox);

// "integrity untrusted, restricted, win32k off", for logs.
std::wstring Describe(const ProcessSandbox& sandbox);

}  // namespace kite

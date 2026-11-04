#pragma once
// What Chromium's sandbox did to Kite's helper processes, read from outside them: each one's
// token integrity level, whether the token is restricted or an AppContainer's, and whether it
// can reach win32k (the window manager). --smoke-test checks them with it (W6b, docs/windows.md
// "Chromium's sandbox"), the way chrome://sandbox lists Chrome's; Alloy-style CEF has no such page.

#include <windows.h>

#include <optional>
#include <string>
#include <vector>

namespace kite {

struct ProcessSandbox {
    DWORD integrity = 0;          // the token's mandatory label RID: SECURITY_MANDATORY_*_RID
    bool restricted = false;      // a restricted token (restricting SIDs), as Chromium's lockdown token has
    bool appContainer = false;    // an AppContainer token (Chromium's LPAC helpers)
    bool win32kLockdown = false;  // win32k system calls disabled (no user32 or gdi32)
};

// Reads `pid`'s sandbox, or nullopt with `error` (the process is gone, or Kite can't see it).
std::optional<ProcessSandbox> InspectSandbox(DWORD pid, std::wstring& error);

// What's missing for a renderer to count as sandboxed, as Chromium sandboxes one on Windows:
// below medium integrity, a restricted or AppContainer token, and no win32k. Empty when it is.
std::wstring RendererSandboxProblem(const ProcessSandbox& sandbox);

// One of this process's children, as Chromium started it.
struct Helper {
    DWORD pid = 0;
    std::wstring type;  // its --type (renderer, gpu-process, utility), and a utility's sub-type after a colon
    ProcessSandbox sandbox;
};

// This process's children: Chromium's helpers. Empty with `error` when they can't be listed
// or one can't be read.
std::vector<Helper> Helpers(std::wstring& error);

// A helper at medium integrity or above, other than the network service, which Chromium runs
// unsandboxed on Windows (as Chrome does). Empty when there's none.
std::wstring HelperSandboxProblem(const std::vector<Helper>& helpers);

// "integrity untrusted, restricted, win32k off", for logs.
std::wstring Describe(const ProcessSandbox& sandbox);

}  // namespace kite

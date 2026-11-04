// See ForegroundWatch.h.

#include "shell/ForegroundWatch.h"

#include <iterator>

namespace kite {
namespace {

// The one watch (a WinEvent callback has no context of its own). Kite's UI thread only.
ForegroundWatch* watching = nullptr;

bool IsKites(HWND window) {
    if (!window) return false;
    DWORD process = 0;
    GetWindowThreadProcessId(window, &process);
    return process == GetCurrentProcessId();
}

std::wstring ClassOf(HWND window) {
    wchar_t name[128] = {};
    return window && GetClassNameW(window, name, static_cast<int>(std::size(name))) ? name : L"";
}

}  // namespace

ForegroundWatch::ForegroundWatch() {
    watching = this;
    hook_ = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, &ForegroundWatch::OnForeground,
                            GetCurrentProcessId(), 0, WINEVENT_OUTOFCONTEXT);
}

ForegroundWatch::~ForegroundWatch() {
    if (hook_) UnhookWinEvent(hook_);
    if (watching == this) watching = nullptr;
}

void CALLBACK ForegroundWatch::OnForeground(HWINEVENTHOOK, DWORD, HWND window, LONG object, LONG, DWORD, DWORD) {
    if (watching && object == OBJID_WINDOW) watching->Saw(window);
}

void ForegroundWatch::Saw(HWND window) {
    if (!IsKites(window)) return;
    if (times_++ > 0) return;
    // The window itself (a page's is Chromium's widget) and the top-level window it's in.
    first_ = ClassOf(window);
    if (first_.empty()) first_ = L"a window";
    if (const HWND root = GetAncestor(window, GA_ROOT); root && root != window) first_ += L" in " + ClassOf(root);
}

std::wstring ForegroundWatch::Problem() {
    Saw(GetForegroundWindow());
    if (times_ > 0) {
        return L"a quiet run came to the front: " + first_ + L" became the foreground window" +
               (times_ > 1 ? L" (" + std::to_wstring(times_) + L" times)" : L"");
    }
    if (!hook_) return L"couldn't watch the foreground window (SetWinEventHook failed)";
    return {};
}

}  // namespace kite

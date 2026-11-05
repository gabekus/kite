// See QuietRun.h.

#include "shell/QuietRun.h"

#include <cassert>
#include <iterator>

#include "shell/Text.h"

namespace kite {
namespace {

std::wstring ClassOf(HWND window) {
    wchar_t name[128] = {};
    return window && GetClassNameW(window, name, static_cast<int>(std::size(name))) ? name : L"";
}

// The window and the top-level window it's in (a page's is Chromium's widget in Kite's window).
std::wstring Describe(HWND window) {
    std::wstring text = ClassOf(window);
    if (text.empty()) return L"a window that's gone";
    if (const HWND root = GetAncestor(window, GA_ROOT); root && root != window) text += L" in " + ClassOf(root);
    return text;
}

}  // namespace

void LogSkippedModal(std::wstring_view what) {
    std::wstring line = L"KITE_TEST_MODAL: " + std::wstring(what);
    for (wchar_t& c : line) {
        if (c == L'\r' || c == L'\n') c = L' ';
    }
    line += L'\n';
    OutputDebugStringW(line.c_str());
    WriteUtf8(STD_ERROR_HANDLE, line);
}

ForegroundWatch* ForegroundWatch::current_ = nullptr;

ForegroundWatch::ForegroundWatch() {
    assert(!current_ && "one ForegroundWatch at a time");
    current_ = this;
    hook_ = SetWinEventHook(EVENT_SYSTEM_FOREGROUND, EVENT_SYSTEM_FOREGROUND, nullptr, &ForegroundWatch::OnForeground,
                            GetCurrentProcessId(), 0, WINEVENT_OUTOFCONTEXT);
}

ForegroundWatch::~ForegroundWatch() {
    if (hook_) UnhookWinEvent(hook_);
    if (current_ == this) current_ = nullptr;
}

void CALLBACK ForegroundWatch::OnForeground(HWINEVENTHOOK, DWORD, HWND window, LONG object, LONG, DWORD, DWORD) {
    // Only Kite's process's events come (the hook's idProcess); a window that's already gone
    // still counts.
    ForegroundWatch* watch = current_;
    if (!watch || object != OBJID_WINDOW) return;
    if (watch->times_++ == 0) watch->first_ = Describe(window);
}

std::wstring ForegroundWatch::Problem() {
    // Out-of-context events wait for this thread to next look at its queue; looking delivers
    // them, and leaves the posted messages where they are.
    MSG message;
    PeekMessageW(&message, nullptr, 0, 0, PM_NOREMOVE);
    if (!hook_) return L"couldn't watch the foreground window (SetWinEventHook failed)";
    const HWND front = GetForegroundWindow();
    DWORD process = 0;
    if (front) GetWindowThreadProcessId(front, &process);
    const bool inFrontNow = front && process == GetCurrentProcessId();
    if (times_ == 0 && !inFrontNow) return {};
    std::wstring problem = L"a quiet run came to the front: ";
    if (times_ > 0) {
        problem += first_ + L" became the foreground window";
        if (times_ > 1) problem += L" (" + std::to_wstring(times_) + L" times)";
        if (inFrontNow) problem += L", and " + Describe(front) + L" is in front now";
    } else {
        problem += Describe(front) + L" is the foreground window";
    }
    return problem;
}

}  // namespace kite

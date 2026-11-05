// See RelayedTooltips.h.

#include "shell/RelayedTooltips.h"

#include <commctrl.h>

#include <algorithm>

namespace kite {

RelayedTooltips::~RelayedTooltips() {
    if (tooltip_) DestroyWindow(tooltip_);
}

void RelayedTooltips::SetTools(std::vector<Tool> tools) {
    if (tools == tools_) return;
    const bool samePlaces = tools.size() == tools_.size() &&
                            std::equal(tools.begin(), tools.end(), tools_.begin(),
                                       [](const Tool& a, const Tool& b) { return EqualRect(&a.rect, &b.rect) != FALSE; });
    std::vector<Tool> old = std::move(tools_);
    tools_ = std::move(tools);
    if (!tooltip_ || !active_) return;
    if (!samePlaces) return Rebuild();
    // Only texts changed (a page's title): those tools' texts.
    for (size_t i = 0; i < tools_.size(); ++i) {
        if (tools_[i].text == old[i].text) continue;
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = window_;
        tool.uId = i + 1;
        tool.lpszText = const_cast<wchar_t*>(tools_[i].text.c_str());  // copied by the control
        SendMessageW(tooltip_, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool));
    }
}

void RelayedTooltips::SetActive(bool active) {
    if (active == active_) return;
    active_ = active;
    if (!tooltip_) return;
    if (!active) SendMessageW(tooltip_, TTM_POP, 0, 0);
    Rebuild();
}

void RelayedTooltips::Make() {
    // Windows' own tooltips, as the Mac's toolTip is AppKit's: comctl32 loads with the first.
    INITCOMMONCONTROLSEX controls{sizeof(controls), ICC_BAR_CLASSES};
    InitCommonControlsEx(&controls);
    tooltip_ = CreateWindowExW(WS_EX_TOPMOST, TOOLTIPS_CLASSW, nullptr, WS_POPUP | TTS_NOPREFIX, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
                               CW_USEDEFAULT, window_, nullptr, GetModuleHandleW(nullptr), nullptr);
    // No tooltip isn't a failure (what it's over still works), and it isn't tried again.
    if (!tooltip_) {
        OutputDebugStringW(L"Kite: no tooltips\n");
        allowed_ = false;
        return;
    }
    Rebuild();
}

void RelayedTooltips::Rebuild() {
    for (size_t id = 1; id <= added_; ++id) {
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = window_;
        tool.uId = id;
        SendMessageW(tooltip_, TTM_DELTOOLW, 0, reinterpret_cast<LPARAM>(&tool));
    }
    added_ = 0;
    if (!active_) return;
    for (size_t i = 0; i < tools_.size(); ++i) {
        TOOLINFOW tool{};
        tool.cbSize = sizeof(tool);
        tool.hwnd = window_;  // relayed messages (TTM_RELAYEVENT), not a subclass of the window
        tool.uId = i + 1;
        tool.rect = tools_[i].rect;
        tool.lpszText = const_cast<wchar_t*>(tools_[i].text.c_str());  // copied by the control
        if (!SendMessageW(tooltip_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool))) break;
        added_ = i + 1;
    }
}

void RelayedTooltips::Relay(UINT message, WPARAM wParam, LPARAM lParam) {
    if (!active_ || !allowed_) return;
    if (!tooltip_) {
        // The first move over a tool makes them.
        if (message != WM_MOUSEMOVE) return;
        const POINT at{static_cast<short>(LOWORD(lParam)), static_cast<short>(HIWORD(lParam))};
        if (std::none_of(tools_.begin(), tools_.end(), [&](const Tool& tool) { return PtInRect(&tool.rect, at) != FALSE; })) return;
        Make();
        if (!tooltip_) return;
    }
    // The pointer left the window: no more moves come to take the tip down.
    if (message == WM_MOUSELEAVE) {
        SendMessageW(tooltip_, TTM_POP, 0, 0);
        return;
    }
    MSG msg{window_, message, wParam, lParam, static_cast<DWORD>(GetMessageTime()), {}};
    const DWORD pos = GetMessagePos();
    msg.pt = POINT{static_cast<short>(LOWORD(pos)), static_cast<short>(HIWORD(pos))};
    SendMessageW(tooltip_, TTM_RELAYEVENT, 0, reinterpret_cast<LPARAM>(&msg));
}

}  // namespace kite

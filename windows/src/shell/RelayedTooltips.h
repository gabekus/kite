#pragma once
// Windows' own tooltips over parts of the window that aren't windows (the sidebar's top-row
// buttons, the favorites' panes), as AppKit's toolTip on the Mac's views: a comctl32 tooltip made
// on the first move over one of its tools (so comctl32 doesn't load at launch), with the window's
// mouse messages relayed to it (TTM_RELAYEVENT, no subclass of the window) and the system's delay
// and look.

#include <windows.h>

#include <string>
#include <vector>

namespace kite {

class RelayedTooltips {
public:
    // `allowed` false (a capture) never makes the tooltip window.
    RelayedTooltips(HWND window, bool allowed) : window_(window), allowed_(allowed) {}
    ~RelayedTooltips();
    RelayedTooltips(const RelayedTooltips&) = delete;
    RelayedTooltips& operator=(const RelayedTooltips&) = delete;

    struct Tool {
        RECT rect;  // client px
        std::wstring text;
        bool operator==(const Tool& other) const {
            return EqualRect(&rect, &other.rect) != FALSE && text == other.text;
        }
    };
    // The tools, in order. The control's tools are made again only when their places or their count
    // change; a new text alone updates that tool's (TTM_UPDATETIPTEXTW).
    void SetTools(std::vector<Tool> tools);
    // Inactive (the sidebar hidden) the tip goes and no tool shows one; active again, they're back.
    void SetActive(bool active);
    // The window's mouse message (client px). The first move over a tool makes the window.
    void Relay(UINT message, WPARAM wParam, LPARAM lParam);
    bool Made() const { return tooltip_ != nullptr; }

private:
    void Make();
    // The control's tools from `tools_` (none while inactive).
    void Rebuild();

    HWND window_;
    bool allowed_;
    bool active_ = true;
    HWND tooltip_ = nullptr;
    std::vector<Tool> tools_;
    size_t added_ = 0;  // the control's tools: ids 1 to added_
};

}  // namespace kite

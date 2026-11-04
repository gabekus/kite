// See SpaceMenu.h.

#include "shell/SpaceMenu.h"

#include <commctrl.h>

#include <algorithm>
#include <cmath>
#include <string>

#include "shell/Text.h"

namespace kite {

namespace {

// uxtheme's PreferredAppMode (ordinal 135's argument).
enum class AppMode : int { Default = 0, AllowDark = 1, ForceDark = 2, ForceLight = 3 };

// Win32 menus in the space's appearance, as the Mac's NSMenu takes the window's (see the header).
void UseMenuAppearance(bool dark) {
    using SetPreferredAppMode = int(WINAPI*)(AppMode);
    using FlushMenuThemes = void(WINAPI*)();
    static const HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!uxtheme) return;
    static const auto setMode = reinterpret_cast<SetPreferredAppMode>(reinterpret_cast<void*>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(135))));
    static const auto flush = reinterpret_cast<FlushMenuThemes>(reinterpret_cast<void*>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(136))));
    if (!setMode || !flush) return;
    setMode(dark ? AppMode::ForceDark : AppMode::ForceLight);
    flush();
}

// The item ids: each command's value plus one (0 is TrackPopupMenuEx's "nothing chosen").
UINT ItemId(SpaceMenuItem::Command command) { return static_cast<UINT>(command) + 1; }

HMENU MakeMenu(const std::vector<SpaceMenuItem>& items) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return nullptr;
    for (const SpaceMenuItem& item : items) {
        if (item.command == SpaceMenuItem::Command::Separator) {
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            continue;
        }
        // Menu text treats & as a mnemonic's mark; the Mac's titles have none.
        std::wstring title;
        for (wchar_t c : Widen(item.title)) {
            if (c == L'&') title += L'&';
            title += c;
        }
        const UINT state = item.enabled ? MF_ENABLED : MF_GRAYED;
        if (item.submenu) {
            // Its items come with what they set; until then the submenu is there, disabled.
            HMENU sub = CreatePopupMenu();
            AppendMenuW(menu, MF_POPUP | state, reinterpret_cast<UINT_PTR>(sub), title.c_str());
        } else {
            AppendMenuW(menu, MF_STRING | state, ItemId(item.command), title.c_str());
        }
    }
    return menu;
}

std::optional<SpaceMenuItem::Command> CommandFor(const std::vector<SpaceMenuItem>& items, UINT id) {
    for (const SpaceMenuItem& item : items) {
        if (id != 0 && ItemId(item.command) == id && item.enabled && !item.submenu) return item.command;
    }
    return std::nullopt;
}

// RenderSpaceMenu's read-back, from a thread timer the menu's loop runs.
struct MenuGrab {
    Pixels* out = nullptr;
    UINT dpi = USER_DEFAULT_SCREEN_DPI;  // the menu window's, as it drew
    std::wstring error = L"the menu didn't show";
    int ticks = 0;
};
thread_local MenuGrab* grab = nullptr;

BOOL CALLBACK FindMenuWindow(HWND window, LPARAM found) {
    wchar_t name[16]{};
    if (GetClassNameW(window, name, 16) && std::wstring(name) == L"#32768" && IsWindowVisible(window)) {
        *reinterpret_cast<HWND*>(found) = window;
        return FALSE;
    }
    return TRUE;
}

void CALLBACK GrabMenu(HWND, UINT, UINT_PTR timer, DWORD) {
    if (!grab) return;
    HWND menu = nullptr;
    EnumThreadWindows(GetCurrentThreadId(), FindMenuWindow, reinterpret_cast<LPARAM>(&menu));
    // A few ticks after it shows, past its fade-in; at most a second.
    if ((!menu || ++grab->ticks < 4) && grab->ticks < 50) {
        if (!menu) ++grab->ticks;
        return;
    }
    KillTimer(nullptr, timer);
    RECT r{};
    if (menu && GetWindowRect(menu, &r) && r.right > r.left && r.bottom > r.top) {
        const auto width = static_cast<UINT>(r.right - r.left), height = static_cast<UINT>(r.bottom - r.top);
        BITMAPINFO info{};
        info.bmiHeader = {sizeof(BITMAPINFOHEADER), static_cast<LONG>(width), -static_cast<LONG>(height), 1, 32, BI_RGB, 0, 0, 0, 0, 0};
        void* bits = nullptr;
        HDC screen = GetDC(nullptr);
        HDC dc = CreateCompatibleDC(screen);
        HBITMAP bitmap = CreateDIBSection(screen, &info, DIB_RGB_COLORS, &bits, nullptr, 0);
        if (dc && bitmap && bits) {
            HGDIOBJ old = SelectObject(dc, bitmap);
            if (PrintWindow(menu, dc, 0)) {
                GdiFlush();
                grab->out->width = width;
                grab->out->height = height;
                const auto* p = static_cast<const uint8_t*>(bits);
                grab->out->bgra.assign(p, p + static_cast<size_t>(width) * height * 4);
                // GDI leaves alpha at 0: the menu is opaque.
                for (size_t i = 3; i < grab->out->bgra.size(); i += 4) grab->out->bgra[i] = 255;
                grab->dpi = GetDpiForWindow(menu);
                grab->error.clear();
            } else {
                grab->error = L"PrintWindow couldn't draw the menu";
            }
            SelectObject(dc, old);
        }
        if (bitmap) DeleteObject(bitmap);
        if (dc) DeleteDC(dc);
        ReleaseDC(nullptr, screen);
    }
    EndMenu();
}

// `in` resampled by `factor` (bilinear), for a menu drawn at another DPI than the capture's.
Pixels Scaled(const Pixels& in, double factor) {
    if (factor == 1 || in.width == 0 || in.height == 0) return in;
    Pixels out;
    out.width = std::max(1u, static_cast<UINT>(std::lround(in.width * factor)));
    out.height = std::max(1u, static_cast<UINT>(std::lround(in.height * factor)));
    out.bgra.resize(static_cast<size_t>(out.width) * out.height * 4);
    for (UINT y = 0; y < out.height; ++y) {
        const double sy = std::clamp((y + 0.5) / factor - 0.5, 0.0, in.height - 1.0);
        const UINT y0 = static_cast<UINT>(sy), y1 = std::min(y0 + 1, in.height - 1);
        const double fy = sy - y0;
        for (UINT x = 0; x < out.width; ++x) {
            const double sx = std::clamp((x + 0.5) / factor - 0.5, 0.0, in.width - 1.0);
            const UINT x0 = static_cast<UINT>(sx), x1 = std::min(x0 + 1, in.width - 1);
            const double fx = sx - x0;
            for (int c = 0; c < 4; ++c) {
                const auto at = [&](UINT px, UINT py) { return in.bgra[(static_cast<size_t>(py) * in.width + px) * 4 + c]; };
                const double top = at(x0, y0) * (1 - fx) + at(x1, y0) * fx, bottom = at(x0, y1) * (1 - fx) + at(x1, y1) * fx;
                out.bgra[(static_cast<size_t>(y) * out.width + x) * 4 + c] = static_cast<uint8_t>(std::lround(top * (1 - fy) + bottom * fy));
            }
        }
    }
    return out;
}

}  // namespace

std::optional<SpaceMenuItem::Command> ShowSpaceMenu(HWND window, const std::vector<SpaceMenuItem>& items, POINT screen, bool dark) {
    HMENU menu = MakeMenu(items);
    if (!menu) return std::nullopt;
    UseMenuAppearance(dark);
    // A menu shown for a window in front closes when the pointer clicks elsewhere (KB135788).
    SetForegroundWindow(window);
    const UINT id = static_cast<UINT>(TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_NONOTIFY,
                                                       screen.x, screen.y, window, nullptr));
    PostMessageW(window, WM_NULL, 0, 0);
    DestroyMenu(menu);  // with its submenus
    return CommandFor(items, id);
}

std::wstring RenderSpaceMenu(HWND window, const std::vector<SpaceMenuItem>& items, POINT screen, bool dark, UINT dpi, Pixels& out) {
    HMENU menu = MakeMenu(items);
    if (!menu) return L"CreatePopupMenu failed";
    UseMenuAppearance(dark);
    Pixels shown;
    MenuGrab state{&shown};
    grab = &state;
    const UINT_PTR timer = SetTimer(nullptr, 0, 20, GrabMenu);
    // Shown without coming forward (a quiet capture never activates Kite), closed by the timer.
    TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_NONOTIFY | TPM_NOANIMATION, screen.x, screen.y, window, nullptr);
    if (timer) KillTimer(nullptr, timer);
    grab = nullptr;
    DestroyMenu(menu);
    if (!timer) return L"SetTimer failed";
    if (!state.error.empty()) return state.error;
    out = Scaled(shown, static_cast<double>(dpi) / (state.dpi ? state.dpi : USER_DEFAULT_SCREEN_DPI));
    return {};
}

bool AskToDeleteSpace(HWND window, const SpaceDeletion& deletion) {
    constexpr int kDelete = 100;
    const std::wstring title = Widen(deletion.title), message = Widen(deletion.message);
    const TASKDIALOG_BUTTON buttons[] = {{kDelete, L"Delete"}, {IDCANCEL, L"Cancel"}};
    TASKDIALOGCONFIG config{};
    config.cbSize = sizeof(config);
    config.hwndParent = window;
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
    config.pszWindowTitle = L"Kite";
    config.pszMainInstruction = title.c_str();
    config.pszContent = message.c_str();
    config.cButtons = 2;
    config.pButtons = buttons;
    // The Mac's first button, Delete, is its default (Return).
    config.nDefaultButton = kDelete;
    int pressed = 0;
    return SUCCEEDED(TaskDialogIndirect(&config, &pressed, nullptr, nullptr)) && pressed == kDelete;
}

}  // namespace kite

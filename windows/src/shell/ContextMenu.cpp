// See ContextMenu.h. Moved out of SpaceMenu.cpp (W9d) for the sidebar's row menus (W17).

#include "shell/ContextMenu.h"

#include <commctrl.h>

#include <algorithm>
#include <cmath>
#include <string>

#include "shell/Text.h"

namespace kite {

namespace {

// uxtheme's PreferredAppMode (ordinal 135's argument).
enum class AppMode : int { Default = 0, AllowDark = 1, ForceDark = 2, ForceLight = 3 };

// Windows 10 1903 (build 18362), where ordinal 135 became SetPreferredAppMode (before it, it was
// AllowDarkModeForApp, with another argument): RtlGetVersion, which no manifest shims.
bool HasPreferredAppMode() {
    using RtlGetVersion = LONG(WINAPI*)(OSVERSIONINFOW*);
    const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    const auto get = ntdll ? reinterpret_cast<RtlGetVersion>(reinterpret_cast<void*>(GetProcAddress(ntdll, "RtlGetVersion"))) : nullptr;
    OSVERSIONINFOW version{};
    version.dwOSVersionInfoSize = sizeof(version);
    return get && get(&version) == 0 && (version.dwMajorVersion > 10 || (version.dwMajorVersion == 10 && version.dwBuildNumber >= 18362));
}

// Win32 menus in the space's appearance while one is open, as the Mac's NSMenu takes the
// window's (see the header). The mode is the whole process's, so it's set as a menu opens and put
// back to the default (light) as it closes: nothing else Kite shows is left forced dark.
class MenuAppearance {
public:
    explicit MenuAppearance(bool dark) {
        if (!Load()) return;
        setMode_(dark ? AppMode::ForceDark : AppMode::ForceLight);
        flush_();
        set_ = true;
    }
    ~MenuAppearance() {
        if (!set_) return;
        setMode_(AppMode::Default);
        flush_();
    }
    MenuAppearance(const MenuAppearance&) = delete;
    MenuAppearance& operator=(const MenuAppearance&) = delete;

private:
    using SetPreferredAppMode = int(WINAPI*)(AppMode);
    using FlushMenuThemes = void(WINAPI*)();
    static bool Load() {
        static const bool loaded = [] {
            if (!HasPreferredAppMode()) return false;
            const HMODULE uxtheme = LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
            if (!uxtheme) return false;
            setMode_ = reinterpret_cast<SetPreferredAppMode>(reinterpret_cast<void*>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(135))));
            flush_ = reinterpret_cast<FlushMenuThemes>(reinterpret_cast<void*>(GetProcAddress(uxtheme, MAKEINTRESOURCEA(136))));
            return setMode_ && flush_;
        }();
        return loaded;
    }
    static inline SetPreferredAppMode setMode_ = nullptr;
    static inline FlushMenuThemes flush_ = nullptr;
    bool set_ = false;
};

// Appends `entries` to `menu`, numbering every entry depth first from `next`: an item's id is its
// index plus one (0 is TrackPopupMenuEx's "nothing chosen").
void Append(HMENU menu, const std::vector<ContextMenuEntry>& entries, size_t& next) {
    for (const ContextMenuEntry& entry : entries) {
        const size_t index = next++;
        if (entry.separator) {
            AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
            continue;
        }
        // Menu text treats & as a mnemonic's mark; the Mac's titles have none.
        std::wstring title;
        for (wchar_t c : Widen(entry.title)) {
            if (c == L'&') title += L'&';
            title += c;
        }
        const UINT state = entry.enabled ? MF_ENABLED : MF_GRAYED;
        if (entry.submenu) {
            // A submenu with nothing in it yet (one whose items come with their checkpoint) is
            // there, disabled.
            HMENU sub = CreatePopupMenu();
            Append(sub, entry.entries, next);
            AppendMenuW(menu, MF_POPUP | state, reinterpret_cast<UINT_PTR>(sub), title.c_str());
        } else {
            AppendMenuW(menu, MF_STRING | state, static_cast<UINT_PTR>(index + 1), title.c_str());
        }
    }
}

HMENU MakeMenu(const std::vector<ContextMenuEntry>& entries) {
    HMENU menu = CreatePopupMenu();
    if (!menu) return nullptr;
    size_t next = 0;
    Append(menu, entries, next);
    return menu;
}

// The entry at depth-first `index`, if it's one that may be chosen.
const ContextMenuEntry* EntryAt(const std::vector<ContextMenuEntry>& entries, size_t index, size_t& next) {
    for (const ContextMenuEntry& entry : entries) {
        if (next++ == index) return &entry;
        if (entry.submenu) {
            if (const ContextMenuEntry* found = EntryAt(entry.entries, index, next)) return found;
        }
    }
    return nullptr;
}

// RenderContextMenu's read-back, from a thread timer the menu's loop runs.
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

size_t ContextMenuSize(const std::vector<ContextMenuEntry>& entries) {
    size_t size = 0;
    for (const ContextMenuEntry& entry : entries) size += 1 + (entry.submenu ? ContextMenuSize(entry.entries) : 0);
    return size;
}

std::optional<size_t> ShowContextMenu(HWND window, const std::vector<ContextMenuEntry>& entries, POINT screen, bool dark) {
    HMENU menu = MakeMenu(entries);
    if (!menu) return std::nullopt;
    const MenuAppearance appearance(dark);
    // A menu shown for a window in front closes when the pointer clicks elsewhere (KB135788).
    SetForegroundWindow(window);
    const UINT id = static_cast<UINT>(TrackPopupMenuEx(menu, TPM_RETURNCMD | TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_TOPALIGN | TPM_NONOTIFY,
                                                       screen.x, screen.y, window, nullptr));
    PostMessageW(window, WM_NULL, 0, 0);
    DestroyMenu(menu);  // with its submenus
    if (id == 0) return std::nullopt;
    size_t next = 0;
    const ContextMenuEntry* chosen = EntryAt(entries, id - 1, next);
    if (!chosen || chosen->separator || chosen->submenu || !chosen->enabled) return std::nullopt;
    return id - 1;
}

std::wstring RenderContextMenu(HWND window, const std::vector<ContextMenuEntry>& entries, POINT screen, bool dark, UINT dpi, Pixels& out) {
    HMENU menu = MakeMenu(entries);
    if (!menu) return L"CreatePopupMenu failed";
    const MenuAppearance appearance(dark);
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

bool AskToConfirm(HWND window, const std::string& title, const std::string& message, const std::string& confirm) {
    constexpr int kConfirm = 100;
    const std::wstring main = Widen(title), content = Widen(message), button = Widen(confirm);
    const TASKDIALOG_BUTTON buttons[] = {{kConfirm, button.c_str()}, {IDCANCEL, L"Cancel"}};
    TASKDIALOGCONFIG config{};
    config.cbSize = sizeof(config);
    config.hwndParent = window;
    config.dwFlags = TDF_ALLOW_DIALOG_CANCELLATION | TDF_POSITION_RELATIVE_TO_WINDOW;
    config.pszWindowTitle = L"Kite";
    config.pszMainInstruction = main.c_str();
    config.pszContent = content.c_str();
    config.cButtons = 2;
    config.pButtons = buttons;
    // The Mac's first button is its default (Return).
    config.nDefaultButton = kConfirm;
    int pressed = 0;
    return SUCCEEDED(TaskDialogIndirect(&config, &pressed, nullptr, nullptr)) && pressed == kConfirm;
}

}  // namespace kite

#pragma once
// The browser window and what's in it, as the Mac's BrowserWindowController: the backdrop,
// the sidebar, the caption buttons, the command bar, the pages (Chromium) and Kite's
// shortcuts, wired to the session (core/Models.h). main.cpp parses the command line, loads and
// saves the session, and runs one of these.
//
// Everything here is on Kite's UI thread. The session is the caller's, borrowed for the
// window's life; the window changes it and the caller saves it as the window closes
// (MainWindow::onClose).

#include <windows.h>

#include <filesystem>
#include <functional>
#include <map>
#include <memory>
#include <optional>
#include <string>

#include "core/KeyBindings.h"
#include "core/Models.h"
#include "core/ThemeBackdrop.h"
#include "shell/CaptionButtonsView.h"
#include "shell/CommandBarView.h"
#include "shell/Compositor.h"
#include "shell/Favicons.h"
#include "shell/MainWindow.h"
#include "shell/Renderer.h"
#include "shell/SidebarView.h"

namespace kite {

#ifdef KITE_HAS_CEF
class Chromium;
#endif

class BrowserWindowController {
public:
    struct Options {
        // A --capture run: the solid material under the backdrop (not what's behind the
        // window), no favicons (no network) and no auto-archive. The caller doesn't start
        // Chromium for one.
        bool capture = false;
        // --smoke-test: every shortcut command must do something, and the first page's load
        // closes the window.
        bool smokeTest = false;
    };

    // The content card, in points: right of the sidebar, inset on the other three sides
    // (BrowserWindowController's Layout.defaultSidebarWidth and ArcMetrics.Content.inset).
    static constexpr int kSidebarWidth = 240;
    static constexpr int kContentInset = 10;

    // The window and everything in it, laid out and wired, not yet shown or drawn. Null with
    // `error` when the GPU, the window or a view couldn't be made. No command bar isn't a
    // failure (CommandBar() is null then).
    static std::unique_ptr<BrowserWindowController> Create(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts,
                                                           Options options, std::wstring& error);
    ~BrowserWindowController();
    BrowserWindowController(const BrowserWindowController&) = delete;
    BrowserWindowController& operator=(const BrowserWindowController&) = delete;

    MainWindow& Window() { return window_; }
    CommandBarView* CommandBar() { return commandBar_.get(); }
    // Why there's no command bar, when there isn't one.
    const std::wstring& CommandBarError() const { return barError_; }
    UINT MaxTextureSize() const { return renderer_ ? renderer_->MaxTextureSize() : 0; }

#ifdef KITE_HAS_CEF
    // Starts Chromium for the window's pages, its profiles under `root`. AlreadyRunning: another
    // Kite has the profile and was told to come forward.
    enum class ChromiumStart { Started, AlreadyRunning, Failed };
    ChromiumStart StartChromium(const std::filesystem::path& root, std::wstring& error);
    // After the message loop: Chromium's shutdown, then what a smoke test checks of it. Empty
    // when it all went well (or there was no Chromium).
    std::wstring ShutDownChromium();
#endif
    // What the pages reported and Kite hasn't run yet (the window's close, at logoff, comes
    // with no WM_CLOSE first).
    void RunPending();

    // Shows the window (behind other windows for a quiet run) and, with Chromium, the first page,
    // and starts the auto-archive's timer.
    void Show(int showCommand, bool behindOtherWindows);

    // Draws the backdrop, the sidebar and the caption buttons and commits them; with
    // `readBack`, the backdrop's frame as presented. Rebuilds a lost GPU first.
    std::wstring Draw(Pixels* readBack = nullptr);
    // The smoke test's checks of the window: the command bar opens and draws, the sidebar and
    // the caption buttons draw something, and the lost-GPU path rebuilds and draws. Empty on
    // success. Then the window closes once the first page has loaded (30 s at most), or after
    // a second without Chromium.
    std::wstring SmokeTest();
    // The window's frame as the screen shows it: the backdrop with the sidebar, the caption
    // buttons and (with `barText`) the command bar opened with that text, composed over it.
    std::wstring Capture(Pixels& pixels, const std::optional<std::string>& barText);

    // Runs messages until WM_QUIT, rebuilding the GPU when its device is removed.
    void RunMessageLoop();

private:
    BrowserWindowController(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts, Options options,
                            std::unique_ptr<Renderer> renderer);
    std::wstring Init();

    // The session changed under the window: the sidebar and an open bar show it.
    void StateChanged();
    // The selected tab's page shows, and the sidebar with it, after the selection moved.
    void SelectionMoved();
    void ShowPage();
    void LoadInTab(const std::string& tabID, const std::string& url);
    // A tab left the session (closed, unloaded or archived): its page goes.
    void PageGone(const std::string& tabID);
    void BlockPages(bool blocked);
    // The Mac's newTab and openLocation.
    void OpenCommandBar(CommandBarMode mode);
    CommandBarView::Look BarLook() const;
    void Commit(const CommandSuggestion& row, CommandBarMode mode);
    // A tab's close button and Ctrl+W (the Mac's close(tab:)). The id by value: Ctrl+W's is the
    // tab's own, which closing erases.
    void CloseTab(std::string id);
    void ArchiveTab();
    void ReopenClosedTab();
    void MakeCommands();
    void RunCommand(const std::string& command);
    bool PageCommand(const std::string& command);
    void DropCompositor();
    std::wstring Rebuild();
    void OnSize();
    bool Filter(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result);
#ifdef KITE_HAS_CEF
    RECT ContentBounds() const;
    void ShowSelectedTab();
    void ShowFirstPage();
    Tab* TabNamed(const std::string& id);
#endif

    HINSTANCE instance_;
    BrowserState& state_;
    const ShortcutMap shortcuts_;
    const Options options_;
    // Destroyed in reverse: the views and the compositor before the window, the window before
    // Chromium (closing it destroys the browsers' windows, which Chromium's shutdown waits
    // for), and the GPU last.
    std::unique_ptr<Renderer> renderer_;
#ifdef KITE_HAS_CEF
    std::unique_ptr<Chromium> chromium_;
#endif
    MainWindow window_;
    // The selected space's theme at launch (W9 changes it with the space).
    Theme theme_;
    Rgba base_{};
    std::unique_ptr<Compositor> compositor_;
    std::unique_ptr<Favicons> favicons_;
    std::unique_ptr<SidebarView> sidebar_;
    std::unique_ptr<CaptionButtonsView> caption_;
    std::unique_ptr<CommandBarView> commandBar_;
    std::wstring barError_;

    // What each shortcut's command does, by id (MainMenu.swift's items).
    std::map<std::string, std::function<void()>, std::less<>> commands_;
    // A shortcut ran from a key: the character Windows makes of that key isn't typed.
    bool dropCharacter_ = false;
#ifdef KITE_HAS_CEF
    // Each open popup's tab and the tab that opened it (the Mac's PagePool.popupOpeners).
    std::map<std::string, std::string> popupOpeners_;
    bool firstPageMade_ = false;
    bool pageLoading_ = false, pageLoaded_ = false;
    ULONGLONG closeAskedAt_ = 0;  // when the smoke test asked the window to close
#endif
};

}  // namespace kite

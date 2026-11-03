// See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <utility>

#include "core/CommandBar.h"
#include "core/LiveTabPolicy.h"
#include "core/OKLab.h"
#include "core/Sidebar.h"
#include "core/SpaceSwipe.h"
#include "core/TitleBar.h"
#include "shell/Capture.h"
#ifdef KITE_HAS_CEF
#include "shell/Chromium.h"
#endif
#include "shell/Errors.h"
#include "shell/Keys.h"
#include "shell/Text.h"

namespace kite {

namespace {

constexpr UINT_PTR kSmokeTimer = 1;
// The auto-archive's pass, every 15 minutes as on the Mac (AppDelegate's archiveTimer).
constexpr UINT_PTR kArchiveTimer = 2;
constexpr UINT kArchiveIntervalMs = 15 * 60 * 1000;
// Posted by the favicon worker when icons arrive (Favicons.h).
constexpr UINT kFaviconsMessage = WM_APP + 4;
// Posted by the frame clock once a composition frame while something animates.
constexpr UINT kFrameMessage = WM_APP + 5;

// Puts text on the clipboard as Unicode text. False when the clipboard couldn't be had.
bool CopyText(HWND owner, const std::wstring& text) {
    if (!OpenClipboard(owner)) return false;
    bool copied = false;
    if (EmptyClipboard()) {
        const size_t bytes = (text.size() + 1) * sizeof(wchar_t);
        if (HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes)) {
            if (void* data = GlobalLock(memory)) {
                std::memcpy(data, text.c_str(), bytes);
                GlobalUnlock(memory);
                copied = SetClipboardData(CF_UNICODETEXT, memory) != nullptr;
            }
            if (!copied) GlobalFree(memory);  // the clipboard owns it only once it's set
        }
    }
    CloseClipboard();
    return copied;
}

// Puts `top` (premultiplied BGRA) over `base` with its top-left at `origin`, as
bool Inked(const Pixels& pixels) {
    for (size_t i = 3; i < pixels.bgra.size(); i += 4) {
        if (pixels.bgra[i] != 0) return true;
    }
    return false;
}

}  // namespace

std::unique_ptr<BrowserWindowController> BrowserWindowController::Create(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts,
                                                                          Options options, std::function<void()> save,
                                                                          std::wstring& error) {
    // The GPU first: everything is set up before the window shows, so it never appears empty
    // or with the wrong title bar.
    std::unique_ptr<Renderer> renderer = Renderer::Create(error);
    if (!renderer) {
        error = L"Kite couldn't start Direct3D: " + error;
        return nullptr;
    }
    if (!MainWindow::RegisterWindowClass(instance)) {
        error = L"RegisterClassExW failed";
        return nullptr;
    }
    std::unique_ptr<BrowserWindowController> controller(
        new BrowserWindowController(instance, state, std::move(shortcuts), options, std::move(save), std::move(renderer)));
    if (!controller->window_.IsValid()) {
        error = L"CreateWindowExW failed";
        return nullptr;
    }
    if (error = controller->Init(); !error.empty()) return nullptr;
    return controller;
}

BrowserWindowController::BrowserWindowController(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts, Options options,
                                                 std::function<void()> save, std::unique_ptr<Renderer> renderer)
    : instance_(instance),
      state_(state),
      shortcuts_(std::move(shortcuts)),
      options_(options),
      save_(std::move(save)),
      renderer_(std::move(renderer)),
      window_(instance),
      themeFrom_(state.SelectedSpace().theme),
      themeTo_(themeFrom_),
      shownSpaceID_(state.SelectedSpace().id) {}

BrowserWindowController::~BrowserWindowController() {
    // The views and the compositor go before the window: it stops calling into them first.
    window_.onClose = nullptr;
    window_.onSize = nullptr;
    window_.onFocus = nullptr;
    window_.onWake = nullptr;
    window_.onMinimize = nullptr;
    window_.onMove = nullptr;
    window_.mayClose = nullptr;
    window_.hitTest = nullptr;
    window_.filter = nullptr;
}

std::wstring BrowserWindowController::Init() {
    std::wstring error;
    // The backdrop: the selected space's theme over the system's acrylic, or over a solid
    // colour where there's none. A capture always uses the solid colour, so it doesn't depend
    // on what's behind the window. Drawn now and then only when something changes; W9 adds
    // the space-switch crossfade.
    systemBackdrop_ = !options_.capture && window_.UseSystemBackdrop();
    const bool dark = !PrefersDarkForeground(themeTo_);
    dark_ = !dark;  // so the first ApplyAppearance applies
    ApplyAppearance(themeTo_);
    clock_ = std::make_unique<FrameClock>(window_.Handle(), kFrameMessage);
    compositor_ = Compositor::Create(window_.Handle(), *renderer_, error);
    if (!compositor_) return L"Kite couldn't start DirectComposition: " + error;

    // The sidebar, over the backdrop: what the session lists, with favicons fetched off the UI
    // thread (none in a capture, which mustn't depend on the network).
    if (!options_.capture) favicons_ = Favicons::Create(window_.Handle(), kFaviconsMessage);
    sidebar_ = SidebarView::Create(window_.Handle(), favicons_.get(), error);
    if (!sidebar_) return L"Kite couldn't make the sidebar: " + error;
    sidebar_->UseCompositor(compositor_.get());
    sidebar_->Layout(static_cast<float>(kSidebarWidth), window_.Dpi());
    sidebar_->Update(state_);

    // Windows' minimize, maximize and close buttons, top-right over the backdrop (the window
    // has no caption), and where dragging moves the window.
    caption_ = CaptionButtonsView::Create(window_.Handle(), error);
    if (!caption_) return L"Kite couldn't make the caption buttons: " + error;
    caption_->UseCompositor(compositor_.get());
    caption_->Layout(window_.Dpi());
    caption_->SetDark(dark);
    window_.hitTest = [this](float x, float y) {
        RECT client{};
        GetClientRect(window_.Handle(), &client);
        const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
        return TitleBarAreaAt(static_cast<float>(client.right) / scale, static_cast<float>(kSidebarWidth), x, y, scale);
    };

    // The command bar (Ctrl+T), over everything in the window.
    CommandBarView::Callbacks bar;
    bar.suggestions = [this](std::string_view text, CommandBarMode mode) { return CommandBarSuggestions(text, state_, mode); };
    bar.commit = [this](const CommandSuggestion& row, CommandBarMode mode) { Commit(row, mode); };
    bar.opened = [this] {
        BlockPages(true);
        sidebar_->ClearHover();  // the bar takes the pointer while it's open
    };
    bar.closed = [this] { BlockPages(false); };
    bar.dpi = [this] { return window_.Dpi(); };
    commandBar_ = CommandBarView::Create(window_.Handle(), std::move(bar), error);
    if (commandBar_) commandBar_->UseCompositor(compositor_.get());
    else {
        barError_ = error;
        OutputDebugStringW((L"Kite: no command bar: " + error + L"\n").c_str());
    }

    window_.onSize = [this] { OnSize(); };
    // A hover's redraw found the GPU gone: rebuild and draw everything.
    caption_->onDeviceLost = [this] { Draw(); };

    // The sidebar's clicks (the Mac's row taps and the header's buttons).
    SidebarView::Actions actions;
    actions.selectTab = [this](const std::string& id) {
        state_.Select(id);
        SelectionMoved();
    };
    actions.setFolderExpanded = [this](const std::string& id, bool expanded) {
        state_.SetFolderExpanded(id, expanded);
        StateChanged();
    };
    actions.togglePinnedSection = [this](const std::string& spaceID) {
        TogglePinnedSection(state_, spaceID);
        StateChanged();
    };
    actions.newTab = [this] { OpenCommandBar(CommandBarMode::NewTab); };
    // The Mac's field action: the bar edits the page's address, or opens a new tab with none.
    actions.editAddress = [this] { OpenCommandBar(CommandBarMode::EditCurrent); };
    actions.closeTab = [this](const std::string& id) { CloseTab(id); };
    sidebar_->SetActions(std::move(actions));

    MakeCommands();
    // Every command the table can name does something: a test run fails on one that doesn't.
    if (options_.smokeTest || options_.capture) {
        for (const ShortcutCommand& command : ShortcutCommands()) {
            if (!commands_.contains(command.id)) return L"the shortcut command " + Widen(command.id) + L" does nothing";
        }
    }
    window_.filter = [this](UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
        return Filter(message, wParam, lParam, result);
    };
    // Closing the window, and logoff or shutdown (which skip WM_CLOSE): what the pages
    // reported runs first (titles, addresses), then the caller saves.
    window_.onClose = [this] {
        RunPending();
        if (save_) save_();
    };
    return {};
}

void BrowserWindowController::ApplyAppearance(const Theme& theme) {
    const bool dark = !PrefersDarkForeground(theme);
    if (dark == dark_) return;
    dark_ = dark;
    window_.SetDarkAppearance(dark);
    base_ = systemBackdrop_ ? Rgba{} : MaterialFallback(dark);
    if (caption_) caption_->SetDark(dark);
}

// MARK: Spaces

void BrowserWindowController::SetTheme(const Theme& theme) {
    if (theme == themeTo_) return;
    const double now = FrameClock::Now();
    // Interrupted mid-fade: continue from whichever side was showing more.
    if (themeStart_ && now - *themeStart_ < space_motion::kThemeDuration / 2) themeTo_ = themeFrom_;
    themeFrom_ = themeTo_;
    themeTo_ = theme;
    themeStart_ = now;
    clock_->Start();
}

float BrowserWindowController::ThemeProgress(double time) {
    if (!themeStart_) return 1;
    const double elapsed = std::max(time - *themeStart_, 0.0);
    if (elapsed >= space_motion::kThemeDuration) {
        themeStart_.reset();
        themeFrom_ = themeTo_;
        return 1;
    }
    return static_cast<float>(ThemeCrossfadeProgress(elapsed));
}

void BrowserWindowController::SyncSpace() {
    const Space& space = state_.SelectedSpace();
    ApplyAppearance(space.theme);
    SetTheme(space.theme);
    if (space.id == shownSpaceID_) return;
    if (auto old = state_.SpaceIndex(shownSpaceID_)) SpaceChanged(*old, state_.SelectedSpaceIndex());
    shownSpaceID_ = space.id;
}

void BrowserWindowController::SpaceChanged(size_t old, size_t now) {
    // A switch from the keyboard slides the pages, as Arc's do: the new page comes in from the
    // side it lies on, the page left behind built until they're at rest.
    if (old == now) return;
    settling_.reset();
    pagesAnchor_ = state_.spaces[old].id;
    pageOffset_ = (now > old ? 1.0 : -1.0) * kSidebarWidth;
    sidebar_->SetPageOffset(static_cast<float>(pageOffset_));
    SettlePages();
}

void BrowserWindowController::SettlePages() {
    if (pageOffset_ == 0) return FinishSettling();
    // No sidebar on screen to time frames from: just land.
    if (!IsWindowVisible(window_.Handle()) || IsIconic(window_.Handle())) {
        pageOffset_ = 0;
        sidebar_->SetPageOffset(0);
        return FinishSettling();
    }
    settling_ = Settle{pageOffset_, 0, FrameClock::Now()};
    clock_->Start();
}

void BrowserWindowController::FinishSettling() {
    settling_.reset();
    // At rest: the new space's neighbours are built, the page left behind goes.
    if (!pagesAnchor_) return;
    pagesAnchor_.reset();
    sidebar_->Update(state_);
}

void BrowserWindowController::Frame(double time) {
    if (settling_) {
        // Arc's page slide: a critically damped spring, stepped once a frame for the frame
        // being made, so the strip is where the spring is when it reaches the screen.
        const double left = SpaceSwipe::Settle(settling_->from - settling_->to, time - settling_->start, space_motion::kPageResponse);
        pageOffset_ = settling_->to + left;
        sidebar_->SetPageOffset(static_cast<float>(pageOffset_));
        if (left == 0) FinishSettling();
    }
    const std::optional<double> crossfading = themeStart_;
    DrawAt(time, nullptr);
    if (options_.frameLog) {
        const double theme = crossfading ? ThemeCrossfadeProgress(std::max(time - *crossfading, 0.0)) : 1;
        frames_.push_back(LoggedFrame{time, pageOffset_, theme});
    }
    if (!settling_ && !themeStart_) clock_->Stop();
}

std::wstring BrowserWindowController::SaveFrameLog(const std::filesystem::path& file) const {
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    if (!out) return L"couldn't open " + file.wstring();
    const double first = frames_.empty() ? 0 : frames_.front().time;
    char line[128];
    for (const LoggedFrame& frame : frames_) {
        std::snprintf(line, sizeof line, "{\"t\":%.6f,\"offset\":%.4f,\"theme\":%.6f}\n", frame.time - first, frame.offset, frame.theme);
        out << line;
    }
    out.flush();
    return out ? std::wstring{} : L"couldn't write " + file.wstring();
}

// MARK: The session and the pages

void BrowserWindowController::StateChanged() {
    SyncSpace();
    sidebar_->Update(state_, pagesAnchor_);
    if (commandBar_) commandBar_->Refresh();
}

void BrowserWindowController::SelectionMoved() {
    ShowPage();
    StateChanged();
}

void BrowserWindowController::ShowPage() {
#ifdef KITE_HAS_CEF
    if (chromium_) ShowSelectedTab();
#endif
}

void BrowserWindowController::LoadInTab(const std::string& tabID, const std::string& url) {
#ifdef KITE_HAS_CEF
    // kite:// pages are drawn by the window, never loaded (the Mac's InternalPage).
    if (!chromium_ || url.starts_with("kite:")) return;
    // A tab whose page closed itself (an unloaded pinned tab) gets a new one.
    if (!chromium_->Navigate(tabID, url)) ShowSelectedTab();
#else
    (void)tabID;
    (void)url;
#endif
}

void BrowserWindowController::PageGone(const std::string& tabID) {
#ifdef KITE_HAS_CEF
    if (!chromium_) return;
    chromium_->Close(tabID);
    // A closed page can't be anyone's opener or popup again.
    std::erase_if(popupOpeners_, [&](const auto& entry) { return entry.first == tabID || entry.second == tabID; });
#else
    (void)tabID;
#endif
}

void BrowserWindowController::BlockPages(bool blocked) {
#ifdef KITE_HAS_CEF
    if (!chromium_) return;
    chromium_->BlockInput(blocked);
    if (!blocked) chromium_->Focus();
#else
    (void)blocked;
#endif
}

// MARK: The command bar

CommandBarView::Look BrowserWindowController::BarLook() const {
    const Theme& selected = state_.SelectedSpace().theme;
    return CommandBarView::Look{!PrefersDarkForeground(selected), Accent(selected)};
}

void BrowserWindowController::OpenCommandBar(CommandBarMode mode) {
    if (!commandBar_) return BlockPages(false);
    const Tab* tab = state_.SelectedTab();
    if (!tab) mode = CommandBarMode::NewTab;
    commandBar_->Show(mode, mode == CommandBarMode::EditCurrent ? tab->url.value_or("") : "", BarLook());
}

void BrowserWindowController::Commit(const CommandSuggestion& row, CommandBarMode mode) {
    // The Mac's BrowserWindowController.commit and open(_:mode:).
    switch (row.kind) {
    case CommandSuggestion::Kind::Open:
    case CommandSuggestion::Kind::Search:
        if (mode == CommandBarMode::EditCurrent && state_.SelectedTab()) {
            const std::string id = state_.SelectedTab()->id;
            if (auto at = state_.Location(id)) {
                if (Tab* tab = state_.TabAt(*at)) tab->url = row.url;
            }
            LoadInTab(id, row.url);
        } else {
            state_.OpenTab(row.url);
            ShowPage();
        }
        break;
    case CommandSuggestion::Kind::SwitchTab:
        if (state_.Location(row.tabID)) {
            state_.Select(row.tabID);
            ShowPage();
        }
        break;
    }
    StateChanged();
}

// MARK: Commands

void BrowserWindowController::CloseTab(std::string id) {
    if (state_.Close(id) == CloseOutcome::NotFound) return;
    // The next page shows first and the closed one hides in the same pass, so the card is
    // never empty in between; then the closed page goes.
    ShowPage();
    PageGone(id);
    StateChanged();
}

void BrowserWindowController::ArchiveTab() {
    // Ctrl+W: the open command bar closes first, else the selected tab.
    if (commandBar_ && commandBar_->IsOpen()) commandBar_->Hide();
    else if (const Tab* tab = state_.SelectedTab()) CloseTab(tab->id);
    else MessageBeep(MB_OK);
}

void BrowserWindowController::ReopenClosedTab() {
    if (state_.ReopenLastClosed()) SelectionMoved();
}

void BrowserWindowController::MakeCommands() {
    // What each shortcut's command does: the Mac's menu items of the same ids (MainMenu.swift).
    commands_ = {
        {"newTab", [this] { OpenCommandBar(CommandBarMode::NewTab); }},
        {"openLocation", [this] { OpenCommandBar(CommandBarMode::EditCurrent); }},
        {"archiveTab", [this] { ArchiveTab(); }},
        {"reopenClosedTab", [this] { ReopenClosedTab(); }},
        // One window, so closing it quits, as the Mac's last window does with Kite set so.
        {"closeWindow", [this] { PostMessageW(window_.Handle(), WM_CLOSE, 0, 0); }},
        {"quitKite", [this] { PostMessageW(window_.Handle(), WM_CLOSE, 0, 0); }},
        {"minimize", [this] { ShowWindow(window_.Handle(), SW_MINIMIZE); }},
        // The Mac's copyURL (its "Copied Current URL" toast comes with toasts).
        {"copyCurrentURL",
         [this] {
             const Tab* tab = state_.SelectedTab();
             if (!tab || !tab->url || !CopyText(window_.Handle(), Widen(*tab->url))) MessageBeep(MB_OK);
         }},
        {"collapsePinnedSection",
         [this] {
             TogglePinnedSection(state_, state_.SelectedSpace().id);
             StateChanged();
         }},
        // The Mac's viewSource: the page's source in a new tab.
        {"viewSource",
         [this] {
             const Tab* tab = state_.SelectedTab();
             if (!tab || !tab->url || tab->url->starts_with("kite:") || tab->url->starts_with("view-source:")) {
                 MessageBeep(MB_OK);
                 return;
             }
             state_.OpenTab("view-source:" + *tab->url);
             SelectionMoved();
         }},
        {"nextTab",
         [this] {
             state_.SelectAdjacentTab(1);
             SelectionMoved();
         }},
        {"previousTab",
         [this] {
             state_.SelectAdjacentTab(-1);
             SelectionMoved();
         }},
        {"nextSpace",
         [this] {
             state_.SelectAdjacentSpace(1);
             SelectionMoved();
         }},
        {"previousSpace",
         [this] {
             state_.SelectAdjacentSpace(-1);
             SelectionMoved();
         }},
        // As the Mac: with no page, Back, Forward, Refresh and Stop do nothing; Developer
        // Tools beeps.
        {"goBack", [this] { PageCommand("goBack"); }},
        {"goForward", [this] { PageCommand("goForward"); }},
        {"reloadPage", [this] { PageCommand("reloadPage"); }},
        {"forceReloadPage", [this] { PageCommand("forceReloadPage"); }},
        {"stopLoading", [this] { PageCommand("stopLoading"); }},
        {"developerTools",
         [this] {
             if (!PageCommand("developerTools")) MessageBeep(MB_OK);
         }},
    };
    for (int n = 1; n <= 9; ++n) {
        commands_[n == 9 ? "lastTab" : "tab" + std::to_string(n)] = [this, n] {
            state_.SelectTabNumber(n);
            SelectionMoved();
        };
        commands_["space" + std::to_string(n)] = [this, n] {
            state_.SelectSpaceAt(static_cast<size_t>(n - 1));
            SelectionMoved();
        };
    }
}

void BrowserWindowController::RunCommand(const std::string& command) {
    if (auto it = commands_.find(command); it != commands_.end()) it->second();
}

bool BrowserWindowController::PageCommand(const std::string& command) {
#ifdef KITE_HAS_CEF
    if (!chromium_) return false;
    using Action = Chromium::PageAction;
    static const std::map<std::string, Action, std::less<>> actions{
        {"goBack", Action::Back},
        {"goForward", Action::Forward},
        {"reloadPage", Action::Reload},
        {"forceReloadPage", Action::ReloadIgnoringCache},
        {"stopLoading", Action::Stop},
        {"developerTools", Action::DevTools},
    };
    auto it = actions.find(command);
    return it != actions.end() && chromium_->Act(it->second);
#else
    (void)command;
    return false;
#endif
}

// MARK: Drawing

void BrowserWindowController::DropCompositor() {
    // The views let go of the compositor's device first, then the compositor goes (so the
    // next draw rebuilds it).
    sidebar_->UseCompositor(nullptr);
    caption_->UseCompositor(nullptr);
    if (commandBar_) commandBar_->UseCompositor(nullptr);
    compositor_.reset();
}

std::wstring BrowserWindowController::Rebuild() {
    // After the GPU is reset or removed, both are rebuilt on whatever adapter is there now.
    std::wstring problem;
    DropCompositor();  // first: a window holds one composition target at a time
    renderer_ = Renderer::Create(problem);
    if (renderer_) compositor_ = Compositor::Create(window_.Handle(), *renderer_, problem);
    if (compositor_) {
        sidebar_->UseCompositor(compositor_.get());
        caption_->UseCompositor(compositor_.get());
        if (commandBar_) commandBar_->UseCompositor(compositor_.get());
    }
    return problem;
}

std::wstring BrowserWindowController::Draw(Pixels* readBack) { return DrawAt(FrameClock::Now(), readBack); }

std::wstring BrowserWindowController::DrawAt(double time, Pixels* readBack) {
    const float progress = ThemeProgress(time);
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    const UINT width = static_cast<UINT>(client.right), height = static_cast<UINT>(client.bottom);
    std::wstring problem;
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (!compositor_ || compositor_->DeviceLost() || sidebar_->DeviceLost() || caption_->DeviceLost()) {
            if (problem = Rebuild(); !problem.empty()) break;
        }
        problem = compositor_->Draw(
            width, height, MakeThemeUniforms(themeFrom_, themeTo_, progress, static_cast<float>(width), static_cast<float>(height)),
            base_, readBack);
        // The sidebar and the buttons with it, shown together at the commit.
        if (problem.empty()) problem = sidebar_->Draw();
        if (problem.empty()) problem = caption_->Draw();
        if (problem.empty()) compositor_->Commit();
        if (!compositor_->DeviceLost() && !sidebar_->DeviceLost() && !caption_->DeviceLost()) break;
    }
    if (!problem.empty()) OutputDebugStringW((L"Kite: drawing failed: " + problem + L"\n").c_str());
    return problem;
}

void BrowserWindowController::OnSize() {
#ifdef KITE_HAS_CEF
    // The page first, so CEF's thread moves it while Kite draws.
    if (chromium_) chromium_->SetBounds(ContentBounds());
#endif
    sidebar_->Layout(static_cast<float>(kSidebarWidth), window_.Dpi());
    caption_->Layout(window_.Dpi());
    Draw();
    if (commandBar_) commandBar_->Layout();
#ifdef KITE_HAS_CEF
    if (chromium_) {
        chromium_->WindowMoved();
        ShowFirstPage();  // restored after a minimized launch
    }
#endif
}

// MARK: The window's messages

bool BrowserWindowController::Filter(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    // The caption buttons' presses, whatever else is open.
    if (caption_->HandleMessage(message, wParam, lParam, result)) return true;
#ifdef KITE_HAS_CEF
    // A key typed straight after Ctrl+T in a page can come before Chromium's note that Ctrl+T
    // was pressed: it opens the bar itself, and the note then finds it open.
    if ((message == WM_KEYDOWN || message == WM_CHAR) && commandBar_ && !commandBar_->IsOpen() && chromium_ &&
        chromium_->KeysComeToKite()) {
        OpenCommandBar(CommandBarMode::NewTab);
    }
#endif
    if ((message == WM_CHAR || message == WM_SYSCHAR) && dropCharacter_) {
        dropCharacter_ = false;
        result = 0;
        return true;
    }
    // A key that made no character: its key-up ends the wait for one.
    if (message == WM_KEYUP || message == WM_SYSKEYUP) dropCharacter_ = false;
    // Kite's shortcuts, wherever the keyboard is in Kite's own window, the bar's field included
    // (as the Mac's menus come before its field editor), but for keys the field edits with
    // (Alt+Left). Alt's come as WM_SYSKEYDOWN. A page's come through Chromium.
    if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
        dropCharacter_ = false;
        const auto pressed =
            ShortcutOfKey(static_cast<UINT>(wParam), GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_MENU) < 0, GetKeyState(VK_SHIFT) < 0);
        const ShortcutTarget* target = pressed ? FindShortcut(shortcuts_, *pressed) : nullptr;
        if (target && !(commandBar_ && commandBar_->IsOpen() && EditsText(*pressed))) {
            // The character TranslateMessage made of it goes too (Alt+K's WM_SYSCHAR would beep).
            dropCharacter_ = true;
            RunCommand(target->command->id);  // a held key repeats it, as the Mac's menus do
            result = 0;
            return true;
        }
    }
    if (commandBar_ && commandBar_->HandleMessage(message, wParam, lParam, result)) {
        if (message == WM_LBUTTONDOWN) sidebar_->ForgetActivation();
        return true;
    }
    if (sidebar_->HandleMouse(message, wParam, lParam)) return true;
    // The caption buttons' appearance changes with the sidebar's, at its commit.
    if (message == SidebarView::kRedrawMessage) {
        if (std::wstring problem = caption_->Draw(); !problem.empty()) {
            OutputDebugStringW((L"Kite: the caption buttons couldn't draw: " + problem + L"\n").c_str());
        }
    }
    if (sidebar_->HandleMessage(message)) {
        // Its own redraw found the GPU gone: the window's draw rebuilds everything.
        if (sidebar_->DeviceLost() || caption_->DeviceLost()) Draw();
        return true;
    }
    if (message == WM_TIMER && wParam == kArchiveTimer) {
        if (auto interval = state_.ArchiveAfterSeconds()) {
            for (const Tab& tab : state_.ArchiveStaleTabs(*interval)) PageGone(tab.id);
            StateChanged();
        }
        return true;
    }
    if (message == kFrameMessage) {
        clock_->Delivered();
        if (clock_->Running()) Frame(FrameClock::NextFrameTime(compositor_ ? compositor_->Device() : nullptr));
        return true;
    }
    if (message == kFaviconsMessage) {
        if (favicons_ && favicons_->TakeResults()) sidebar_->Invalidate();
        return true;
    }
    return false;
}

void BrowserWindowController::RunPending() {
#ifdef KITE_HAS_CEF
    if (chromium_) chromium_->RunPending();
#endif
}

void BrowserWindowController::Show(int showCommand, bool behindOtherWindows) {
    // Quiet runs open behind other windows without focus, and ignore a launcher's "start maximized".
    if (behindOtherWindows) window_.ShowBehindOtherWindows();
    else window_.Show(showCommand);
#ifdef KITE_HAS_CEF
    ShowFirstPage();
#endif
    // The auto-archive's later passes (the launch's ran before the window). A capture never archives.
    if (!options_.capture) SetTimer(window_.Handle(), kArchiveTimer, kArchiveIntervalMs, nullptr);
}

// MARK: Tests

std::wstring BrowserWindowController::SmokeTest() {
    // The command bar opens over the window, draws with text in it, and closes.
    if (!commandBar_) return L"Kite couldn't make the command bar";
    commandBar_->Show(CommandBarMode::NewTab, "", BarLook());
    commandBar_->Type("kite smoke");
    if (std::wstring problem = commandBar_->Draw(); !problem.empty()) return L"the command bar couldn't draw: " + problem;
    commandBar_->Hide();
    // The sidebar draws what the session lists (something, not a blank surface).
    Pixels chrome;
    if (std::wstring problem = sidebar_->Draw(&chrome); !problem.empty()) return L"the sidebar couldn't draw: " + problem;
    if (!Inked(chrome)) return L"the sidebar drew nothing";
    // And the caption buttons their glyphs.
    Pixels buttons;
    if (std::wstring problem = caption_->Draw(&buttons); !problem.empty()) return L"the caption buttons couldn't draw: " + problem;
    if (!Inked(buttons)) return L"the caption buttons drew nothing";
    // Switching spaces: the pages slide and the theme crossfades, and both come to rest on the
    // next space, then back on this one.
    if (state_.spaces.size() > 1) {
        const std::string before = state_.SelectedSpace().id;
        RunCommand("nextSpace");
        if (!settling_ || pageOffset_ != kSidebarWidth) return L"Next Space didn't slide the pages";
        Frame(FrameClock::Now() + 1);
        if (settling_ || pageOffset_ != 0 || pagesAnchor_ || themeStart_ || themeFrom_ != state_.SelectedSpace().theme) {
            return L"Next Space didn't come to rest";
        }
        RunCommand("previousSpace");
        Frame(FrameClock::Now() + 1);
        if (state_.SelectedSpace().id != before || settling_ || pageOffset_ != 0) return L"Previous Space didn't come back";
        frames_.clear();
    }
    // The lost-GPU path, once: the renderer, swap chain and composition target are rebuilt and
    // draw again (a real device removal can't be caused from a test).
    DropCompositor();
    if (std::wstring problem = Draw(); !problem.empty()) return L"Kite couldn't rebuild its renderer: " + problem;
    // With Chromium it waits for the first page instead, for at most 30 s.
    UINT smokeMs = 1000;
#ifdef KITE_HAS_CEF
    if (chromium_) smokeMs = 30'000;
#endif
    SetTimer(window_.Handle(), kSmokeTimer, smokeMs, [](HWND hwnd, UINT, UINT_PTR, DWORD) { PostMessageW(hwnd, WM_CLOSE, 0, 0); });
    return {};
}

std::wstring BrowserWindowController::Capture(Pixels& pixels, const std::optional<std::string>& barText) {
    // The window's own frame, read back as it's presented: at the window's scale.
    std::wstring problem = Draw(&pixels);
    if (problem.empty()) {
        // The sidebar's surface over the backdrop, at the window's top-left.
        Pixels chrome;
        problem = sidebar_->Draw(&chrome);
        if (problem.empty()) ComposeOver(pixels, chrome, POINT{0, 0});
    }
    if (problem.empty()) {
        Pixels buttons;
        POINT origin{};
        problem = caption_->Draw(&buttons, &origin);
        if (problem.empty()) ComposeOver(pixels, buttons, origin);
    }
    if (problem.empty() && barText) {
        // The bar as Ctrl+T opens it, with the text typed in.
        if (!commandBar_) return L"Kite couldn't make the command bar";
        commandBar_->Show(CommandBarMode::NewTab, "", BarLook());
        commandBar_->Type(*barText);
        Pixels bar;
        POINT origin{};
        problem = commandBar_->Draw(&bar, &origin);
        if (problem.empty()) ComposeOver(pixels, bar, origin);
    }
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    if (problem.empty() && (pixels.width != static_cast<UINT>(client.right) || pixels.height != static_cast<UINT>(client.bottom))) {
        problem = L"the frame isn't the window's size";
    }
    return problem;
}

void BrowserWindowController::RunMessageLoop() {
    // Messages, and the GPU's device-removed signal so a lost device is rebuilt even while
    // nothing is drawing (the composition would otherwise stay blank until the next resize).
    // If a rebuild failed (no adapter yet, mid driver update), it's retried every second for a
    // minute; after that only a resize retries, so a machine with no usable GPU doesn't wake
    // Kite every second for good.
    constexpr ULONGLONG kRetryForMs = 60'000;
    ULONGLONG retryUntil = 0;
    for (bool running = true; running;) {
        HANDLE removed = renderer_ && compositor_ ? renderer_->DeviceRemovedEvent() : nullptr;
        DWORD timeout = INFINITE;
        if (!compositor_) {
            const ULONGLONG now = GetTickCount64();
            if (!retryUntil) retryUntil = now + kRetryForMs;
            if (now < retryUntil) timeout = 1000;
        } else {
            retryUntil = 0;
        }
        const DWORD woke =
            MsgWaitForMultipleObjectsEx(removed ? 1 : 0, removed ? &removed : nullptr, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if ((removed && woke == WAIT_OBJECT_0) || woke == WAIT_TIMEOUT) {
            if (renderer_ && compositor_) {
                const HRESULT reason = renderer_->Device()->GetDeviceRemovedReason();
                OutputDebugStringW(HResultMessage(L"Kite: the GPU device was removed", reason).append(L"\n").c_str());
            }
            DropCompositor();  // forces Draw() to rebuild
            Draw();
            continue;
        }
        MSG message;
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            if (message.message == WM_QUIT) {
                running = false;
                break;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
}

#ifdef KITE_HAS_CEF

// MARK: Chromium

RECT BrowserWindowController::ContentBounds() const {
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    const int dpi = static_cast<int>(window_.Dpi());
    auto px = [dpi](int points) { return MulDiv(points, dpi, USER_DEFAULT_SCREEN_DPI); };
    // Its top under the caption buttons.
    RECT card{px(kSidebarWidth), px(static_cast<int>(title_bar::kContentTop)), client.right - px(kContentInset),
              client.bottom - px(kContentInset)};
    card.right = std::max(card.right, card.left + 1);
    card.bottom = std::max(card.bottom, card.top + 1);
    return card;
}

void BrowserWindowController::ShowSelectedTab() {
    const Tab* tab = state_.SelectedTab();
    // No tab: the card shows through (the Mac's "Press ⌘T to open a tab" comes later).
    if (!tab) return chromium_->ShowNothing();
    // As the Mac's makePage: the tab's address, or a blank page for none or for one of Kite's
    // own pages (kite://, which come later).
    std::string url = tab->url.value_or("");
    if (url.starts_with("kite:")) url.clear();
    chromium_->Show(tab->id, state_.SelectedProfileDirectory(), url, ContentBounds());
}

void BrowserWindowController::ShowFirstPage() {
    // The first page is made once the window is on screen and not minimized. Made while the
    // window was still hidden, it came up hidden for good (an empty card until the first
    // click), and the first ShowWindow sends WM_SIZE before the window is visible; made while
    // minimized, it would lay out at 1×1.
    if (firstPageMade_ || !chromium_ || !IsWindowVisible(window_.Handle()) || IsIconic(window_.Handle())) return;
    firstPageMade_ = true;
    ShowSelectedTab();
}

Tab* BrowserWindowController::TabNamed(const std::string& id) {
    auto location = state_.Location(id);
    return location ? state_.TabAt(*location) : nullptr;
}

Chromium::StartResult BrowserWindowController::StartChromium(const std::filesystem::path& root, std::wstring& error) {
    PageEvents events;
    events.addressChanged = [this](const std::string& id, const std::string& url) {
        if (Tab* tab = TabNamed(id); tab && !url.empty()) tab->url = url;
        StateChanged();
    };
    events.titleChanged = [this](const std::string& id, const std::string& title) {
        // An empty title keeps the last one, as the Mac's BrowserStore does.
        if (Tab* tab = TabNamed(id); tab && !title.empty()) tab->title = title;
        StateChanged();
    };
    events.faviconChanged = [this](const std::string& id, const std::string& url) {
        Tab* tab = TabNamed(id);
        const std::optional<std::string> icon = url.empty() ? std::nullopt : std::optional<std::string>(url);
        if (!tab || tab->faviconURL == icon) return;
        tab->faviconURL = icon;
        StateChanged();
    };
    events.loadingChanged = [this](const std::string&, bool loading) {
        // A smoke test closes once the first page has loaded (or shown its error page).
        if (loading) {
            pageLoading_ = true;
        } else if (pageLoading_ && !pageLoaded_) {
            pageLoaded_ = true;
            if (options_.smokeTest) {
                closeAskedAt_ = GetTickCount64();
                PostMessageW(window_.Handle(), WM_CLOSE, 0, 0);
            }
        }
    };
    events.popupOpened = [this](const std::string& openerID, const std::string& id, const std::string& url) {
        // In the current space, as the Mac's openTab(id:url:). window.open('') has no address
        // yet, which the session keeps as none (the Mac's nil).
        state_.OpenTab(url.empty() ? std::nullopt : std::optional<std::string>(url), std::nullopt, true, Now(), id);
        popupOpeners_[id] = openerID;
        SelectionMoved();
    };
    events.openInNewTab = [this](const std::string&, const std::string& url, bool foreground) {
        // In the current space, as the Mac's openTab(url:select:).
        state_.OpenTab(url, std::nullopt, foreground);
        if (foreground) ShowSelectedTab();
        StateChanged();
    };
    events.pageClosed = [this](const std::string& id) {
        // A page that closed itself (window.close() after a sign-in): its tab closes, and a
        // popup on screen hands it back to its opener, as the Mac's PagePool does.
        const auto opener = popupOpeners_.extract(id);
        state_.PageClosedItself(id, opener ? std::optional<std::string>(opener.mapped()) : std::nullopt);
        std::erase_if(popupOpeners_, [&](const auto& entry) { return entry.second == id; });
        SelectionMoved();
    };
    // A popup and its opener keep their pages while both tabs exist; a page closed for the
    // limit can't be anyone's opener or popup again (the Mac's PagePool.discard).
    events.keepAlive = [this](const std::string& id) { return IsLinkedToPopup(popupOpeners_, state_, id); };
    events.pageDiscarded = [this](const std::string& id) {
        std::erase_if(popupOpeners_, [&](const auto& entry) { return entry.first == id || entry.second == id; });
    };
    events.shortcuts = shortcuts_;
    events.command = [this](const std::string& command) { RunCommand(command); };
    events.newTab = [this] {
        // Not when the bar has already opened for the keys typed after Ctrl+T and been closed
        // again (closing it gives the keys back to the pages).
        if (chromium_->KeysComeToKite()) OpenCommandBar(CommandBarMode::NewTab);
    };
    events.keyForwarded = [this](bool character, unsigned code, bool ctrl, bool shift) {
        if (!commandBar_) return;
        if (character) commandBar_->ForwardCharacter(static_cast<wchar_t>(code));
        else commandBar_->ForwardKey(code, ctrl, shift);
    };
    events.relaunched = [this] {
        // Kite was launched again: this one comes forward instead.
        if (IsIconic(window_.Handle())) ShowWindow(window_.Handle(), SW_RESTORE);
        SetForegroundWindow(window_.Handle());
    };
    if (const auto started = Chromium::Start(instance_, window_.Handle(), root, std::move(events), chromium_, error);
        started != Chromium::StartResult::Started) {
        return started;
    }
    window_.onWake = [this] { chromium_->RunPending(); };
    window_.onMinimize = [this] { chromium_->Minimized(); };
    window_.onMove = [this] { chromium_->WindowMoved(); };
    window_.mayClose = [this] { return chromium_->MayCloseWindow(); };
    window_.onFocus = [this] {
        // The open bar keeps the keyboard in Kite's window.
        if (!commandBar_ || !commandBar_->IsOpen()) chromium_->Focus();
    };
    return Chromium::StartResult::Started;
}

std::wstring BrowserWindowController::ShutDownChromium() {
    if (!chromium_) return {};
    // Every browser closed within the window's 5 s deadline and Chromium's shutdown wait,
    // rather than Chromium going down under one.
    const bool closedCleanly = chromium_->Shutdown();
    if (!options_.smokeTest) return {};
    if (!closedCleanly) return L"a browser didn't close in time; Chromium shut down under it";
    if (!pageLoaded_) return L"the first page didn't finish loading within 30 s";
    if (!chromium_->PagesCanBeHidden()) return L"a page had no Chromium widget window to hide: background tabs would keep drawing";
    // One WM_CLOSE must close the window (the browsers first); the 30 s timer's second one
    // would otherwise hide a close that hangs.
    if (GetTickCount64() - closeAskedAt_ > 5'000) {
        return L"the window took " + std::to_wstring((GetTickCount64() - closeAskedAt_) / 1000) + L" s to close";
    }
    return {};
}

#endif  // KITE_HAS_CEF

}  // namespace kite

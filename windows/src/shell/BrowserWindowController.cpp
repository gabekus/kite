// See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <utility>

#include "core/CommandBar.h"
#include "core/Json.h"
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
// When the pages' slide on the compositor has ended (its duration and a frame, rounded up).
constexpr UINT_PTR kSettleTimer = 3;
// The session's save, armed by a change (SaveSchedule) and gone once it fires: never idle.
constexpr UINT_PTR kSaveTimer = 4;
// Posted by the favicon worker when icons arrive (Favicons.h).
constexpr UINT kFaviconsMessage = WM_APP + 4;
// Posted by the frame clock once a composition frame while something animates.
constexpr UINT kFrameMessage = WM_APP + 5;
constexpr UINT kSpaceIconsMessage = WM_APP + 6;
// Posted by the memory watch (MemoryPressure.h), wParam the MemoryPressure level.
constexpr UINT kMemoryPressureMessage = WM_APP + 7;

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
bool Inked(const Pixels& pixels, UINT fromRow = 0) {
    for (size_t i = static_cast<size_t>(fromRow) * pixels.width * 4 + 3; i < pixels.bgra.size(); i += 4) {
        if (pixels.bgra[i] != 0) return true;
    }
    return false;
}

}  // namespace

std::unique_ptr<BrowserWindowController> BrowserWindowController::Create(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts,
                                                                          Options options, SessionWriter* writer,
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
        new BrowserWindowController(instance, state, std::move(shortcuts), options, writer, std::move(renderer)));
    if (!controller->window_.IsValid()) {
        error = L"CreateWindowExW failed";
        return nullptr;
    }
    if (error = controller->Init(); !error.empty()) return nullptr;
    return controller;
}

BrowserWindowController::BrowserWindowController(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts, Options options,
                                                 SessionWriter* writer, std::unique_ptr<Renderer> renderer)
    : instance_(instance),
      state_(state),
      shortcuts_(std::move(shortcuts)),
      options_(options),
      writer_(writer),
      renderer_(std::move(renderer)),
      window_(instance),
      theme_(state.SelectedSpace().theme),
      shownSpaceID_(state.SelectedSpace().id) {
    createdAt_ = FrameClock::Now();
}

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
    ApplyAppearance(theme_.to);
    clock_ = std::make_unique<FrameClock>(window_.Handle(), kFrameMessage);
    // Not in a capture, whose pages Chromium doesn't make.
    if (!options_.capture) {
        memoryWatch_ = std::make_unique<MemoryPressureWatch>(window_.Handle(), kMemoryPressureMessage);
        watchingMemory_ = memoryWatch_->IsWatching();
    }
    compositor_ = Compositor::Create(window_.Handle(), *renderer_, error);
    if (!compositor_) return L"Kite couldn't start DirectComposition: " + error;

    // The sidebar, over the backdrop: what the session lists, with favicons fetched off the UI
    // thread (none in a capture, which mustn't depend on the network).
    if (!options_.capture) favicons_ = Favicons::Create(window_.Handle(), kFaviconsMessage);
    sidebar_ = SidebarView::Create(window_.Handle(), favicons_.get(),
                                   SpaceIconPainter::Pictures{options_.spaceIcons, kSpaceIconsMessage, options_.capture}, error);
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
    caption_->SetDark(*dark_);
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
    // The space tip is a window of its own: it goes when the window moves or is minimized,
    // rather than stay where the cell was (or come back with the window). Chromium's start adds
    // its own to these.
    window_.onMove = [this] { sidebar_->HideTip(); };
    window_.onMinimize = [this] { sidebar_->HideTip(); };
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
    // A space's cell in the bar: that space, the pages sliding to it (the Mac's select(cell)).
    actions.selectSpace = [this](const std::string& spaceID) {
        state_.SelectSpace(spaceID);
        SelectionMoved();
    };
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
    // reported runs first (titles, addresses), then the session is saved at once. Closing
    // doesn't wait for the write (main.cpp does, once the window is gone); logoff and shutdown
    // can end the process as soon as WM_ENDSESSION returns, so that waits, for a bounded time.
    window_.onClose = [this](bool endingSession) {
        clock_->Stop();
        memoryWatch_.reset();
        RunPending();
        closing_ = true;
        SaveNow();
        if (endingSession && writer_) {
            if (std::string problem = writer_->Flush(kEndSessionFlush); !problem.empty()) {
                OutputDebugStringW((L"Kite: " + Widen(problem) + L"\n").c_str());
            }
        }
    };
    return {};
}

void BrowserWindowController::ApplyAppearance(const Theme& theme) {
    const bool dark = !PrefersDarkForeground(theme);
    if (dark_ == dark) return;
    dark_ = dark;
    window_.SetDarkAppearance(dark);
    base_ = systemBackdrop_ ? Rgba{} : MaterialFallback(dark);
    if (caption_) caption_->SetDark(dark);
}

// MARK: Spaces

void BrowserWindowController::SetTheme(const Theme& theme) {
    // Nothing on screen to fade: it's simply the new theme when the window shows again.
    if (!IsWindowVisible(window_.Handle()) || IsIconic(window_.Handle())) {
        if (theme != theme_.to || theme_.Fading()) theme_.Snap(theme);
        return;
    }
    if (theme_.Set(theme, FrameClock::Now())) clock_->Start();
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
    KillTimer(window_.Handle(), kSettleTimer);
    pagesAnchor_ = state_.spaces[old].id;
    const float from = (now > old ? 1.0f : -1.0f) * static_cast<float>(kSidebarWidth);
    // No sidebar on screen to slide: just land.
    const double duration =
        IsWindowVisible(window_.Handle()) && !IsIconic(window_.Handle()) ? sidebar_->SlidePages(from, 0) : 0;
    if (duration <= 0) {
        sidebarSliding_ = false;
        return FinishSettling();
    }
    // The compositor runs it; Kite only hears when it has ended.
    sidebarSliding_ = true;
    slideStarted_ = true;
    // The compositor starts it at the commit's frame, up to a frame after now: the timer allows
    // for one at 60 Hz.
    SetTimer(window_.Handle(), kSettleTimer, static_cast<UINT>(std::ceil(duration * 1000)) + 17, nullptr);
}

void BrowserWindowController::FinishSettling() {
    KillTimer(window_.Handle(), kSettleTimer);
    sidebarSliding_ = false;
    slideStarted_ = false;
    sidebar_->SetPageOffset(0);
    // At rest: the new space's neighbours are built, the page left behind goes.
    if (!pagesAnchor_) return;
    pagesAnchor_.reset();
    sidebar_->Update(state_);
}

bool BrowserWindowController::CommandEnabled(const std::string& command) const {
    // Space 1 to Space 9 (the Mac's validateMenuItem: no such space, no such item).
    if (command.size() == 6 && command.starts_with("space") && command[5] >= '1' && command[5] <= '9') {
        return static_cast<size_t>(command[5] - '0') <= state_.spaces.size();
    }
    return true;
}

void BrowserWindowController::Frame(double time) {
    ++frameCount_;
    lastFrameTime_ = time;
    // Minimized: nothing to draw into (OnSize draws the end of it on restore).
    if (!IsIconic(window_.Handle())) DrawAt(time, nullptr);
    else lastThemeProgress_ = theme_.Progress(time);
    if (options_.frameLog) {
        if (frames_.empty()) frames_.reserve(1024);
        frames_.push_back(LoggedFrame{FrameClock::Now(), time, sidebar_->PageOffset(), lastThemeProgress_});
    }
    if (!theme_.Fading()) {
        clock_->Stop();
        lastFrameTime_.reset();
    }
}

std::wstring BrowserWindowController::SaveFrameLog(const std::filesystem::path& file) const {
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    if (!out) return L"couldn't open " + file.wstring();
    const double first = frames_.empty() ? 0 : frames_.front().handled;
    char line[160];
    for (const LoggedFrame& frame : frames_) {
        std::snprintf(line, sizeof line, "{\"t\":%.6f,\"target\":%.6f,\"offset\":%.4f,\"theme\":%.6f}\n", frame.handled - first,
                      frame.target - first, frame.offset, frame.theme);
        out << line;
    }
    out.flush();
    return out ? std::wstring{} : L"couldn't write " + file.wstring();
}

std::wstring BrowserWindowController::SaveSaveLog(const std::filesystem::path& file) const {
    json::Array saves;
    for (const LoggedSave& save : saves_) {
        saves.push_back(json::Object{{"t", std::round(save.at * 1000) / 1000}, {"uiMicros", std::round(save.micros * 10) / 10},
                                     {"closing", save.closing}});
    }
    const double mean = saveCost_.saves ? saveCost_.totalMicros / static_cast<double>(saveCost_.saves) : 0.0;
    json::Array reports;
    for (const PressureReport& report : pressureReports_) {
        const char* name = report.level == MemoryPressure::Critical ? "critical" : report.level == MemoryPressure::Warning ? "warning" : "normal";
        reports.push_back(json::Object{{"t", std::round(report.at * 1000) / 1000}, {"level", name}, {"discarded", report.discarded}});
    }
    json::Object log{{"saves", json::Value(std::move(saves))},
                     {"frames", frameCount_},
                     {"uiMicros", json::Object{{"max", saveCost_.maxMicros}, {"mean", mean}}},
                     {"memoryPressure", json::Object{{"watching", watchingMemory_}, {"reports", json::Value(std::move(reports))}}}};
    if (writer_) {
        const SessionWriter::Statistics stats = writer_->Stats();
        log.emplace("writer", json::Object{{"handedOver", stats.handedOver},
                                           {"written", stats.written},
                                           {"unchanged", stats.unchanged},
                                           {"superseded", stats.superseded},
                                           {"backups", stats.backups},
                                           {"lastBytes", stats.lastBytes},
                                           {"lastEncodeMicros", stats.lastEncodeMicros},
                                           {"lastWriteMicros", stats.lastWriteMicros},
                                           {"lastError", stats.lastError},
                                           {"lastBackupError", stats.lastBackupError}});
    }
    std::ofstream out(file, std::ios::binary | std::ios::trunc);
    if (!out) return L"couldn't open " + file.wstring();
    out << json::Write(json::Value(std::move(log))) << '\n';
    out.flush();
    return out ? std::wstring{} : L"couldn't write " + file.wstring();
}

// MARK: The session and the pages

void BrowserWindowController::SessionChanged(SessionSaveDelay delay) {
    // A second after the last sidebar change; a page's title or favicon never pushes a waiting
    // save back (SaveSchedule). SetTimer with the same id replaces the waiting one. Nothing
    // when the session mustn't be saved (MaySave).
    if (!writer_ || !writer_->MaySave()) return;
    if (auto seconds = saveSchedule_.Changed(delay, FrameClock::Now())) {
        SetTimer(window_.Handle(), kSaveTimer, static_cast<UINT>(std::ceil(*seconds * 1000)), nullptr);
        ++saveArms_;
    }
}

void BrowserWindowController::SaveNow() {
    KillTimer(window_.Handle(), kSaveTimer);
    saveSchedule_.Saved();
    if (!writer_ || !writer_->MaySave()) return;
    // A copy for the writer's thread (the session is the UI thread's to change): the only cost
    // here. Encoding and the disk are the writer's.
    const auto start = std::chrono::steady_clock::now();
    writer_->Save(state_);
    const double micros = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
    ++saveCost_.saves;
    saveCost_.maxMicros = std::max(saveCost_.maxMicros, micros);
    saveCost_.totalMicros += micros;
    if (options_.saveLog) saves_.push_back(LoggedSave{FrameClock::Now() - createdAt_, micros, closing_});
}

void BrowserWindowController::StateChanged(std::optional<SessionSaveDelay> save) {
    if (save) SessionChanged(*save);
    SyncSpace();
    sidebar_->Update(state_, pagesAnchor_);
    // A slide begins at once: the new page and the caption buttons' appearance drawn and the
    // strip's animation committed now, not on the next pass (the crossfade's first frame comes
    // with the clock).
    if (slideStarted_) {
        slideStarted_ = false;
        std::wstring problem = sidebar_->Draw();
        if (problem.empty()) problem = caption_->Draw();
        if (problem.empty()) compositor_->Commit();
        else if (sidebar_->DeviceLost() || caption_->DeviceLost()) Draw();
    }
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

std::wstring BrowserWindowController::Draw(Pixels* readBack) {
    // Between the clock's frames (a resize mid-crossfade): the frame it last drew for, so the
    // fade doesn't step back.
    return DrawAt(lastFrameTime_.value_or(FrameClock::Now()), readBack);
}

std::wstring BrowserWindowController::DrawAt(double time, Pixels* readBack) {
    const float progress = theme_.Progress(time);
    lastThemeProgress_ = progress;
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    const UINT width = static_cast<UINT>(client.right), height = static_cast<UINT>(client.bottom);
    std::wstring problem;
    for (int attempt = 0; attempt < 2; ++attempt) {
        if (!compositor_ || compositor_->DeviceLost() || sidebar_->DeviceLost() || caption_->DeviceLost()) {
            if (problem = Rebuild(); !problem.empty()) break;
        }
        problem = compositor_->Draw(
            width, height, MakeThemeUniforms(theme_.from, theme_.to, progress, static_cast<float>(width), static_cast<float>(height)),
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
    // The space tip is a window of its own: it goes rather than stay where the cell was.
    sidebar_->HideTip();
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
        if (target && !(commandBar_ && commandBar_->IsOpen() && EditsText(*pressed)) && CommandEnabled(target->command->id)) {
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
    if (sidebar_->HandleMessage(message, wParam)) {
        // Its own redraw found the GPU gone: the window's draw rebuilds everything.
        if (sidebar_->DeviceLost() || caption_->DeviceLost()) Draw();
        return true;
    }
    if (message == WM_TIMER && wParam == kArchiveTimer) {
        if (auto interval = state_.ArchiveAfterSeconds()) {
            const std::vector<Tab> archived = state_.ArchiveStaleTabs(*interval);
            for (const Tab& tab : archived) PageGone(tab.id);
            if (!archived.empty()) {
                StateChanged();
            } else if (writer_ && writer_->MaySave() && !writer_->OfferBackup()) {
                // Nothing changed, so nothing to redraw or write; but the Mac's pass always
                // mutates, so its session saves and its hourly backup comes with it. The writer
                // offers that backup of what it last wrote, or, having written nothing yet this
                // run, the session is saved as a change would be.
                SessionChanged();
            }
        }
        return true;
    }
    if (message == kFrameMessage) {
        // Delivered after the frame: a frame that takes longer than the next tick doesn't queue
        // another behind it.
        if (clock_->Running()) Frame(FrameClock::NextFrameTime(compositor_ ? compositor_->Device() : nullptr));
        clock_->Delivered();
        return true;
    }
    if (message == WM_TIMER && wParam == kSaveTimer) {
        SaveNow();
        return true;
    }
    if (message == kMemoryPressureMessage) {
        // The Mac's watchMemoryPressure: the pages that aren't on screen close, if memory is
        // still low as the report is handled (a dip already over, seen at launch on a busy PC,
        // closes nothing). A test profile's --save-log run can post a report with lParam 1,
        // which skips that check, to drive the path without running the machine out of memory.
        const auto level = static_cast<MemoryPressure>(wParam);
        const bool forced = options_.saveLog && lParam == 1;
        const bool low = memoryWatch_ && memoryWatch_->IsLow();
        const bool discards = DiscardsPages(level) && (forced || low);
        // Over already: the watch waits for low again, so the next spell is reported.
        if (DiscardsPages(level) && !low && memoryWatch_) memoryWatch_->Recovered();
        if (options_.saveLog) pressureReports_.push_back({FrameClock::Now() - createdAt_, level, discards});
#ifdef KITE_HAS_CEF
        if (chromium_ && discards) chromium_->DiscardHiddenPages();
#endif
        return true;
    }
    // The pages' slide has ended on the compositor.
    if (message == WM_TIMER && wParam == kSettleTimer) {
        FinishSettling();
        return true;
    }
    if (message == kSpaceIconsMessage) {
        sidebar_->PicturesArrived();
        return true;
    }
    if (message == kFaviconsMessage) {
        if (favicons_ && favicons_->TakeResults()) sidebar_->InvalidatePages();
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

std::wstring BrowserWindowController::SmokeTestSpaces() {
    const std::string before = state_.SelectedSpace().id;
    const size_t index = state_.SelectedSpaceIndex();
    const bool visible = IsWindowVisible(window_.Handle()) && !IsIconic(window_.Handle());
    const auto settle = [&](const wchar_t* what) -> std::wstring {
        const bool fades = theme_.Fading();
        if (visible && !sidebarSliding_) return std::wstring(what) + L" didn't slide the pages";
        if (!visible && (sidebarSliding_ || fades)) return std::wstring(what) + L" animated a hidden window";
        // The clock's frames until the fade ends and the slide's timer fires (2 s at most). Only
        // those (and the window's other timers): the rest waits for the message loop, so a page
        // that loads meanwhile can't close the window mid-switch.
        const size_t framesBefore = frameCount_;
        const ULONGLONG deadline = GetTickCount64() + 2000;
        MSG message;
        while ((clock_->Running() || sidebarSliding_) && GetTickCount64() < deadline) {
            if (PeekMessageW(&message, window_.Handle(), kFrameMessage, kFrameMessage, PM_REMOVE) ||
                PeekMessageW(&message, window_.Handle(), WM_TIMER, WM_TIMER, PM_REMOVE)) {
                DispatchMessageW(&message);
            } else {
                Sleep(1);
            }
        }
        if (clock_->Running()) return std::wstring(what) + L": the frame clock never stopped";
        if (sidebarSliding_) return std::wstring(what) + L": the pages' slide never ended";
        if (fades && frameCount_ == framesBefore) return std::wstring(what) + L": the crossfade got no frames";
        if (sidebar_->PageOffset() != 0 || pagesAnchor_) return std::wstring(what) + L": the pages didn't come to rest";
        if (theme_.Fading() || theme_.from != state_.SelectedSpace().theme) return std::wstring(what) + L": the theme didn't come to rest";
        return {};
    };
    RunCommand("nextSpace");
    if (state_.SelectedSpaceIndex() == index) return L"Next Space didn't select another space";
    if (std::wstring problem = settle(L"Next Space"); !problem.empty()) return problem;
    RunCommand("previousSpace");
    if (std::wstring problem = settle(L"Previous Space"); !problem.empty()) return problem;
    if (state_.SelectedSpace().id != before) return L"Previous Space didn't come back";
    // Space n past the last space passes its key on.
    if (CommandEnabled("space9") != (state_.spaces.size() >= 9)) return L"Space 9 is enabled without a ninth space";
    frames_.clear();
    return {};
}

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
    // The space bar along its bottom: the end buttons and the spaces' cells.
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    const long barTop = std::lround(SpaceBarTop(static_cast<float>(chrome.height) / scale) * scale);
    if (barTop < 0 || barTop >= static_cast<long>(chrome.height) || !Inked(chrome, static_cast<UINT>(barTop))) {
        return L"the space bar drew nothing";
    }
    // And the caption buttons their glyphs.
    Pixels buttons;
    if (std::wstring problem = caption_->Draw(&buttons); !problem.empty()) return L"the caption buttons couldn't draw: " + problem;
    if (!Inked(buttons)) return L"the caption buttons drew nothing";
    // Switching spaces: the pages slide on the compositor and the theme crossfades on the
    // clock's frames, and both come to rest on the next space, then back on this one.
    if (state_.spaces.size() > 1) {
        const uint64_t armed = saveArms_;
        if (std::wstring problem = SmokeTestSpaces(); !problem.empty()) return problem;
        // A change arms the session's save (it may have fired already: the settling ran timers).
        if (writer_ && writer_->MaySave() && saveArms_ == armed) return L"switching spaces didn't schedule a save";
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

std::wstring BrowserWindowController::Capture(Pixels& pixels, const std::optional<std::string>& barText, std::optional<size_t> tip) {
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
    if (problem.empty() && tip) {
        // A space's tip at rest over its cell, as the pointer leaves it there (its window over
        // the browser window's, clipped to it as the Mac's capture of the window is).
        Pixels tipPixels;
        POINT origin{};
        problem = sidebar_->RenderTip(*tip, tipPixels, origin);
        if (problem.empty()) ComposeOver(pixels, tipPixels, origin);
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
    // The Mac's mutatePage: a navigation saves as soon as a sidebar change, a title or favicon
    // later (SessionSaveDelay::PageEvent); a report that changes nothing saves nothing.
    events.addressChanged = [this](const std::string& id, const std::string& url) {
        Tab* tab = TabNamed(id);
        const bool changed = tab && !url.empty() && tab->url != url;
        if (changed) tab->url = url;
        StateChanged(changed ? std::optional(SessionSaveDelay::Soon) : std::nullopt);
    };
    events.titleChanged = [this](const std::string& id, const std::string& title) {
        // An empty title keeps the last one, as the Mac's BrowserStore does.
        Tab* tab = TabNamed(id);
        const bool changed = tab && !title.empty() && tab->title != title;
        if (changed) tab->title = title;
        StateChanged(changed ? std::optional(SessionSaveDelay::PageEvent) : std::nullopt);
    };
    events.faviconChanged = [this](const std::string& id, const std::string& url) {
        Tab* tab = TabNamed(id);
        const std::optional<std::string> icon = url.empty() ? std::nullopt : std::optional<std::string>(url);
        if (!tab || tab->faviconURL == icon) return;
        tab->faviconURL = icon;
        StateChanged(SessionSaveDelay::PageEvent);
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
    window_.onMinimize = [this] {
        sidebar_->HideTip();
        chromium_->Minimized();
    };
    window_.onMove = [this] {
        sidebar_->HideTip();
        chromium_->WindowMoved();
    };
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

// See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>
#include <cmath>
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
// When the pages' slide on the compositor has ended (its duration and a frame, rounded up).
constexpr UINT_PTR kSettleTimer = 3;
// Posted by the favicon worker when icons arrive (Favicons.h).
constexpr UINT kFaviconsMessage = WM_APP + 4;
// Posted by the frame clock once a composition frame while something animates.
constexpr UINT kFrameMessage = WM_APP + 5;
constexpr UINT kSpaceIconsMessage = WM_APP + 6;
// A frame log's touchpad records at most (a few MB; a resting finger polls once a frame).
constexpr size_t kMaxTouchpadLog = 200000;

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
      theme_(state.SelectedSpace().theme),
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
    ApplyAppearance(theme_.to);
    clock_ = std::make_unique<FrameClock>(window_.Handle(), kFrameMessage);
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

    // Two fingers on a precision touchpad over the sidebar: a swipe between spaces, or the
    // list's scroll. Without DirectManipulation they stay the system's wheel messages.
    if (!options_.capture) {
        touchpad_ = TouchpadInput::Create(
            window_.Handle(),
            [this](const SwipeInput& input) {
                // Where the pointer is now: it decides whose the gesture is until a swipe begins.
                POINT at{};
                GetCursorPos(&at);
                ScreenToClient(window_.Handle(), &at);
                SwipeInputArrived(input, at);
            },
            [this] { clock_->Start(); }, error);
        if (touchpad_) {
            touchpad_->SetScale(static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI);
            // A hardware run's record of what DirectManipulation reported, with the frames (a
            // resting finger's polls add one a frame: the log keeps the first of them).
            if (options_.frameLog) {
                touchpad_->log = [this](const std::string& line) {
                    if (touchpadLog_.size() < kMaxTouchpadLog) touchpadLog_.push_back(line);
                    else ++touchpadLogDropped_;
                };
            }
        } else {
            touchpadError_ = error;
            OutputDebugStringW((L"Kite: no touchpad gestures: " + error + L"\n").c_str());
        }
        error.clear();
    }

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
    // reported runs first (titles, addresses), then the caller saves.
    window_.onClose = [this] {
        clock_->Stop();
        // DirectManipulation lets the window go while it's still a window.
        touchpad_.reset();
        RunPending();
        if (save_) save_();
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
    // side it lies on, the page left behind built until they're at rest. A swipe's own landing
    // doesn't (its pages are already there), and mid-swipe the pages are the fingers'.
    if (old == now || selectingBySwipe_ || swipe_.Swiping()) return;
    // A swipe's landing still to come is overtaken by this switch.
    pendingLanding_.reset();
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
    // A swipe's landing: its space is selected now the pages are at rest, its page where the
    // neighbour's was.
    CommitLanding();
    sidebar_->SetPageOffset(0);
    // At rest: the new space's neighbours are built, the page left behind goes.
    if (!pagesAnchor_) return;
    pagesAnchor_.reset();
    sidebar_->Update(state_);
}

bool BrowserWindowController::OverSidebar(POINT at) const {
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    return !(commandBar_ && commandBar_->IsOpen()) && at.x >= 0 && at.y >= 0 && at.y < client.bottom &&
           static_cast<float>(at.x) < static_cast<float>(kSidebarWidth) * scale;
}

SpaceSwipeGesture::Step BrowserWindowController::SwipeInputArrived(const SwipeInput& input, POINT at) {
    // Asked of each event until a swipe begins, as the Mac's isOverSidebar: the pointer may have
    // left the sidebar since the fingers came down, or the command bar opened over it.
    const bool overSidebar = OverSidebar(at);
    const SpaceSwipeGesture::Step step = swipe_.Handle(input, overSidebar, [this] { return BeginSwipe(); });
    switch (step) {
    case SpaceSwipeGesture::Step::Pass:
        if (overSidebar) {
            // A vertical gesture is the list's scroll (and its momentum) under the pointer:
            // content dragged down goes back up the list.
            if (input.dy != 0) sidebar_->ScrollList(at, static_cast<float>(-input.dy));
        } else if (touchpad_) {
            // Not the sidebar's: the rest of it is the system's wheel messages, for whatever is
            // under the pointer (the Mac passes the event on to it).
            touchpad_->ReleaseContact();
        }
        break;
    case SpaceSwipeGesture::Step::Move:
        ShowSwipe();
        break;
    case SpaceSwipeGesture::Step::Release:
        FinishSwipe(swipe_.Landing());
        break;
    case SpaceSwipeGesture::Step::Swallow:
        break;
    }
    return step;
}

SwipeStart BrowserWindowController::BeginSwipe() {
    // Caught mid-settle: carry on from where the pages are, with the selected space's
    // neighbours, a landing still to come selected first.
    float offset = sidebar_->PageOffset();
    KillTimer(window_.Handle(), kSettleTimer);
    sidebarSliding_ = false;
    slideStarted_ = false;
    offset += static_cast<float>(CommitLanding() * kSidebarWidth);
    if (pagesAnchor_) {
        pagesAnchor_.reset();
        sidebar_->Update(state_);
    }
    sidebar_->SetPageOffset(offset);
    const size_t index = state_.SelectedSpaceIndex();
    return SwipeStart{static_cast<double>(kSidebarWidth), index > 0, index + 1 < state_.spaces.size(), offset};
}

void BrowserWindowController::ShowSwipe() {
    const SpaceSwipe& swipe = *swipe_.Swipe();
    sidebar_->SetPageOffset(static_cast<float>(swipe.Offset()));
    // The theme crossfades towards the neighbour the pages are moving to, drawn on the next
    // frame (the clock's, which runs while the touchpad does).
    const size_t index = state_.SelectedSpaceIndex();
    const Theme& current = state_.spaces[index].theme;
    const size_t neighbour = index + static_cast<size_t>(swipe.Direction());
    const bool hasNeighbour = swipe.Direction() != 0 && neighbour < state_.spaces.size();
    theme_.SetInteractive(current, hasNeighbour ? state_.spaces[neighbour].theme : current, static_cast<float>(swipe.Progress()));
    swipeMoved_ = true;
    clock_->Start();
}

void BrowserWindowController::FinishSwipe(int landing) {
    const size_t index = state_.SelectedSpaceIndex();
    // A space selected under the swipe (from the keyboard) may leave no neighbour that side.
    const size_t target = index + static_cast<size_t>(landing);
    if (landing != 0 && target >= state_.spaces.size()) landing = 0;
    const Space& space = state_.spaces[index + static_cast<size_t>(landing)];
    const bool visible = IsWindowVisible(window_.Handle()) && !IsIconic(window_.Handle());
    if (visible) {
        theme_.FinishInteractive(space.theme, FrameClock::Now());
        if (theme_.Fading()) clock_->Start();
    } else {
        theme_.Snap(space.theme);
    }
    // The pages slide on to the neighbour's page before the space is selected: selecting it
    // redraws the sidebar and swaps the web page, work that would stall the slide's first frames.
    if (landing != 0) pendingLanding_ = Landing{space.id, landing};
    const float to = -static_cast<float>(landing * kSidebarWidth);
    const double duration = visible ? sidebar_->SlidePages(sidebar_->PageOffset(), to) : 0;
    if (duration <= 0) {
        sidebar_->SetPageOffset(to);
        return FinishSettling();
    }
    sidebarSliding_ = true;
    // The bar's light slides with them (SlidePages leaves that to the sidebar's next Update),
    // and the slide starts now, as a keyboard switch's: PageOffset reads it from now, so a swipe
    // catching it mid-way carries on from where the pages really are.
    sidebar_->Update(state_, pagesAnchor_);
    CommitSlide();
    SetTimer(window_.Handle(), kSettleTimer, static_cast<UINT>(std::ceil(duration * 1000)) + 17, nullptr);
}

int BrowserWindowController::CommitLanding() {
    if (!pendingLanding_) return 0;
    const Landing landing = *pendingLanding_;
    pendingLanding_.reset();
    if (!state_.SpaceIndex(landing.spaceID)) return 0;
    // The page left behind stays built until the next pass at rest (FinishSettling's).
    pagesAnchor_ = state_.SelectedSpace().id;
    selectingBySwipe_ = true;
    state_.SelectSpace(landing.spaceID);
    SelectionMoved();
    selectingBySwipe_ = false;
    return landing.pages;
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
    // The touchpad's movement this frame first, so the frame shows it.
    const bool touchpadFrames = touchpad_ && touchpad_->Step();
    // Only what moved draws: the crossfade, or a swipe's step. The touchpad's other frames (a
    // vertical scroll's, a swipe's swallowed momentum) leave the backdrop as it is.
    if (theme_.Fading() || swipeMoved_) {
        swipeMoved_ = false;
        // Minimized: nothing to draw into (OnSize draws the end of it on restore).
        if (!IsIconic(window_.Handle())) DrawAt(time, nullptr);
        else lastThemeProgress_ = theme_.Progress(time);
    }
    if (options_.frameLog) {
        if (frames_.empty()) frames_.reserve(1024);
        frames_.push_back(LoggedFrame{FrameClock::Now(), time, sidebar_->PageOffset(), lastThemeProgress_});
    }
    if (!theme_.Fading() && !touchpadFrames) {
        clock_->Stop();
        lastFrameTime_.reset();
        return;
    }
    // The display at its highest rate only while something moves on it: a fade, or fingers (or
    // their momentum) moving. Fingers resting on the touchpad, after a fade too, leave it alone.
    clock_->SetBoost(theme_.Fading() || (touchpad_ && touchpad_->Moving()));
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
    for (const std::string& record : touchpadLog_) out << record << '\n';
    if (touchpadLogDropped_) out << "{\"dm\":\"dropped\",\"count\":" << touchpadLogDropped_ << "}\n";
    out.flush();
    return out ? std::wstring{} : L"couldn't write " + file.wstring();
}

// MARK: The session and the pages

void BrowserWindowController::StateChanged() {
    SyncSpace();
    sidebar_->Update(state_, pagesAnchor_);
    // A slide begins at once: the new page and the caption buttons' appearance drawn and the
    // strip's animation committed now, not on the next pass (the crossfade's first frame comes
    // with the clock).
    if (slideStarted_) {
        slideStarted_ = false;
        CommitSlide();
    }
    if (commandBar_) commandBar_->Refresh();
}

void BrowserWindowController::CommitSlide() {
    std::wstring problem = sidebar_->Draw();
    if (problem.empty()) problem = caption_->Draw();
    if (problem.empty()) compositor_->Commit();
    else if (sidebar_->DeviceLost() || caption_->DeviceLost()) Draw();
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
    if (touchpad_) touchpad_->SetScale(static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI);
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
    // Two fingers coming down on a precision touchpad: over the sidebar (and nothing over it),
    // the gesture is DirectManipulation's, and its frames come with the clock.
    if (message == DM_POINTERHITTEST && touchpad_) {
        if (touchpad_->HitTest(wParam, lParam, [this](POINT at) { return OverSidebar(at); })) {
            // Frames to poll DirectManipulation with; the display's rate goes up once it moves.
            clock_->Start(false);
            result = 0;
            return true;
        }
        return false;
    }
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
            for (const Tab& tab : state_.ArchiveStaleTabs(*interval)) PageGone(tab.id);
            StateChanged();
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

bool BrowserWindowController::RunUntil(const std::function<bool()>& done, double seconds) {
    // Only the clock's frames and the window's timers: the rest waits for the message loop, so
    // a page that loads meanwhile can't close the window mid-test.
    const ULONGLONG deadline = GetTickCount64() + static_cast<ULONGLONG>(seconds * 1000);
    MSG message;
    while (!done() && GetTickCount64() < deadline) {
        if (PeekMessageW(&message, window_.Handle(), kFrameMessage, kFrameMessage, PM_REMOVE) ||
            PeekMessageW(&message, window_.Handle(), WM_TIMER, WM_TIMER, PM_REMOVE)) {
            DispatchMessageW(&message);
        } else {
            Sleep(1);
        }
    }
    return done();
}

std::wstring BrowserWindowController::RunToRest(const wchar_t* what) {
    const bool visible = IsWindowVisible(window_.Handle()) && !IsIconic(window_.Handle());
    const bool fades = theme_.Fading();
    if (visible && !sidebarSliding_) return std::wstring(what) + L" didn't slide the pages";
    if (!visible && (sidebarSliding_ || fades)) return std::wstring(what) + L" animated a hidden window";
    // The clock's frames until the fade ends and the slide's timer fires (2 s at most).
    const size_t framesBefore = frameCount_;
    RunUntil([this] { return !clock_->Running() && !sidebarSliding_; }, 2);
    if (clock_->Running()) return std::wstring(what) + L": the frame clock never stopped";
    if (sidebarSliding_) return std::wstring(what) + L": the pages' slide never ended";
    if (fades && frameCount_ == framesBefore) return std::wstring(what) + L": the crossfade got no frames";
    if (sidebar_->PageOffset() != 0 || pagesAnchor_ || pendingLanding_) return std::wstring(what) + L": the pages didn't come to rest";
    if (theme_.Fading() || theme_.Interactive() || theme_.from != state_.SelectedSpace().theme) {
        return std::wstring(what) + L": the theme didn't come to rest";
    }
    return {};
}

std::wstring BrowserWindowController::SmokeTestSpaces() {
    const std::string before = state_.SelectedSpace().id;
    const size_t index = state_.SelectedSpaceIndex();
    RunCommand("nextSpace");
    if (state_.SelectedSpaceIndex() == index) return L"Next Space didn't select another space";
    if (std::wstring problem = RunToRest(L"Next Space"); !problem.empty()) return problem;
    RunCommand("previousSpace");
    if (std::wstring problem = RunToRest(L"Previous Space"); !problem.empty()) return problem;
    if (state_.SelectedSpace().id != before) return L"Previous Space didn't come back";
    // Space n past the last space passes its key on.
    if (CommandEnabled("space9") != (state_.spaces.size() >= 9)) return L"Space 9 is enabled without a ninth space";
    frames_.clear();
    return {};
}

std::wstring BrowserWindowController::SmokeTestSwipe() {
    // DirectManipulation is there on every Windows Kite runs on: without it, no touchpad swipes.
    if (!touchpad_) return L"Kite couldn't take touchpad gestures: " + touchpadError_;
    // Touchpad events as DirectManipulation reports them, a frame apart, over the list.
    using Phase = SwipeInput::Phase;
    using Step = SpaceSwipeGesture::Step;
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    // The pointer over the list, and over the page beside the sidebar.
    const POINT list{std::lround(120 * scale), std::lround(200 * scale)};
    const POINT page{std::lround((kSidebarWidth + 200) * scale), std::lround(200 * scale)};
    double stamp = FrameClock::Now();
    const auto sendAt = [&](POINT at, Phase phase, double dx, double dy, double after = 1.0 / 60) {
        stamp += after;
        return SwipeInputArrived(SwipeInput{phase, dx, dy, stamp}, at);
    };
    const auto send = [&](Phase phase, double dx, double dy, double after = 1.0 / 60) { return sendAt(list, phase, dx, dy, after); };
    const std::string before = state_.SelectedSpace().id;
    const size_t index = state_.SelectedSpaceIndex();
    // Towards whichever neighbour there is: the next space's content comes in from the right.
    const int towards = index + 1 < state_.spaces.size() ? 1 : -1;
    const size_t neighbour = index + static_cast<size_t>(towards);

    // A gesture that starts vertically scrolls the list and never swipes, sideways or not.
    send(Phase::Began, 0, 0);
    if (send(Phase::Changed, 2, -10) != Step::Pass || send(Phase::Changed, -towards * 60.0, 0) != Step::Pass ||
        swipe_.Swiping() || sidebar_->PageOffset() != 0) {
        return L"a vertical gesture swiped";
    }
    send(Phase::Ended, 0, 0);
    send(Phase::MomentumEnded, 0, 0);
    // Fingers down over the sidebar, the pointer over the page by the time they move (the Mac
    // asks where each event is until the swipe begins): the page's, never a swipe.
    send(Phase::Began, 0, 0);
    if (sendAt(page, Phase::Changed, -towards * 60.0, 0) != Step::Pass || swipe_.Swiping() || sidebar_->PageOffset() != 0) {
        return L"a gesture moving over the page swiped";
    }
    sendAt(page, Phase::Ended, 0, 0);

    // Sideways: the pages and the theme follow the fingers, and a frame draws it.
    send(Phase::Began, 0, 0);
    for (int i = 0; i < 6; ++i) send(Phase::Changed, -towards * 25.0, 0);
    if (!swipe_.Swiping()) return L"a sideways gesture didn't swipe";
    if (std::abs(sidebar_->PageOffset() + towards * 150.0f) > 0.01f) return L"the pages didn't follow the swipe";
    if (!theme_.Interactive() || std::abs(theme_.Progress(0) - 150.0f / kSidebarWidth) > 1e-4f ||
        theme_.to != state_.spaces[neighbour].theme) {
        return L"the theme didn't follow the swipe";
    }
    if (std::wstring problem = Draw(); !problem.empty()) return L"a swipe's frame didn't draw: " + problem;
    // Let go past half a page: it lands on the neighbour, its momentum swallowed (the list
    // doesn't scroll with it).
    if (send(Phase::Ended, 0, 0) != Step::Release || swipe_.Landing() != towards) return L"a swipe past half a page didn't land";
    if (state_.SelectedSpaceIndex() != index) return L"a swipe selected its space before the pages were at rest";
    const float scrolled = sidebar_->ListScroll();
    if (send(Phase::Momentum, -towards * 40.0, -30) != Step::Swallow || sidebar_->ListScroll() != scrolled) {
        return L"a swipe's momentum wasn't swallowed";
    }
    send(Phase::MomentumEnded, 0, 0);
    // Fingers down again mid-settle: the landing is selected and the pages carry on from where
    // they are, the new space's page where the neighbour's was.
    const float settling = sidebar_->PageOffset();
    send(Phase::Began, 0, 0);
    send(Phase::Changed, -towards * 1.0, 0);
    if (!swipe_.Swiping() || state_.SelectedSpaceIndex() != neighbour) return L"a swipe caught mid-settle didn't land the last one";
    const float carried = settling + static_cast<float>(towards * kSidebarWidth) - static_cast<float>(towards);
    // The spring moves on between the two readings: a few points at most.
    if (std::abs(sidebar_->PageOffset() - carried) > 8) return L"a swipe caught mid-settle didn't carry on from the pages";
    if (send(Phase::Ended, 0, 0) != Step::Release) return L"a swipe caught mid-settle didn't let go";
    if (std::wstring problem = RunToRest(L"A swipe"); !problem.empty()) return problem;
    if (state_.SelectedSpaceIndex() != neighbour) return L"a swipe didn't select the space it landed on";

    // A short slow drag back stays where it is.
    send(Phase::Began, 0, 0);
    for (int i = 0; i < 4; ++i) send(Phase::Changed, towards * 10.0, 0, 0.1);
    if (send(Phase::Ended, 0, 0) != Step::Release || swipe_.Landing() != 0) return L"a short slow swipe didn't stay";
    if (std::wstring problem = RunToRest(L"A short swipe"); !problem.empty()) return problem;
    if (state_.SelectedSpaceIndex() != neighbour) return L"a short swipe moved the selection";

    // A flick back lands on the space it started from, however short.
    send(Phase::Began, 0, 0);
    for (int i = 0; i < 3; ++i) send(Phase::Changed, towards * 20.0, 0);
    if (send(Phase::Ended, 0, 0) != Step::Release || swipe_.Landing() != -towards) return L"a flick didn't land";
    if (std::wstring problem = RunToRest(L"A flick"); !problem.empty()) return problem;
    if (state_.SelectedSpace().id != before) return L"a flick back didn't come back";
    if (std::wstring problem = SmokeTestSwipeThreeSpaces(); !problem.empty()) return problem;
    if (std::wstring problem = SmokeTestSwipeOneSpace(); !problem.empty()) return problem;
    if (state_.SelectedSpace().id != before) return L"the swipe tests didn't come back to their space";
    frames_.clear();
    return {};
}

std::wstring BrowserWindowController::SmokeTestSwipeThreeSpaces() {
    using Phase = SwipeInput::Phase;
    using Step = SpaceSwipeGesture::Step;
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    const POINT list{std::lround(120 * scale), std::lround(200 * scale)};
    double stamp = FrameClock::Now();
    const auto send = [&](Phase phase, double dx) {
        stamp += 1.0 / 60;
        return SwipeInputArrived(SwipeInput{phase, dx, 0, stamp}, list);
    };
    // Half a page and more towards the next space (6 frames of 25pt), not yet let go.
    const auto swipeToNext = [&] {
        send(Phase::Began, 0);
        for (int i = 0; i < 6; ++i) send(Phase::Changed, -25);
        return swipe_.Swiping();
    };
    const auto selectFirst = [&]() -> std::wstring {
        if (state_.SelectedSpaceIndex() == 0) return {};
        RunCommand("space1");
        return RunToRest(L"Space 1");
    };
    const std::string before = state_.SelectedSpace().id;
    // A third space at the end, in a theme neither of the first two has, the selection kept.
    Theme third = Theme::Presets().back();
    for (const Theme& preset : Theme::Presets()) {
        if (std::none_of(state_.spaces.begin(), state_.spaces.end(), [&](const Space& space) { return space.theme == preset; })) {
            third = preset;
            break;
        }
    }
    const std::string added = state_.AddSpace("Swipe test", "", third);
    state_.SelectSpace(before);
    StateChanged();
    const size_t last = state_.spaces.size() - 1;
    const std::wstring failure = [&]() -> std::wstring {
        if (std::wstring problem = selectFirst(); !problem.empty()) return problem;

        // A keyboard switch overtakes a landing still to come: Previous Space (round to the
        // last) wins, and the pages don't then land on the next space.
        if (!swipeToNext()) return L"a swipe to the next space didn't begin";
        if (send(Phase::Ended, 0) != Step::Release || swipe_.Landing() != 1 || !pendingLanding_) return L"a swipe to the next space didn't land";
        RunCommand("previousSpace");
        if (pendingLanding_ || state_.SelectedSpaceIndex() != last) return L"a keyboard switch didn't overtake a swipe's landing";
        if (std::wstring problem = RunToRest(L"A keyboard switch over a landing"); !problem.empty()) return problem;
        if (state_.SelectedSpaceIndex() != last) return L"a swipe's landing came after the keyboard's switch";
        if (std::wstring problem = selectFirst(); !problem.empty()) return problem;

        // A space selected under the swipe (Space 3 from the keyboard): the release has no next
        // space to land on and stays, and the theme goes on to the selected space's from the
        // side showing more (the next space's, 150 of 240pt in).
        const Theme& next = state_.spaces[1].theme;
        if (!swipeToNext()) return L"a swipe to the next space didn't begin";
        RunCommand("space" + std::to_string(last + 1));
        if (state_.SelectedSpaceIndex() != last || !swipe_.Swiping() || !theme_.Interactive()) {
            return L"a space selected under a swipe ended it";
        }
        if (send(Phase::Ended, 0) != Step::Release || pendingLanding_) return L"a swipe with no space left to land on landed";
        if (!theme_.Fading() || theme_.from != next || theme_.to != third) {
            return L"the theme didn't go on to the space selected under the swipe";
        }
        if (std::wstring problem = RunToRest(L"A swipe under a selection"); !problem.empty()) return problem;
        if (state_.SelectedSpaceIndex() != last) return L"a swipe moved a selection made under it";
        if (std::wstring problem = selectFirst(); !problem.empty()) return problem;

        // Let go with the window hidden: no slide or fade to run, so it lands and selects at once.
        if (!swipeToNext()) return L"a swipe to the next space didn't begin";
        ShowWindow(window_.Handle(), SW_HIDE);
        const bool released = send(Phase::Ended, 0) == Step::Release;
        const bool landed = released && state_.SelectedSpaceIndex() == 1 && !pendingLanding_ && !sidebarSliding_ &&
                            sidebar_->PageOffset() == 0 && !pagesAnchor_ && !theme_.Fading() && !theme_.Interactive() &&
                            theme_.from == state_.SelectedSpace().theme;
        ShowWindow(window_.Handle(), SW_SHOWNA);
        if (!landed) return L"a swipe let go in a hidden window didn't land at once";
        if (std::wstring problem = Draw(); !problem.empty()) return L"the window didn't draw again after a hidden swipe: " + problem;
        if (std::wstring problem = selectFirst(); !problem.empty()) return problem;

        // Past the first space: the pages rubber-band (less than the fingers went), the theme
        // stays, and the release goes back.
        send(Phase::Began, 0);
        for (int i = 0; i < 6; ++i) send(Phase::Changed, 25);
        const float band = sidebar_->PageOffset();
        if (!swipe_.Swiping() || !(band > 0 && band < 150)) return L"the pages didn't rubber-band before the first space";
        if (!theme_.Interactive() || theme_.from != theme_.to || theme_.to != state_.SelectedSpace().theme) {
            return L"the theme moved past the first space";
        }
        if (send(Phase::Ended, 0) != Step::Release || swipe_.Landing() != 0) return L"a swipe past the first space landed";
        if (std::wstring problem = RunToRest(L"A swipe past the first space"); !problem.empty()) return problem;
        if (state_.SelectedSpaceIndex() != 0) return L"a swipe past the first space moved the selection";

        // A fade's boost ends with it, though the clock runs on for fingers resting on the
        // touchpad (made here by asking the touchpad for frames, as a contact taken does).
        if (state_.spaces[0].theme != state_.spaces[1].theme && touchpad_) {
            RunCommand("nextSpace");
            touchpad_->PollFor(1.5);
            if (!theme_.Fading() || !clock_->Boosted()) return L"a space switch's crossfade didn't boost the display";
            if (!RunUntil([this] { return !theme_.Fading(); }, 2)) return L"a space switch's crossfade never ended";
            // A frame after it, for the clock to hear.
            const size_t frames = frameCount_;
            RunUntil([&] { return frameCount_ > frames; }, 0.5);
            if (!clock_->Running()) return L"the clock stopped while the touchpad wanted frames";
            if (clock_->Boosted()) return L"fingers resting on the touchpad kept a crossfade's boost";
            if (!RunUntil([this] { return !clock_->Running() && !sidebarSliding_; }, 3)) return L"the touchpad's frames never stopped";
            if (sidebar_->PageOffset() != 0 || pagesAnchor_) return L"the pages didn't come to rest under the touchpad's frames";
            if (std::wstring problem = selectFirst(); !problem.empty()) return problem;
        }
        return {};
    }();
    // The test's space goes, whatever happened, the selection where it was.
    swipe_ = SpaceSwipeGesture();
    pendingLanding_.reset();
    if (state_.SelectedSpace().id != before) {
        state_.SelectSpace(before);
        SelectionMoved();
        if (std::wstring settled = RunToRest(L"Back to the first space"); !settled.empty() && failure.empty()) return settled;
    }
    std::erase_if(state_.spaces, [&](const Space& space) { return space.id == added; });
    StateChanged();
    return failure;
}

std::wstring BrowserWindowController::SmokeTestSwipeOneSpace() {
    using Phase = SwipeInput::Phase;
    using Step = SpaceSwipeGesture::Step;
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    const POINT list{std::lround(120 * scale), std::lround(200 * scale)};
    double stamp = FrameClock::Now();
    const auto send = [&](Phase phase, double dx) {
        stamp += 1.0 / 60;
        return SwipeInputArrived(SwipeInput{phase, dx, 0, stamp}, list);
    };
    // The other spaces set aside: a profile with one space.
    const std::string only = state_.SelectedSpace().id;
    const std::vector<Space> spaces = state_.spaces;
    std::erase_if(state_.spaces, [&](const Space& space) { return space.id != only; });
    StateChanged();
    const std::wstring failure = [&]() -> std::wstring {
        // Either way it rubber-bands, the theme stays, and the release goes back.
        for (const double dx : {-25.0, 25.0}) {
            send(Phase::Began, 0);
            for (int i = 0; i < 6; ++i) send(Phase::Changed, dx);
            const float band = sidebar_->PageOffset();
            if (!swipe_.Swiping() || !(std::abs(band) > 0 && std::abs(band) < 150) || (band > 0) != (dx > 0)) {
                return L"the pages didn't rubber-band with one space";
            }
            if (!theme_.Interactive() || theme_.from != theme_.to) return L"the theme moved with one space";
            if (send(Phase::Ended, 0) != Step::Release || swipe_.Landing() != 0) return L"a swipe with one space landed";
            if (std::wstring problem = RunToRest(L"A swipe with one space"); !problem.empty()) return problem;
            if (state_.SelectedSpace().id != only) return L"a swipe with one space moved the selection";
        }
        return {};
    }();
    // The others back, round the space as it is now (its page may have reported meanwhile).
    swipe_ = SpaceSwipeGesture();
    std::vector<Space> restored = spaces;
    for (Space& space : restored) {
        if (space.id == only) space = state_.SelectedSpace();
    }
    state_.spaces = std::move(restored);
    StateChanged();
    return failure;
}

std::wstring BrowserWindowController::HoldSwipe(double dx) {
    using Phase = SwipeInput::Phase;
    // Over the list, where a capture's fingers would be.
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    const POINT list{std::lround(120 * scale), std::lround(200 * scale)};
    double stamp = FrameClock::Now();
    SwipeInputArrived(SwipeInput{Phase::Began, 0, 0, stamp}, list);
    // At a steady pace, a frame at a time, as fingers would.
    const int steps = std::max(1, static_cast<int>(std::ceil(std::abs(dx) / 20)));
    for (int i = 0; i < steps; ++i) SwipeInputArrived(SwipeInput{Phase::Changed, dx / steps, 0, stamp += 1.0 / 60}, list);
    if (!swipe_.Swiping()) return L"the swipe didn't begin";
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
        if (std::wstring problem = SmokeTestSpaces(); !problem.empty()) return problem;
        // And swiping between them with two fingers on a touchpad.
        if (std::wstring problem = SmokeTestSwipe(); !problem.empty()) return problem;
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

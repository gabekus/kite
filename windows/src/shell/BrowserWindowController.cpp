// See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iterator>
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
#include "shell/Sandbox.h"
#endif
#include "shell/Errors.h"
#include "shell/Keys.h"
#include "shell/PerfLog.h"
#include "shell/QuitDialog.h"
#include "shell/SidebarMenus.h"
#include "shell/SpaceMenu.h"
#include "shell/Text.h"

namespace kite {

namespace {

// A frame log's touchpad records at most: about 20 MB held (a record's string is 40 to 90
// characters, some 100 bytes with its allocation) and 8 to 18 MB written. A resting finger
// polls once a frame, so a 500 Hz display fills it in under 7 minutes of resting.
constexpr size_t kMaxTouchpadLog = 200000;

}  // namespace

std::unique_ptr<BrowserWindowController> BrowserWindowController::Create(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts,
                                                                          Options options, SessionWriter* writer,
                                                                          HistoryStores* history, DownloadsWriter* downloads,
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
        new BrowserWindowController(instance, state, std::move(shortcuts), options, writer, history, downloads, std::move(renderer)));
    if (!controller->window_.IsValid()) {
        error = L"CreateWindowExW failed";
        return nullptr;
    }
    if (error = controller->Init(); !error.empty()) return nullptr;
    return controller;
}

BrowserWindowController::BrowserWindowController(HINSTANCE instance, BrowserState& state, ShortcutMap shortcuts, Options options,
                                                 SessionWriter* writer, HistoryStores* history, DownloadsWriter* downloads,
                                                 std::unique_ptr<Renderer> renderer)
    : instance_(instance),
      state_(state),
      shortcuts_(std::move(shortcuts)),
      options_(options),
      writer_(writer),
      downloadsWriter_(downloads),
      history_(history),
      renderer_(std::move(renderer)),
      window_(instance),
      theme_(state.SelectedSpace().theme),
      shownSpaceID_(state.SelectedSpace().id) {
    createdAt_ = FrameClock::Now();
}

BrowserWindowController::~BrowserWindowController() {
    downloadsRead_->target = nullptr;  // a read still on the worker posts nowhere
    StopArcRead();
    // History's worker outlives the window: it stops posting to it.
    if (history_) history_->SetWake(nullptr);
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
    if (history_) {
        // Each profile's file is read on history's worker; its wake comes here. One read before
        // the window existed is taken in now.
        HWND hwnd = window_.Handle();
        history_->SetWake([hwnd] { PostMessageW(hwnd, kHistoryMessage, 0, 0); });
        history_->Adopt();
    }
    compositor_ = Compositor::Create(window_.Handle(), *renderer_, error);
    if (!compositor_) return L"Kite couldn't start DirectComposition: " + error;
    if (perf::On()) perf::SetWindow(window_.Handle());

    // The sidebar, over the backdrop: what the session lists, with favicons fetched off the UI
    // thread (none in a capture, which mustn't depend on the network, unless it's asked for them).
    if (!options_.capture || options_.captureFavicons) favicons_ = Favicons::Create(window_.Handle(), kFaviconsMessage);
    sidebar_ = SidebarView::Create(window_.Handle(), favicons_.get(),
                                   SpaceIconPainter::Pictures{options_.spaceIcons, kSpaceIconsMessage, options_.capture}, error);
    if (!sidebar_) return L"Kite couldn't make the sidebar: " + error;
    sidebar_->UseCompositor(compositor_.get());
    // Its empty favorites tray shows until it's dismissed (a small file, read before the window shows).
    oneShotFlags_ = OneShotFlags::Load(options_.supportDirectory);
    sidebar_->SetFavoritesEmptyStateDismissed(oneShotFlags_.Get(OneShotFlags::kFavoritesEmptyStateDismissed));
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
        return TitleBarAreaAt(static_cast<float>(client.right) / scale, SidebarShownWidth(), x, y, scale);
    };

    // The command bar (Ctrl+T), over everything in the window.
    CommandBarView::Callbacks bar;
    bar.suggestions = [this](std::string_view text, CommandBarMode mode) {
        // The current space's profile's history (the Mac's store.history).
        const History* history = history_ ? &history_->ForProfile(state_.SelectedProfileDirectory()).Get() : nullptr;
        return CommandBarSuggestions(text, state_, mode, history, Now());
    };
    bar.commit = [this](const CommandSuggestion& row, CommandBarMode mode) { Commit(row, mode); };
    bar.opened = [this] {
        // The keyboard: the find field lets it go and a rename ends, keeping what was typed, as
        // its field editor would, before the bar makes its system caret.
        GiveKeyboard(KeyboardField::CommandBar);
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

    // The find bar (Ctrl+F), over the page and under the command bar.
    FindBarView::Callbacks find;
    find.search = [this](const FindQuery::Search& search) { FindInPage(search); };
    find.close = [this] { HideFindBar(true); };
    find.takeKeyboard = [this] { GiveKeyboard(KeyboardField::Find, false); };
    find.dpi = [this] { return window_.Dpi(); };
    findBar_ = FindBarView::Create(window_.Handle(), std::move(find), error);
    if (findBar_) findBar_->UseCompositor(compositor_.get());
    else OutputDebugStringW((L"Kite: no find bar: " + error + L"\n").c_str());

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
    // Editing spaces (+Spaces.cpp): a drop in the bar, the space menu, the header's rename.
    actions.moveSpace = [this](const std::string& spaceID, size_t index) { MoveSpace(spaceID, index); };
    actions.spaceMenu = [this](const std::string& spaceID, POINT screen) { ShowSpaceMenu(spaceID, screen); };
    // The rows' and favorites' menus (+SidebarMenus.cpp).
    actions.rowMenu = [this](SidebarMenuKind kind, const std::string& id, POINT screen) { ShowRowMenu(kind, id, screen); };
    actions.renameSpace = [this](const std::string& spaceID, const std::string& name) { RenameSpace(spaceID, name); };
    actions.beginRenaming = [this](const std::string& spaceID) { BeginRenaming(spaceID); };
    // Tabs and folders (+Tabs.cpp): their row's rename, a double-click on a tab, Back to Pinned URL.
    actions.renameTab = [this](const std::string& tabID, const std::string& name) { RenameTab(tabID, name); };
    actions.renameFolder = [this](const std::string& folderID, const std::string& name) { RenameFolder(folderID, name); };
    actions.beginRenamingTab = [this](const std::string& tabID) { BeginRenamingTab(tabID, true); };
    actions.resetTab = [this](const std::string& tabID) { BackToPinnedURL(tabID); };
    // The top row's buttons run the commands of the same names (the Mac's SidebarActions).
    actions.topRow = [this](TopRowButton button) { RunCommand(TopRowCommand(button)); };
    // The empty favorites tray's Dismiss (the Mac's OneShotFlags.set): a write of a few bytes.
    actions.dismissFavoritesEmptyState = [this] {
        if (const std::string problem = oneShotFlags_.Set(OneShotFlags::kFavoritesEmptyStateDismissed, true); !problem.empty()) {
            OutputDebugStringW((L"Kite: " + Widen(problem) + L"\n").c_str());
        }
        sidebar_->SetFavoritesEmptyStateDismissed(true);
    };
    sidebar_->SetActions(std::move(actions));
    if (options_.quiet) askToDelete_ = [](const SpaceDeletion&) { return false; };
    else askToDelete_ = [this](const SpaceDeletion& deletion) { return AskToDeleteSpace(window_.Handle(), deletion); };
    if (options_.quiet) askToDeleteFolder_ = [](const FolderDeletion&) { return false; };
    else askToDeleteFolder_ = [this](const FolderDeletion& deletion) { return AskToDeleteFolder(window_.Handle(), deletion); };
    showRowMenu_ = [this](const std::vector<SidebarMenuItem>& items, POINT screen) {
        return ShowSidebarMenu(window_.Handle(), items, screen, dark_.value_or(true));
    };

    MakeCommands();
    // View › Hide Sidebar and the Mac's File › Import from Arc…: in the window's system menu
    // (Alt+Space) until Windows has a menu of Kite's own, so a pointer can bring a hidden sidebar
    // back (its toggle leaves with it, and there's no hover reveal yet).
    if (HMENU menu = GetSystemMenu(window_.Handle(), FALSE)) {
        AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
        AppendMenuW(menu, MF_STRING, kToggleSidebarMenuID, ToggleSidebarMenuText().c_str());
        AppendMenuW(menu, MF_STRING, kImportFromArcMenuID, L"Import from Arc…");
    }
    // Every command the table can name does something: a test run fails on one that doesn't.
    if (options_.quiet) {
        for (const ShortcutCommand& command : ShortcutCommands()) {
            if (!commands_.contains(command.id)) return L"the shortcut command " + Widen(command.id) + L" does nothing";
        }
    }
    window_.filter = [this](UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
        return Filter(message, wParam, lParam, result);
    };
    // Closing the window, and logoff or shutdown (which skip WM_CLOSE): what the pages
    // reported runs first (titles, addresses), then the session, history and downloads.json are
    // saved at once. Closing doesn't wait for the writes (main.cpp does, once the window is gone);
    // logoff and shutdown can end the process as soon as WM_ENDSESSION returns, so that waits for
    // all three, kEndSessionFlush at most between them.
    window_.onClose = [this](bool endingSession) {
        // First, so an Import from Arc whose dialog is still up does nothing more.
        closing_ = true;
        clock_->Stop();
        // A slide still running lets the display's rate go now, not when the controller goes.
        slideBoost_.Set(false);
        toggleBoost_.Set(false);
        // DirectManipulation lets the window go while it's still a window.
        touchpad_.reset();
        memoryWatch_.reset();
        RunPending();
        SaveNow();
        // An Arc import whose session is written but whose history isn't merged yet: all of it
        // now, before history's last save.
        KillTimer(window_.Handle(), kArcMergeTimer);
        FinishArcImport();
        // History too, as the Mac's flush at quit; main.cpp waits for its writes.
        if (history_) {
            KillTimer(window_.Handle(), kHistoryTimer);
            history_->SaveNow();
        }
        // The read is in (else FinishDownloads joins it once the window is gone): the list's
        // last state, as the Mac's applicationWillTerminate saves it.
        if (downloads_.Restored()) SaveDownloadsNow();
        // The window is going: the worker's read posts nowhere now (FinishDownloads takes it).
        downloadsRead_->target = nullptr;
        // Logoff and shutdown: one deadline for the session, history and downloads.json.
        if (endingSession) {
            const Deadline deadline = DeadlineAfter(kEndSessionFlush);
            std::string problems[3];
            if (writer_) problems[0] = writer_->Flush(deadline);
            if (history_) problems[1] = history_->Flush(deadline);
            if (downloadsWriter_) problems[2] = downloadsWriter_->Flush(Left(deadline));
            for (const std::string& problem : problems) {
                if (!problem.empty()) OutputDebugStringW((L"Kite: " + Widen(problem) + L"\n").c_str());
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
    // side it lies on, the page left behind built until they're at rest. A swipe's own landing
    // doesn't (its pages are already there), and mid-swipe the pages are the fingers'.
    if (old == now || selectingBySwipe_ || swipe_.Swiping()) return;
    // A swipe's landing still to come is overtaken by this switch.
    pendingLanding_.reset();
    KillTimer(window_.Handle(), kSettleTimer);
    pagesAnchor_ = state_.spaces[old].id;
    const float from = (now > old ? 1.0f : -1.0f) * static_cast<float>(kSidebarWidth);
    // No sidebar on screen to slide (the window or the sidebar hidden): just land.
    const double duration =
        IsWindowVisible(window_.Handle()) && !IsIconic(window_.Handle()) && sidebarShown_ ? sidebar_->SlidePages(from, 0) : 0;
    if (duration <= 0) {
        SetSliding(false);
        return FinishSettling();
    }
    // The compositor runs it; Kite only hears when it has ended.
    SetSliding(true);
    slideStarted_ = true;
    // The compositor starts it at the commit's frame, up to a frame after now: the timer allows
    // for one at 60 Hz.
    SetTimer(window_.Handle(), kSettleTimer, static_cast<UINT>(std::ceil(duration * 1000)) + 17, nullptr);
}

void BrowserWindowController::FinishSettling() {
    KillTimer(window_.Handle(), kSettleTimer);
    SetSliding(false);
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

void BrowserWindowController::SetSliding(bool sliding) {
    sidebarSliding_ = sliding;
    // The display at its highest rate while the pages slide on the compositor, as the Mac's
    // settle boosts on its clock: a switch with no crossfade (the same theme) too.
    slideBoost_.Set(sliding);
}

bool BrowserWindowController::OverSidebar(POINT at) const {
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    return sidebarShown_ && !(commandBar_ && commandBar_->IsOpen()) && at.x >= 0 && at.y >= 0 && at.y < client.bottom &&
           static_cast<float>(at.x) < static_cast<float>(kSidebarWidth) * scale;
}

SpaceSwipeGesture::Step BrowserWindowController::SwipeInputArrived(const SwipeInput& input, POINT at) {
    // Asked of a gesture's began and its movement until it's decided, as the Mac's
    // isOverSidebar: the pointer may have left the sidebar since the fingers came down, or the
    // command bar opened over it.
    const bool overSidebar = OverSidebar(at);
    const SpaceSwipeGesture::Step step = swipe_.Handle(input, overSidebar, [this] { return BeginSwipe(); });
    switch (step) {
    case SpaceSwipeGesture::Step::Pass:
        if (!swipe_.AskedWhere()) {
            // Decided: the rest of a vertical gesture, momentum included, is the list's wherever
            // the pointer goes, when it was decided over the list.
            if (listScrolling_) sidebar_->ScrollListBy(static_cast<float>(-input.dy));
        } else if (overSidebar) {
            // A vertical gesture is the list's scroll under the pointer: content dragged down goes
            // back up the list.
            listScrolling_ = sidebar_->ScrollList(at, static_cast<float>(-input.dy));
            // Decided vertical anywhere else on the sidebar (the header, the top row, the space
            // bar): nothing of Kite's scrolls with it, so the contact goes back to the system and
            // the clock stops polling for it.
            if (swipe_.Vertical() && !listScrolling_ && touchpad_) touchpad_->ReleaseContact();
        } else {
            // Off the sidebar before it's decided: not the sidebar's. The rest of it is the
            // system's wheel messages, for whatever is under the pointer (the Mac passes the
            // event on to it).
            listScrolling_ = false;
            if (touchpad_) touchpad_->ReleaseContact();
        }
        break;
    case SpaceSwipeGesture::Step::Move:
        listScrolling_ = false;
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
    SetSliding(false);
    slideStarted_ = false;
    offset += static_cast<float>(CommitLanding() * kSidebarWidth);
    if (pagesAnchor_) {
        pagesAnchor_.reset();
        sidebar_->Update(state_);
    }
    sidebar_->SetPageOffset(offset);
    const size_t index = state_.SelectedSpaceIndex();
    swipeNeighbours_ = SpaceSwipe::Neighbours::Make(SpaceIDs(), index);
    return SwipeStart{static_cast<double>(kSidebarWidth), index > 0, index + 1 < state_.spaces.size(), offset};
}

void BrowserWindowController::ShowSwipe() {
    const SpaceSwipe& swipe = *swipe_.Swipe();
    // The spaces it began between, by id: a reorder or a delete under it (the space bar's, the
    // menu's) leaves the pages on screen the wrong ones, and the swipe is dropped.
    const std::optional<size_t> current = SwipeSpace(0), neighbour = SwipeSpace(swipe.Direction());
    if (!current || !neighbour) return CancelSwipe();
    sidebar_->SetPageOffset(static_cast<float>(swipe.Offset()));
    // The theme crossfades towards the neighbour the pages are moving to, drawn on the next
    // frame (the clock's, which runs while the touchpad does).
    theme_.SetInteractive(state_.spaces[*current].theme, state_.spaces[*neighbour].theme, static_cast<float>(swipe.Progress()));
    swipeMoved_ = true;
    clock_->Start();
}

void BrowserWindowController::FinishSwipe(int landing) {
    // Where it lands, among the spaces it began between (finish(cancelled:)'s space(towards:)):
    // none when they changed under it, which settles back on the selected space.
    const std::optional<size_t> target = SwipeSpace(landing);
    swipeNeighbours_.reset();
    if (!target) landing = 0;
    const Space& space = state_.spaces[target.value_or(state_.SelectedSpaceIndex())];
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
    SetSliding(true);
    // The bar's light slides with them (SlidePages leaves that to the sidebar's next Update),
    // and the slide starts now, as a keyboard switch's: PageOffset reads it from now, so a swipe
    // catching it mid-way carries on from where the pages really are.
    sidebar_->Update(state_, pagesAnchor_);
    CommitSlide();
    SetTimer(window_.Handle(), kSettleTimer, static_cast<UINT>(std::ceil(duration * 1000)) + 17, nullptr);
}

std::vector<std::string> BrowserWindowController::SpaceIDs() const {
    std::vector<std::string> ids;
    ids.reserve(state_.spaces.size());
    for (const Space& space : state_.spaces) ids.push_back(space.id);
    return ids;
}

std::optional<size_t> BrowserWindowController::SwipeSpace(int direction) const {
    if (!swipeNeighbours_) return std::nullopt;
    const std::optional<std::string> id = swipeNeighbours_->Target(direction, SpaceIDs(), state_.selectedSpaceID);
    return id ? state_.SpaceIndex(*id) : std::nullopt;
}

void BrowserWindowController::CancelSwipe() {
    // SpaceSwipeController.cancel: the swipe goes, the rest of its gesture with it, and the pages
    // and the theme settle back on the selected space.
    swipe_.Abandon();
    swipeNeighbours_.reset();
    FinishSwipe(0);
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
    // Pin Tab and the other tab commands need a tab, or one off its pinned page.
    if (const std::optional<bool> enabled = TabCommandEnabled(command)) return *enabled;
    return true;
}

void BrowserWindowController::Frame(double time, double rateHz) {
    ++frameCount_;
    lastFrameTime_ = time;
    // The touchpad's movement this frame first, so the frame shows it.
    const bool touchpadFrames = touchpad_ && touchpad_->Step();
    // Before the draw, so its commit is this frame's.
    if (perf::On()) perf::Frame(time, sidebar_->PageOffset(), theme_.Progress(time), rateHz);
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
    json::Object downloads{{"reports", downloadCost_.reports},
                           {"uiMicros", json::Object{{"max", downloadCost_.maxMicros},
                                                     {"mean", downloadCost_.reports ? downloadCost_.totalMicros / static_cast<double>(downloadCost_.reports) : 0.0}}},
                           {"saves", downloadCost_.saves},
                           {"saveMaxMicros", downloadCost_.saveMaxMicros},
                           {"items", downloads_.List().Items().size()},
                           {"active", downloads_.List().Active().size()}};
#ifdef KITE_HAS_CEF
    if (chromium_) {
        const auto [fromChromium, delivered] = chromium_->DownloadReports();
        downloads.emplace("fromChromium", fromChromium);
        downloads.emplace("deliveredToKite", delivered);
        // Each page kept for its downloads after its tab closed, as it went.
        json::Array parked;
        for (const auto& [url, muted] : chromium_->ParkedPages()) parked.push_back(json::Object{{"url", url}, {"muted", muted}});
        downloads.emplace("parked", json::Value(std::move(parked)));
        downloads.emplace("parkedLeavePagesAnswered", chromium_->ParkedLeavePagesAnswered());
        // Whether the stall check's timer was still running at the end (it must stop with the last parked page).
        downloads.emplace("stallCheckRunning", chromium_->StallCheckRunning());
        downloads.emplace("stallCheckTicks", chromium_->StallCheckTicks());
    }
#endif
    if (downloadsWriter_) {
        const DownloadsWriter::Statistics stats = downloadsWriter_->Stats();
        downloads.emplace("writer", json::Object{{"handedOver", stats.handedOver},
                                                 {"written", stats.written},
                                                 {"unchanged", stats.unchanged},
                                                 {"superseded", stats.superseded},
                                                 {"refused", stats.refused},
                                                 {"loaded", stats.loaded},
                                                 {"canSave", stats.canSave},
                                                 {"loadMicros", stats.loadMicros},
                                                 {"lastBytes", stats.lastBytes},
                                                 {"lastEncodeMicros", stats.lastEncodeMicros},
                                                 {"lastWriteMicros", stats.lastWriteMicros},
                                                 {"lastError", stats.lastError}});
    }
    // Each finished file's mark of the web, as Windows reads it (its Zone.Identifier stream,
    // which Chromium's quarantine writes): the live check that a download is marked as from the
    // internet. Read here, after the window has gone.
    json::Array completed;
    for (const DownloadItem& item : downloads_.List().Items()) {
        if (item.state != DownloadState::Complete || item.path.empty()) continue;
        std::filesystem::path stream(std::u8string(item.path.begin(), item.path.end()));
        stream += L":Zone.Identifier";
        json::Object entry{{"path", item.path}};
        std::ifstream in(stream, std::ios::binary);
        std::string line;
        while (in && std::getline(in, line)) {
            // Chromium ends the stream with a NUL.
            while (!line.empty() && (line.back() == '\r' || line.back() == '\0' || line.back() == ' ')) line.pop_back();
            if (line.starts_with("ZoneId=")) entry.emplace("zoneId", line.substr(7));
            if (line.starts_with("HostUrl=")) entry.emplace("hostUrl", line.substr(8));
            if (line.starts_with("ReferrerUrl=")) entry.emplace("referrerUrl", line.substr(12));
        }
        completed.push_back(json::Value(std::move(entry)));
    }
    downloads.emplace("completed", json::Value(std::move(completed)));
    log.emplace("downloads", json::Value(std::move(downloads)));
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
    if (history_) {
        const HistoryStores::Statistics stats = history_->Stats();
        const double visitMean = historyCost_.visits ? historyCost_.totalMicros / static_cast<double>(historyCost_.visits) : 0.0;
        const HistoryStore& store = history_->ForProfile(BrowserState::kDefaultProfile);
        log.emplace("history", json::Object{{"visits", historyCost_.visits},
                                            {"visitMicros", json::Object{{"max", historyCost_.maxMicros}, {"mean", visitMean}}},
                                            {"entries", store.Get().Count()},
                                            {"loaded", store.IsLoaded()},
                                            {"loadError", store.LoadError()},
                                            {"loads", stats.loads},
                                            {"writes", stats.writes},
                                            {"failedWrites", stats.failedWrites},
                                            {"lastBytes", stats.lastBytes},
                                            {"lastLoadMicros", stats.lastLoadMicros},
                                            {"lastEncodeMicros", stats.lastEncodeMicros},
                                            {"lastWriteMicros", stats.lastWriteMicros},
                                            {"lastError", stats.lastError}});
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

void BrowserWindowController::SaveNow(std::function<void(const std::string& error)> then) {
    KillTimer(window_.Handle(), kSaveTimer);
    saveSchedule_.Saved();
    if (!writer_ || !writer_->MaySave()) {
        // Nothing is written, and whoever waits on this write hears so.
        if (then) then("Kite doesn't save this session (it couldn't be read)");
        return;
    }
    // A copy for the writer's thread (the session is the UI thread's to change): the only cost
    // here. Encoding and the disk are the writer's.
    const auto start = std::chrono::steady_clock::now();
    if (then) writer_->SaveThen(state_, std::move(then));
    else writer_->Save(state_);
    const double micros = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
    ++saveCost_.saves;
    saveCost_.maxMicros = std::max(saveCost_.maxMicros, micros);
    saveCost_.totalMicros += micros;
    if (options_.saveLog) saves_.push_back(LoggedSave{FrameClock::Now() - createdAt_, micros, closing_});
}

void BrowserWindowController::ArmHistorySave() {
    if (!history_) return;
    // One timer for every profile's store: the soonest save; none when nothing waits.
    if (auto seconds = history_->NextSaveIn()) {
        SetTimer(window_.Handle(), kHistoryTimer, static_cast<UINT>(std::ceil(*seconds * 1000)), nullptr);
    } else {
        KillTimer(window_.Handle(), kHistoryTimer);
    }
}

HistoryStore* BrowserWindowController::HistoryForTab(const std::string& tabID) {
    if (!history_) return nullptr;
    // Profiles.swift's profileDirectory(ofTab:): the tab's space's profile, a favorite's grid's,
    // else the selected space's.
    std::string directory = state_.SelectedProfileDirectory();
    if (auto location = state_.Location(tabID)) {
        if (location->space) {
            directory = state_.ProfileDirectory(*location->space);
        } else {
            for (const auto& [profile, tabs] : state_.favoritesByProfile) {
                if (std::any_of(tabs.begin(), tabs.end(), [&](const Tab& tab) { return tab.id == tabID; })) directory = profile;
            }
        }
    }
    return &history_->ForProfile(directory);
}

void BrowserWindowController::RecordAddress(const std::string& tabID, const std::string& url) {
    // The Mac's pageURLChanged, before its tab check (a typed URL is already on the tab when the
    // page reports it). A tab showing one of Kite's own pages keeps it out of history.
    if (url.empty() || !history_) return;
    if (const Tab* tab = state_.FindTabByID(tabID); tab && tab->url && tab->url->starts_with("kite:") && !History::Records(url)) return;
    auto [it, inserted] = recordedURLs_.try_emplace(tabID, url);
    if (!inserted && it->second == url) return;
    it->second = url;
    HistoryStore* store = HistoryForTab(tabID);
    if (!store) return;
    const auto start = std::chrono::steady_clock::now();
    const bool changed = store->RecordVisit(url, "", Now());
    historyCost_.Add(std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count());
    if (changed) ArmHistorySave();
}

void BrowserWindowController::RecordTitle(const std::string& tabID, const std::string& title) {
    // The Mac's pageTitleChanged: for the address the tab last recorded; a repeat saves nothing.
    if (title.empty() || !history_) return;
    if (const Tab* tab = state_.FindTabByID(tabID); tab && tab->url && tab->url->starts_with("kite:")) return;
    auto it = recordedURLs_.find(tabID);
    if (it == recordedURLs_.end()) return;
    if (HistoryStore* store = HistoryForTab(tabID); store && store->UpdateTitle(it->second, title)) ArmHistorySave();
}

// MARK: Downloads

void BrowserWindowController::DownloadUpdated(const DownloadUpdate& update) {
    const auto start = std::chrono::steady_clock::now();
    const DownloadsModel::Outcome outcome = downloads_.Apply(update, FrameClock::Now());
    if (outcome.save) DownloadsChanged(outcome.save);
    // The Mac's requestUserAttention(.informational) as a download completes: the taskbar
    // button flashes, unless Kite is in front (or the run is quiet).
    if (outcome.applied && outcome.stateChanged && outcome.item.state == DownloadState::Complete && !options_.quiet &&
        GetForegroundWindow() != window_.Handle()) {
        FLASHWINFO flash{sizeof flash, window_.Handle(), FLASHW_TRAY, 2, 0};
        FlashWindowEx(&flash);
    }
    const double micros = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
    ++downloadCost_.reports;
    downloadCost_.maxMicros = std::max(downloadCost_.maxMicros, micros);
    downloadCost_.totalMicros += micros;
}

void BrowserWindowController::DownloadsChanged(std::optional<double> seconds) {
    if (!seconds || !downloadsWriter_) return;
    SetTimer(window_.Handle(), kDownloadsSaveTimer, static_cast<UINT>(std::ceil(*seconds * 1000)), nullptr);
}

void BrowserWindowController::SaveDownloadsNow() {
    KillTimer(window_.Handle(), kDownloadsSaveTimer);
    downloads_.Schedule().Saved();
    if (!downloadsWriter_ || !downloads_.MaySave()) return;
    const auto start = std::chrono::steady_clock::now();
    downloadsWriter_->Save(downloads_.List());
    const double micros = std::chrono::duration<double, std::micro>(std::chrono::steady_clock::now() - start).count();
    ++downloadCost_.saves;
    downloadCost_.saveMaxMicros = std::max(downloadCost_.saveMaxMicros, micros);
}

std::chrono::milliseconds BrowserWindowController::Left(std::chrono::steady_clock::time_point deadline) {
    const auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline - std::chrono::steady_clock::now());
    return std::max(left, std::chrono::milliseconds(0));
}

void BrowserWindowController::ReadDownloads() {
    if (!downloadsWriter_ || downloadsReadAsked_) return;
    downloadsReadAsked_ = true;
    downloadsRead_->target = window_.Handle();
    downloadsWriter_->Load([slot = downloadsRead_](std::optional<downloads_file::Loaded> loaded) {
        {
            std::lock_guard lock(slot->mutex);
            slot->result = std::move(loaded);
        }
        if (const HWND target = slot->target.load()) PostMessageW(target, kDownloadsReadMessage, 0, 0);
    });
}

void BrowserWindowController::DownloadsRead() {
    std::optional<std::optional<downloads_file::Loaded>> result;
    {
        std::lock_guard lock(downloadsRead_->mutex);
        result = std::exchange(downloadsRead_->result, std::nullopt);
    }
    if (!result || downloads_.Restored()) return;
    const std::optional<downloads_file::Loaded>& loaded = *result;
    // DownloadsModel.start's notes, to the debugger and a quiet run's stderr.
    std::wstring note;
    const std::wstring file = downloadsWriter_->File().wstring();
    if (!loaded) {
        note = L"couldn't read or move downloads; not saving over " + file + L" this launch";
    } else {
        if (loaded->movedAside) note = L"couldn't read downloads, moved them to " + loaded->movedAside->wstring();
        if (loaded->copiedAside) {
            note = L"couldn't read " + std::to_wstring(loaded->dropped) + L" of the downloads, kept the original at " +
                   loaded->copiedAside->wstring();
        }
        if (!loaded->canSave) note = L"not saving downloads over " + file + L" this launch";
    }
    if (!note.empty()) {
        OutputDebugStringW((L"Kite: " + note + L"\n").c_str());
        if (options_.quiet) WriteUtf8(STD_ERROR_HANDLE, L"Kite: " + note + L"\n");
    }
    DownloadsChanged(downloads_.Restore(loaded ? loaded->list : DownloadList(), loaded && loaded->canSave, FrameClock::Now()));
}

void BrowserWindowController::FinishDownloads(std::chrono::steady_clock::time_point deadline) {
    if (!downloadsWriter_ || downloads_.Restored() || !downloadsReadAsked_) return;
    // The window is gone, so the worker's post went nowhere: wait for the read itself.
    downloadsWriter_->Flush(Left(deadline));
    DownloadsRead();
    if (downloads_.Restored()) SaveDownloadsNow();
}

std::map<std::string, ProfileSettings> BrowserWindowController::DownloadLocations() const {
    std::map<std::string, ProfileSettings> byProfile{{BrowserState::kDefaultProfile, state_.Settings(std::string(BrowserState::kDefaultProfile))}};
    if (auto profiles = state_.extra.find("profiles"); profiles != state_.extra.end() && profiles->second.AsArray()) {
        for (const json::Value& profile : *profiles->second.AsArray()) {
            const json::Value* directory = profile.Find("directory");
            if (directory && directory->AsString()) byProfile.emplace(*directory->AsString(), state_.Settings(*directory->AsString()));
        }
    }
    return byProfile;
}

bool BrowserWindowController::MayQuit() {
    if (quitConfirmed_) return true;
    // A close that comes while the dialog is open (a second click on the close button) waits for it.
    if (askingToQuit_) return false;
    if (downloads_.List().Active().empty()) {
        quitConfirmed_ = true;
        return true;
    }
    askingToQuit_ = true;
    const bool close = RunDownloadsInProgress(window_.Handle(), options_.quiet);
    askingToQuit_ = false;
    if (!close) return false;
    quitConfirmed_ = true;
#ifdef KITE_HAS_CEF
    // Close Kite cancels them. Those still running now (some may have finished while it asked).
    std::vector<Chromium::DownloadKey> running;
    for (const DownloadItem& item : downloads_.List().Active()) {
        if (item.engineID) running.emplace_back(*item.engineID, item.engineContext.value_or(""));
    }
    if (chromium_) {
        chromium_->CancelDownloads(std::move(running), [this](const Chromium::DownloadKey& key) {
            if (const DownloadItem* item = downloads_.List().Item(key.first, key.second)) downloads_.CanceledWithoutEngine(*item);
        });
    }
#endif
    return true;
}

void BrowserWindowController::StateChanged(std::optional<SessionSaveDelay> save) {
    FindBarFollowsSelection();
    // A tab pinned by any path remembers its page, and a page reported by a pinned tab with none yet
    // becomes its pinned URL (the Mac's BrowserStore.mutate and mutatePage sync after every change):
    // a change there is a sidebar change, saved soon, whatever this update's own save was.
    if (state_.SyncPinnedURLs()) save = SessionSaveDelay::Soon;
    // A rename ends once its header or row isn't shown (another space selected, the space, tab or
    // folder gone or hidden in a closed folder), keeping what was typed, as leaving the field does:
    // renamed here, in this update, so the sidebar's Update stays a picture of the session.
    if (const auto renaming = sidebar_->Renaming(); renaming && !RenameStillShown(*renaming)) {
        if (const auto taken = sidebar_->TakeRename()) {
            ApplyRename(taken->first, taken->second);
            if (!save) save = SessionSaveDelay::Soon;
        }
    }
    if (save) SessionChanged(*save);
    SyncSpace();
    // The selected tab's page's status first, so the top row's update shows both together.
    ShowPageStatus();
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
    if (chromium_ && !(options_.smokeTest && holdPages_)) ShowSelectedTab();
#endif
}

void BrowserWindowController::LoadInTab(const std::string& tabID, const std::string& url) {
#ifdef KITE_HAS_CEF
    // kite:// pages are drawn by the window, never loaded (the Mac's InternalPage).
    if (!chromium_ || url.starts_with("kite:")) return;
    // A tab whose page closed itself (an unloaded pinned tab) gets a new one, as the selected tab's
    // (ShowPage: none for the smoke test's own tabs).
    if (!chromium_->Navigate(tabID, url)) ShowPage();
#else
    (void)tabID;
    (void)url;
#endif
}

void BrowserWindowController::PageGone(const std::string& tabID) {
    // Its status goes with it (BrowserStore.clearPage): a tab that comes back has no history.
    pageStatus_.erase(tabID);
#ifdef KITE_HAS_CEF
    if (!chromium_) return;
    chromium_->Close(tabID);
    ForgetRecorded(tabID);
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
    case CommandSuggestion::Kind::History:
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

// MARK: Find in page

bool BrowserWindowController::FindBarDark() const {
    const json::Value* appearance = nullptr;
    if (auto it = state_.extra.find("pageAppearance"); it != state_.extra.end()) appearance = &it->second;
    const std::string* name = appearance ? appearance->AsString() : nullptr;
    // Windows' apps' mode, as Automatic follows macOS's.
    DWORD light = 1, size = sizeof(light);
    RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize", L"AppsUseLightTheme",
                 RRF_RT_REG_DWORD, nullptr, &light, &size);
    return FindBarIsDark(name ? std::string_view(*name) : std::string_view(), light == 0);
}

void BrowserWindowController::ShowFind() {
    if (!findBar_) return;
    // As the Mac's showFind: no page, nothing to find in.
    // A page still being made counts (Ctrl+F straight after a new tab): its search waits for it.
    bool page = false;
#ifdef KITE_HAS_CEF
    page = chromium_ && chromium_->CanFind();
#endif
    const Tab* tab = state_.SelectedTab();
    if (!page || !tab) {
        MessageBeep(MB_OK);
        return;
    }
    findTabID_ = tab->id;
    findBar_->SetCard(ContentBounds());
    findBar_->Show(FindBarDark());
    // Ctrl+F over the command bar: the bar goes and the field takes the keyboard (GiveKeyboard
    // keeps the page from taking it as the bar closes).
    GiveKeyboard(KeyboardField::Find);
}

BrowserWindowController::KeyboardField BrowserWindowController::KeyboardOwner() const {
    if (commandBar_ && commandBar_->IsOpen()) return KeyboardField::CommandBar;
    if (sidebar_->Renaming()) return KeyboardField::Rename;
    if (findBar_ && findBar_->HasKeyboard()) return KeyboardField::Find;
    return KeyboardField::None;
}

void BrowserWindowController::GiveKeyboard(KeyboardField to, bool focusFindField) {
    if (to == KeyboardField::Find && findBar_) {
        // First, so nothing on the way hands the keyboard to the page: not the command bar
        // closing (BlockPages' Focus), not a navigation landing meanwhile.
#ifdef KITE_HAS_CEF
        if (chromium_) chromium_->KeepKeyboard(true);
#endif
        if (commandBar_ && commandBar_->IsOpen()) commandBar_->Hide();
    }
    // The others, so their system carets go before `to` makes its own.
    if (to != KeyboardField::Find && findBar_) findBar_->LoseKeyboard();
    if (to != KeyboardField::Rename) sidebar_->EndRenaming(true);
    if (to == KeyboardField::Find && findBar_ && focusFindField) findBar_->Focus();
    // A press in the field takes it itself, after this (focusFindField false): Kite keeps it.
    if (to == KeyboardField::Find && !focusFindField) return;
    UpdateFindHole();
}

void BrowserWindowController::StepFind(bool forward) {
    // stepFind: a closed or empty bar opens instead.
    if (!findBar_ || !findBar_->IsOpen() || findBar_->Query().Query().empty()) return ShowFind();
    findBar_->Step(forward);
}

void BrowserWindowController::FindInPage(const FindQuery::Search& search) {
#ifdef KITE_HAS_CEF
    if (!chromium_) return;
    if (search.text.empty()) chromium_->StopFinding();
    else chromium_->Find(search.text, search.forward, search.findNext);
#else
    (void)search;
#endif
}

void BrowserWindowController::HideFindBar(bool focusPage) {
    if (!findBar_ || !findBar_->IsOpen()) return;
    // The search ends in the page it ran in, which is still the shown one here.
#ifdef KITE_HAS_CEF
    if (chromium_) chromium_->StopFinding();
#endif
    findBar_->Query().Stopped();
    findBar_->Hide();
    findTabID_.clear();
    UpdateFindHole();
#ifdef KITE_HAS_CEF
    if (focusPage && chromium_ && GetForegroundWindow() == window_.Handle()) chromium_->Focus();
#else
    (void)focusPage;
#endif
}

void BrowserWindowController::FindBarFollowsSelection() {
    if (!findBar_ || !findBar_->IsOpen()) return;
    const Tab* tab = state_.SelectedTab();
    if (!tab || tab->id != findTabID_) HideFindBar(false);
}

void BrowserWindowController::UpdateFindHole() {
#ifdef KITE_HAS_CEF
    if (!chromium_) return;
    const bool open = findBar_ && findBar_->IsOpen();
    chromium_->SetOverlayHole(open ? findBar_->Frame() : RECT{}, open ? static_cast<int>(std::lround(findBar_->CornerRadiusPx())) : 0);
    chromium_->KeepKeyboard(open && findBar_->HasKeyboard());
#endif
}

RECT BrowserWindowController::ContentBounds() const {
    RECT client{};
    GetClientRect(window_.Handle(), &client);
    const int dpi = static_cast<int>(window_.Dpi());
    auto px = [dpi](int points) { return MulDiv(points, dpi, USER_DEFAULT_SCREEN_DPI); };
    // Its top under the caption buttons; its leading edge the sidebar's, or the inset once the
    // sidebar is hidden (not while it's still sliding off: a tab switch or a resize then would put
    // the page over it).
    const int left = static_cast<int>(CardLeft(sidebarShown_ || toggling_, static_cast<float>(kSidebarWidth)));
    const int inset = static_cast<int>(sidebar_toggle::kContentInset);
    RECT card{px(left), px(static_cast<int>(title_bar::kContentTop)), client.right - px(inset), client.bottom - px(inset)};
    card.right = std::max(card.right, card.left + 1);
    card.bottom = std::max(card.bottom, card.top + 1);
    return card;
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

void BrowserWindowController::ShowPageStatus() {
    const Tab* tab = state_.SelectedTab();
    const auto found = tab ? pageStatus_.find(tab->id) : pageStatus_.end();
    sidebar_->SetPageStatus(found != pageStatus_.end() ? found->second : PageStatus{});
}

void BrowserWindowController::ToggleSidebar() { SetSidebarShown(!sidebarShown_); }

void BrowserWindowController::SetSidebarShown(bool shown) {
    if (shown == sidebarShown_) return;
    // Hiding ends a rename, keeping what was typed, as the field editor leaving a hidden view does.
    if (!shown) sidebar_->EndRenaming(true);
    sidebarShown_ = shown;
    KillTimer(window_.Handle(), kToggleTimer);
    // Like Arc: the final frames set once, the compositor drawing the frames between (no slide
    // on a window that isn't on screen).
    const bool visible = IsWindowVisible(window_.Handle()) && !IsIconic(window_.Handle());
    const double duration = sidebar_->SetShown(shown, visible);
    toggling_ = duration > 0;
    // The display at its highest rate while it slides (docs/windows.md, Refresh rate).
    toggleBoost_.Set(toggling_);
    // The system menu's item says what it will do next (validateMenuItem's retitling).
    if (HMENU menu = GetSystemMenu(window_.Handle(), FALSE)) {
        ModifyMenuW(menu, kToggleSidebarMenuID, MF_BYCOMMAND | MF_STRING, kToggleSidebarMenuID, ToggleSidebarMenuText().c_str());
    }
    // The page clear of the sidebar: a show moves it first, a hide at the end.
    if (shown || !toggling_) MovePage();
    // Shown again, what changed while it was hidden draws before the slide's first frame.
    if (shown) {
        if (std::wstring problem = sidebar_->Draw(); !problem.empty()) {
            OutputDebugStringW((L"Kite: the sidebar couldn't draw: " + problem + L"\n").c_str());
        }
        if (sidebar_->DeviceLost()) Draw();
    }
    if (compositor_) compositor_->Commit();
    // The compositor starts it at the commit's frame, up to a frame after now: a frame at 60 Hz to
    // spare, as the pages' settle.
    if (toggling_) SetTimer(window_.Handle(), kToggleTimer, static_cast<UINT>(std::ceil(duration * 1000)) + 17, nullptr);
}

std::wstring BrowserWindowController::ToggleSidebarMenuText() const {
    std::wstring text = Widen(ToggleSidebarTitle(sidebarShown_));
    // A menu's key equivalent after a tab, as Windows' menus right-align it.
    if (const std::optional<KeyShortcut> shortcut = MenuShortcut(shortcuts_, "toggleSidebar")) text += L"\t" + Widen(shortcut->DisplayString());
    return text;
}

void BrowserWindowController::FinishToggle() {
    KillTimer(window_.Handle(), kToggleTimer);
    if (!toggling_) return;
    toggling_ = false;
    toggleBoost_.Set(false);
    sidebar_->SettleToggle();
    if (!sidebarShown_) MovePage();
    if (compositor_) compositor_->Commit();
}

void BrowserWindowController::MovePage() {
#ifdef KITE_HAS_CEF
    if (chromium_) chromium_->SetBounds(ContentBounds());
#endif
    // The find bar keeps the card's top-right corner (narrower in a narrow card), the page's hole
    // under it.
    if (findBar_) findBar_->SetCard(ContentBounds());
    UpdateFindHole();
}

void BrowserWindowController::MakeCommands() {
    // What each shortcut's command does: the Mac's menu items of the same ids (MainMenu.swift).
    commands_ = {
        {"newTab", [this] { OpenCommandBar(CommandBarMode::NewTab); }},
        {"openLocation", [this] { OpenCommandBar(CommandBarMode::EditCurrent); }},
        {"archiveTab", [this] { ArchiveTab(); }},
        {"reopenClosedTab", [this] { ReopenClosedTab(); }},
        {"importFromArc", [this] { ImportFromArc(); }},
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
        {"toggleSidebar", [this] { ToggleSidebar(); }},
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
        {"find", [this] { ShowFind(); }},
        {"findNext", [this] { StepFind(true); }},
        {"findPrevious", [this] { StepFind(false); }},
    };
    MakeTabCommands();
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
    auto it = commands_.find(command);
    if (it == commands_.end()) return;
    if (!perf::On()) return it->second();
    perf::Mark("command-begin", command);
    it->second();
    perf::Mark("command-end", command);
}

bool BrowserWindowController::QueuePerfRequest(const COPYDATASTRUCT* data) {
    if (!data || data->dwData != perf::kControlTag || !data->lpData || !data->cbData) return false;
    auto parsed = json::Parse(std::string_view(static_cast<const char*>(data->lpData), data->cbData));
    const json::Value* request = std::get_if<json::Value>(&parsed);
    if (!request || !request->AsObject()) return false;
    const auto text = [&](std::string_view key) -> const std::string* {
        const json::Value* value = request->Find(key);
        return value ? value->AsString() : nullptr;
    };
    const auto number = [&](std::string_view key) -> std::optional<int64_t> {
        const json::Value* value = request->Find(key);
        return value ? value->AsInt() : std::nullopt;
    };
    PerfRequest queued{PerfRequest::Kind::Mark, {}, 0, 0, 0};
    if (const std::string* command = text("command")) {
        if (!commands_.contains(*command) || !CommandEnabled(*command)) return false;
        queued = {PerfRequest::Kind::Command, *command, 0, 0, number("qpc").value_or(perf::Now())};
    } else if (const std::string* mark = text("mark")) {
        queued = {PerfRequest::Kind::Mark, *mark, 0, 0, 0};
    } else if (const std::string* url = text("open")) {
        // Web pages only: nothing of the machine's (file:, view-source:, kite: or a script).
        if (!url->starts_with("http://") && !url->starts_with("https://")) return false;
        queued = {PerfRequest::Kind::Open, *url, 0, 0, 0};
    } else if (const std::string* input = text("input")) {
        if (*input == "leave") {
            queued = {PerfRequest::Kind::Leave, {}, 0, 0, 0};
        } else {
            const auto x = number("x"), y = number("y");
            if (*input != "move" || !x || !y || *x < 0 || *y < 0 || *x > 0x7FFF || *y > 0x7FFF) return false;
            queued = {PerfRequest::Kind::Move, {}, *x, *y, number("qpc").value_or(perf::Now())};
        }
    } else {
        return false;
    }
    if (perfRequests_.size() >= 256) return false;  // a sender that never lets the loop run
    perfRequests_.push_back(std::move(queued));
    if (perfRequests_.size() == 1) PostMessageW(window_.Handle(), kPerfRequestMessage, 0, 0);
    return true;
}

void BrowserWindowController::RunPerfRequests() {
    std::vector<PerfRequest> requests;
    requests.swap(perfRequests_);
    for (PerfRequest& r : requests) {
        switch (r.kind) {
        case PerfRequest::Kind::Command:
            // The state may have changed since it was queued.
            if (!CommandEnabled(r.text)) {
                perf::Mark("control-refused", r.text);
                break;
            }
            if (perf::On()) perf::Input("command", r.qpc);
            RunCommand(r.text);
            break;
        case PerfRequest::Kind::Mark: perf::Mark(r.text); break;
        case PerfRequest::Kind::Open:
            state_.OpenTab(r.text);
            SelectionMoved();
            break;
        case PerfRequest::Kind::Move:
            perfPointer_ = true;
            if (PostMessageW(window_.Handle(), WM_MOUSEMOVE, 0, MAKELPARAM(r.x, r.y))) {
                ++perfMovesPosted_;
                if (perf::On()) perf::Input("move", r.qpc);
            }
            break;
        case PerfRequest::Kind::Leave:
            perfPointer_ = false;
            perfMovesPosted_ = 0;
            if (PostMessageW(window_.Handle(), WM_MOUSELEAVE, 0, 0)) ++perfLeavesPosted_;
            break;
        }
    }
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
    if (findBar_) findBar_->UseCompositor(nullptr);
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
        if (findBar_) findBar_->UseCompositor(compositor_.get());
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
        const auto lost = [this] {
            return !compositor_ || compositor_->DeviceLost() || sidebar_->DeviceLost() || caption_->DeviceLost() ||
                   (findBar_ && findBar_->DeviceLost());
        };
        if (lost()) {
            if (problem = Rebuild(); !problem.empty()) break;
        }
        problem = compositor_->Draw(
            width, height, MakeThemeUniforms(theme_.from, theme_.to, progress, static_cast<float>(width), static_cast<float>(height)),
            base_, readBack);
        // The sidebar and the buttons with it, shown together at the commit.
        if (problem.empty()) problem = sidebar_->Draw();
        if (problem.empty()) problem = caption_->Draw();
        if (problem.empty()) compositor_->Commit();
        if (!lost()) break;
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
    // Whatever moves the content card (this resize, the sidebar's toggle in MovePage; later
    // splits) puts the find bar in its corner again and the page's hole under it.
    if (findBar_) findBar_->SetCard(ContentBounds());
    UpdateFindHole();
#ifdef KITE_HAS_CEF
    if (chromium_) {
        chromium_->WindowMoved();
        ShowFirstPage();  // restored after a minimized launch
    }
#endif
}

// MARK: The window's messages

bool BrowserWindowController::Filter(UINT message, WPARAM wParam, LPARAM lParam, LRESULT& result) {
    static_assert([] {
        constexpr UINT ids[] = {MainWindow::kWakeMessage, CommandBarView::kRedrawMessage, SidebarView::kRedrawMessage, kFaviconsMessage,
                                kFrameMessage, kSpaceIconsMessage, kMemoryPressureMessage, kHistoryMessage, kArcReadMessage, kArcSavedMessage,
                                kDownloadsReadMessage, kPerfRequestMessage};
        for (size_t i = 0; i < std::size(ids); ++i) {
            for (size_t j = i + 1; j < std::size(ids); ++j) {
                if (ids[i] == ids[j]) return false;
            }
        }
        return true;
    }(), "two of the window's WM_APP messages share an id");
    if (options_.perfControl) {
        if (message == WM_COPYDATA) {
            result = QueuePerfRequest(reinterpret_cast<const COPYDATASTRUCT*>(lParam)) ? 1 : 0;
            return true;
        }
        if (message == kPerfRequestMessage) {
            RunPerfRequests();
            return true;
        }
    }
    // The real pointer's moves and leaves, not the ones --perf-control posted (they arrive in
    // order), nor the leave TrackMouseEvent sends at once while a posted pointer is over the
    // window (the real one is elsewhere).
    if (message == WM_MOUSEMOVE && perfMovesPosted_) --perfMovesPosted_;
    else if (message == WM_MOUSELEAVE && perfLeavesPosted_) --perfLeavesPosted_;
    else if (message == WM_MOUSEMOVE || message == WM_NCMOUSEMOVE || message == WM_NCMOUSELEAVE ||
             (message == WM_MOUSELEAVE && !perfPointer_)) {
        perf::CountPointerMove();
    }
    if (message == WM_DISPLAYCHANGE && perf::On()) perf::DisplayChanged();
    // The real pointer isn't over the window while --perf-control moves one: TrackMouseEvent's
    // leave would take the hover straight off again.
    if (message == WM_MOUSELEAVE && perfPointer_) {
        result = 0;
        return true;
    }
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
    // Kite's shortcuts, wherever the keyboard is in Kite's own window, the bar's field and the
    // rename's included (as the Mac's menus come before its field editor), but for keys the
    // fields edit with (Alt+Left). Alt's come as WM_SYSKEYDOWN. A page's come through Chromium.
    if (message == WM_KEYDOWN || message == WM_SYSKEYDOWN) {
        dropCharacter_ = false;
        const auto pressed =
            ShortcutOfKey(static_cast<UINT>(wParam), GetKeyState(VK_CONTROL) < 0, GetKeyState(VK_MENU) < 0, GetKeyState(VK_SHIFT) < 0);
        const ShortcutTarget* target = pressed ? FindShortcut(shortcuts_, *pressed) : nullptr;
        const bool editing = KeyboardOwner() != KeyboardField::None;
        if (target && !(editing && EditsText(*pressed)) && CommandEnabled(target->command->id)) {
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
    // The header's rename field, when a space is renamed: its keys, characters and focus.
    if (sidebar_->HandleKey(message, wParam, lParam)) {
        result = message == WM_SETCURSOR ? TRUE : 0;
        return true;
    }
    if (findBar_) {
        const bool handled = findBar_->HandleMessage(message, wParam, lParam, result);
        // Who has the keyboard decides whether a navigation may take it.
        if (message == WM_SETFOCUS || message == WM_KILLFOCUS || message == WM_LBUTTONDOWN) UpdateFindHole();
        if (handled) return true;
        // The system's light or dark mode changed: the bar follows (pageAppearance automatic).
        if (message == WM_SETTINGCHANGE && lParam && std::wstring_view(reinterpret_cast<const wchar_t*>(lParam)) == L"ImmersiveColorSet") {
            findBar_->SetDark(FindBarDark());
        }
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
        // A test run steps its own (RunUntil), and one posted before it began is dropped.
        if (clock_->Running() && !clock_->Manual()) {
            double rate = 0;
            const double time = FrameClock::NextFrameTime(compositor_ ? compositor_->Device() : nullptr, perf::On() ? &rate : nullptr);
            Frame(time, rate);
        }
        clock_->Delivered();
        return true;
    }
    if (message == WM_TIMER && wParam == kSaveTimer) {
        SaveNow();
        return true;
    }
    if (message == WM_TIMER && wParam == kHistoryTimer) {
        KillTimer(window_.Handle(), kHistoryTimer);
        if (history_) history_->SaveDue();
        ArmHistorySave();
        return true;
    }
    if (message == kHistoryMessage) {
        // A profile's history.json has been read: it takes the place of what this run had (its
        // visits replayed over it), and an open bar shows its rows.
        std::vector<std::string> problems;
        if (history_ && history_->Adopt(&problems)) {
            if (commandBar_ && commandBar_->IsOpen()) commandBar_->Refresh();
            ArmHistorySave();
        }
        // A file that didn't read was moved aside (or, if it couldn't be, is left alone and not
        // saved over); the Mac logs it too. The save log's history block has the default's.
        for (const std::string& problem : problems) {
            OutputDebugStringW((L"Kite: history couldn't be read, starting without it: " + Widen(problem) + L"\n").c_str());
        }
        return true;
    }
    if (message == WM_TIMER && wParam == kDownloadsSaveTimer) {
        SaveDownloadsNow();
        return true;
    }
    if (message == kDownloadsReadMessage) {
        DownloadsRead();
        return true;
    }
#ifdef KITE_HAS_CEF
    if (message == WM_TIMER && chromium_ && chromium_->HandleTimer(wParam)) return true;
#endif
    if (message == WM_TIMER && wParam == kTestCloseTabTimer) {
        KillTimer(window_.Handle(), kTestCloseTabTimer);
#ifdef KITE_HAS_CEF
        // First a click's user activation for the page (so it may ask Leave Page), then the close.
        if (!testGestureGiven_ && chromium_ && chromium_->TestUserGesture()) {
            testGestureGiven_ = true;
            SetTimer(window_.Handle(), kTestCloseTabTimer, 500, nullptr);
            return true;
        }
#endif
        if (const Tab* tab = state_.SelectedTab()) CloseTab(tab->id);
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
    if (message == WM_TIMER && wParam == kToggleTimer) {
        FinishToggle();
        return true;
    }
    if (message == WM_SYSCOMMAND && (wParam & 0xFFF0) == kToggleSidebarMenuID) {
        RunCommand("toggleSidebar");
        result = 0;
        return true;
    }
    if (message == kSpaceIconsMessage) {
        sidebar_->PicturesArrived();
        return true;
    }
    // Each of the window's own messages has its own id (W15 and W11 once took the same two).
    static_assert(kArcReadMessage > kHistoryMessage && kArcSavedMessage > kArcReadMessage, "the window's message ids overlap");
    if (message == kArcReadMessage) {
        ArcRead();
        return true;
    }
    if (message == kArcSavedMessage) {
        ArcSaved();
        return true;
    }
    if (message == WM_TIMER && wParam == kArcMergeTimer) {
        KillTimer(window_.Handle(), kArcMergeTimer);
        ArcSaved();
        return true;
    }
    if (message == WM_SYSCOMMAND && (wParam & 0xFFF0) == kImportFromArcMenuID) {
        RunCommand("importFromArc");
        result = 0;
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

void BrowserWindowController::Show(int showCommand) {
    // Quiet runs open behind other windows and never activate, and ignore a launcher's "start
    // maximized".
    if (options_.quiet) {
        window_.NeverActivate();
        window_.ShowBehindOtherWindows();
    } else {
        window_.Show(showCommand);
    }
    // Before the first page, whose first download then usually finds the history already in.
    ReadDownloads();
#ifdef KITE_HAS_CEF
    ShowFirstPage();
#endif
    if (options_.saveLog && options_.testCloseTabMs) SetTimer(window_.Handle(), kTestCloseTabTimer, *options_.testCloseTabMs, nullptr);
    // The auto-archive's later passes (the launch's ran before the window). A capture never archives.
    if (!options_.capture) SetTimer(window_.Handle(), kArchiveTimer, kArchiveIntervalMs, nullptr);
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
        // --perf-log looks up when committed frames reached the screen, every 16 ms while any wait.
        const bool polling = perf::On() && perf::Pending();
        if (polling && timeout == INFINITE) timeout = 16;
        const DWORD woke =
            MsgWaitForMultipleObjectsEx(removed ? 1 : 0, removed ? &removed : nullptr, timeout, QS_ALLINPUT, MWMO_INPUTAVAILABLE);
        if (polling) perf::Poll();
        if ((removed && woke == WAIT_OBJECT_0) || (woke == WAIT_TIMEOUT && !compositor_)) {
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
            if (perf::On()) {
                const int64_t began = perf::Now();
                DispatchMessageW(&message);
                perf::Dispatched(message.message, began);
            } else {
                DispatchMessageW(&message);
            }
        }
    }
}

}  // namespace kite

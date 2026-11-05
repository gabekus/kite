// The window controller's test runs: --smoke-test's checks and --capture's frames and the states
// they hold (a swipe, a drag in the space bar, the space menu, the rename field). See
// BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#include <algorithm>
#include <cmath>

#include "core/SpaceBar.h"
#include "core/SpaceEditing.h"
#include "shell/Capture.h"
#include "shell/SpaceMenu.h"
#include "shell/Text.h"

namespace kite {

namespace {

bool Inked(const Pixels& pixels, UINT fromRow = 0) {
    for (size_t i = static_cast<size_t>(fromRow) * pixels.width * 4 + 3; i < pixels.bgra.size(); i += 4) {
        if (pixels.bgra[i] != 0) return true;
    }
    return false;
}

}  // namespace

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
        // And editing them: drags in the bar, the menu, renaming, New Folder, Delete Space.
        if (std::wstring problem = SmokeTestSpaceEditing(); !problem.empty()) return problem;
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

std::wstring BrowserWindowController::Capture(Pixels& pixels, const std::optional<std::string>& barText, std::optional<size_t> tip,
                                              const std::optional<CaptureFind>& find) {
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
    if (problem.empty() && find) {
        // The find bar as Ctrl+F opens it over the selected tab, the query typed in and the page's
        // report shown (no Chromium in a capture, so no page to ask).
        if (!findBar_) return L"Kite couldn't make the find bar";
        if (const Tab* tab = state_.SelectedTab()) findTabID_ = tab->id;
        else return L"--find needs a selected tab";
        findBar_->SetCard(ContentBounds());
        findBar_->Show(FindBarDark());
        findBar_->Type(find->query);
        if (find->result) findBar_->ShowResult(*find->result);
        Pixels bar;
        POINT origin{};
        problem = findBar_->Draw(&bar, &origin);
        if (problem.empty()) ComposeOver(pixels, bar, origin);
    }
    if (problem.empty() && heldMenu_) {
        // The space's menu as a right-click on its cell opens it, read back from Windows' menu
        // and put where Windows puts one with no room under the pointer: its bottom-left there.
        const std::optional<POINT> at = sidebar_->SpaceCellCentre(*heldMenu_);
        if (!at || *heldMenu_ >= state_.spaces.size()) return L"there's no such space for the menu";
        POINT screen = *at;
        ClientToScreen(window_.Handle(), &screen);
        Pixels menu;
        problem = RenderSpaceMenu(window_.Handle(), SpaceMenu(state_, state_.spaces[*heldMenu_].id), screen, dark_.value_or(true),
                                  window_.Dpi(), menu);
        if (problem.empty()) ComposeOver(pixels, menu, POINT{at->x, at->y - static_cast<LONG>(menu.height)});
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

namespace {

// A mouse message to the window, as the pointer would send it at `at` (client px).
void SendMouse(HWND window, UINT message, POINT at, WPARAM buttons) { SendMessageW(window, message, buttons, MAKELPARAM(at.x, at.y)); }

}  // namespace

std::wstring BrowserWindowController::WaitForDrop() {
    // The landing's timer (2 s at most).
    return RunUntil([this] { return !sidebar_->DraggingSpace(); }, 2) ? L"" : L"the drop never landed";
}

std::wstring BrowserWindowController::HoldSpaceDrag(size_t index, float x, bool drop) {
    const std::optional<POINT> from = sidebar_->SpaceCellCentre(index);
    if (!from) return L"there's no such space";
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    const POINT to{std::lround(x * scale), from->y};
    // Pressed on the cell's centre, then a pointer's moves along to `x`, a few px at a time.
    SendMouse(window_.Handle(), WM_LBUTTONDOWN, *from, MK_LBUTTON);
    const LONG distance = to.x - from->x;
    const LONG steps = std::max(2L, std::abs(distance) / 8);
    for (LONG i = 1; i <= steps; ++i) SendMouse(window_.Handle(), WM_MOUSEMOVE, POINT{from->x + distance * i / steps, from->y}, MK_LBUTTON);
    if (!sidebar_->DraggingSpace()) return L"the drag didn't begin";
    if (!drop) return {};
    SendMouse(window_.Handle(), WM_LBUTTONUP, to, 0);
    return WaitForDrop();
}

std::wstring BrowserWindowController::HoldRename(size_t index, const std::optional<std::string>& text, bool focused) {
    if (index >= state_.spaces.size()) return L"there's no such space";
    const std::string id = state_.spaces[index].id;
    const bool switches = state_.selectedSpaceID != id;
    RunSpaceMenuItem(id, SpaceMenuItem::Command::Rename);
    // Renaming another space selects it: its page slides in first.
    if (switches) {
        if (std::wstring problem = RunToRest(L"Rename Space"); !problem.empty()) return problem;
    }
    if (sidebar_->Renaming() != id) return L"the rename field didn't open";
    if (text) sidebar_->TypeInRename(*text);
    if (focused) sidebar_->FocusRenameForCapture();
    return {};
}

#ifdef KITE_HAS_CEF

void BrowserWindowController::CloseAfterSmoke() {
    closeAskedAt_ = GetTickCount64();
    PostMessageW(window_.Handle(), WM_CLOSE, 0, 0);
}

void BrowserWindowController::FailSmokeFind(std::wstring problem) {
    smokeFindProblem_ = std::move(problem);
    smokeFind_ = SmokeFind::Done;
    HideFindBar(false);
    CloseAfterSmoke();
}

void BrowserWindowController::StartSmokeFind() {
    if (!findBar_ || !chromium_->CanFind()) return CloseAfterSmoke();
    smokeFind_ = SmokeFind::Matching;
    ShowFind();
    if (std::wstring problem = SmokeTestKeyboard(); !problem.empty()) return FailSmokeFind(std::move(problem));
    findBar_->Type("kite SMOKE");  // case-insensitive, as the Mac's find
}

std::wstring BrowserWindowController::SmokeTestKeyboard() {
    // One field at a time has the keyboard (and the thread's one system caret).
    if (KeyboardOwner() != KeyboardField::Find) return L"Ctrl+F didn't give the find field the keyboard";
    const size_t index = state_.SelectedSpaceIndex();
    const std::string id = state_.spaces[index].id, name = state_.spaces[index].name;
    const auto restore = [&] {
        state_.RenameSpace(id, name);
        StateChanged();
    };
    // A rename started while the find field has it takes it, and the keys go to the rename.
    BeginRenaming(id);
    if (KeyboardOwner() != KeyboardField::Rename || findBar_->HasKeyboard()) return L"a rename didn't take the keyboard from the find field";
    SendMessageW(window_.Handle(), WM_CHAR, L'Q', 0);
    SendMessageW(window_.Handle(), WM_KEYDOWN, VK_RETURN, 0);
    if (sidebar_->Renaming() || state_.spaces[index].name != "Q" || !findBar_->Query().Query().empty()) {
        return L"keys typed in a rename begun over the find field didn't go to the rename";
    }
    restore();
    // Ctrl+F ends a rename, keeping what was typed, and takes the keyboard back.
    BeginRenaming(id);
    sidebar_->TypeInRename("R");
    ShowFind();
    if (sidebar_->Renaming() || state_.spaces[index].name != "R" || KeyboardOwner() != KeyboardField::Find) {
        return L"Ctrl+F didn't end the rename and take the keyboard";
    }
    restore();
    // A press on the bar's down arrow leaves the keyboard where it was (borderless NSButtons
    // don't become first responder); a press in its field takes it, ending the rename.
    BeginRenaming(id);
    for (UINT message : {WM_LBUTTONDOWN, WM_LBUTTONUP}) {
        SendMouse(window_.Handle(), message, findBar_->ClientPointOf(FindBarView::Part::Next), message == WM_LBUTTONDOWN ? MK_LBUTTON : 0);
    }
    if (sidebar_->Renaming() != id || findBar_->HasKeyboard()) return L"a press on the find bar's arrow took the keyboard";
    for (UINT message : {WM_LBUTTONDOWN, WM_LBUTTONUP}) {
        SendMouse(window_.Handle(), message, findBar_->ClientPointOf(FindBarView::Part::Field), message == WM_LBUTTONDOWN ? MK_LBUTTON : 0);
    }
    if (sidebar_->Renaming() || KeyboardOwner() != KeyboardField::Find) return L"a press in the find field didn't take the keyboard from the rename";
    restore();
    // The command bar takes it from the find field, and hands it to the page as it closes.
    OpenCommandBar(CommandBarMode::NewTab);
    if (KeyboardOwner() != KeyboardField::CommandBar || findBar_->HasKeyboard()) return L"the command bar didn't take the keyboard from the find field";
    commandBar_->Hide();
    if (KeyboardOwner() != KeyboardField::None || !findBar_->IsOpen()) return L"the command bar closing didn't leave the find bar open without the keyboard";
    ShowFind();
    return {};
}

void BrowserWindowController::SmokeTestFind(int count, int activeMatch, bool final) {
    // A search's last report, once its first match is active (a new search reports twice: its
    // highlights, then the step that makes the first match active).
    if (!final || !findBar_) return;
    const std::string label = findBar_->Query().Label();
    switch (smokeFind_) {
    case SmokeFind::Matching: {
        if (activeMatch < 1) return;
        // windows/helix/pages/smoke.html says "Kite smoke page" once in its body.
        if (count != 1 || activeMatch != 1) return FailSmokeFind(L"\"kite SMOKE\" found " + std::to_wstring(count) + L" matches, the page has 1");
        if (label != "1/1") return FailSmokeFind(L"the counter read \"" + Widen(label) + L"\" for 1 of 1");
        // The page's window has its hole under the bar, and only there.
        smokeFindFrame_ = findBar_->Frame();
        const RECT& frame = smokeFindFrame_;
        const POINT inside{(frame.left + frame.right) / 2, (frame.top + frame.bottom) / 2};
        const POINT outside{frame.left - 20, frame.bottom + 20};
        // Its rounded corner is the page's, and the bar's opaque inside isn't.
        const POINT corner{frame.left, frame.top};
        if (chromium_->PageTakesClickAt(inside)) return FailSmokeFind(L"a click on the bar would reach the page");
        if (!chromium_->PageTakesClickAt(outside)) return FailSmokeFind(L"a click on the page beside the bar wouldn't reach it");
        if (!chromium_->PageTakesClickAt(corner)) return FailSmokeFind(L"the hole isn't rounded at the bar's corner");
        smokeFind_ = SmokeFind::Missing;
        findBar_->Type(" zqxj");
        return;
    }
    case SmokeFind::Missing: {
        // A stale search's last report can still come; only no match counts.
        if (count != 0) return;
        if (label != "Not Found") return FailSmokeFind(L"the counter read \"" + Widen(label) + L"\" for no match");
        smokeFind_ = SmokeFind::Done;
        HideFindBar(false);
        if (!findBar_->Query().Query().empty() || findBar_->IsOpen()) return FailSmokeFind(L"the bar didn't close");
        // The hole goes with it, on CEF's thread.
        const POINT inside{(smokeFindFrame_.left + smokeFindFrame_.right) / 2, (smokeFindFrame_.top + smokeFindFrame_.bottom) / 2};
        if (!RunUntil([&] { return chromium_->PageTakesClickAt(inside); }, 2)) return FailSmokeFind(L"the page's hole stayed after the bar closed");
        if (HANDLE out = GetStdHandle(STD_OUTPUT_HANDLE); out && out != INVALID_HANDLE_VALUE) {
            static constexpr char kReport[] =
                "Kite smoke test: find in page read 1/1, then Not Found; the page's window had its rounded hole under the bar, "
                "and lost it as the bar closed; the keyboard went to one field at a time\n";
            DWORD written = 0;
            WriteFile(out, kReport, static_cast<DWORD>(sizeof kReport - 1), &written, nullptr);
        }
        CloseAfterSmoke();
        return;
    }
    case SmokeFind::Idle:
    case SmokeFind::Done: return;
    }
}

#endif  // KITE_HAS_CEF

std::wstring BrowserWindowController::SmokeTestSpaceEditing() {
    const auto ids = [&] {
        std::vector<std::string> now;
        for (const Space& space : state_.spaces) now.push_back(space.id);
        return now;
    };
    const std::vector<std::string> order = ids();
    const std::string selected = state_.selectedSpaceID;
    const float scale = static_cast<float>(window_.Dpi()) / USER_DEFAULT_SCREEN_DPI;
    const auto cellX = [&](size_t index) { return static_cast<float>(sidebar_->SpaceCellCentre(index)->x) / scale; };
    const size_t lastIndex = state_.spaces.size() - 1;

    // The first space's cell dragged past the last and dropped there: it's last, and the
    // selection stays on the space it was; then dragged back to the front.
    if (std::wstring problem = HoldSpaceDrag(0, cellX(lastIndex) + 20, true); !problem.empty()) return L"a drag in the space bar: " + problem;
    if (ids().back() != order.front() || state_.selectedSpaceID != selected) return L"a drop in the space bar didn't move the space";
    if (std::wstring problem = HoldSpaceDrag(lastIndex, cellX(0) - 20, true); !problem.empty()) {
        return L"a drag back in the space bar: " + problem;
    }
    if (ids() != order) return L"a drag back in the space bar didn't put the space first again";
    // A drag let go off the strip (above the bar) goes back where it came from, moving nothing.
    if (std::wstring problem = HoldSpaceDrag(0, cellX(lastIndex), false); !problem.empty()) return L"a drag in the space bar: " + problem;
    SendMouse(window_.Handle(), WM_LBUTTONUP, POINT{std::lround(cellX(lastIndex) * scale), 0}, 0);
    if (std::wstring problem = WaitForDrop(); !problem.empty()) return problem;
    if (ids() != order) return L"a drag dropped off the strip moved a space";
    // The mouse taken away mid-drag (WM_CAPTURECHANGED) sends the cell back where it came from.
    if (std::wstring problem = HoldSpaceDrag(0, cellX(lastIndex) + 20, false); !problem.empty()) return L"a drag in the space bar: " + problem;
    ReleaseCapture();
    if (std::wstring problem = WaitForDrop(); !problem.empty()) return problem;
    SendMouse(window_.Handle(), WM_LBUTTONUP, POINT{std::lround((cellX(lastIndex) + 20) * scale), sidebar_->SpaceCellCentre(0)->y}, 0);
    if (sidebar_->DraggingSpace() || ids() != order) return L"a drag whose mouse went elsewhere moved a space";
    // A drop still landing refuses a new drag (the Mac's reorder?.landing guard).
    if (std::wstring problem = HoldSpaceDrag(0, cellX(lastIndex) + 20, false); !problem.empty()) return L"a drag in the space bar: " + problem;
    SendMouse(window_.Handle(), WM_LBUTTONUP, POINT{std::lround((cellX(lastIndex) + 20) * scale), sidebar_->SpaceCellCentre(0)->y}, 0);
    const std::string landing = order.front();
    HoldSpaceDrag(1, cellX(0), false);
    if (sidebar_->DraggedSpace() != landing) return L"a new drag began while a drop was landing";
    SendMouse(window_.Handle(), WM_LBUTTONUP, POINT{std::lround(cellX(0) * scale), sidebar_->SpaceCellCentre(0)->y}, 0);
    if (std::wstring problem = WaitForDrop(); !problem.empty()) return problem;
    if (ids().back() != landing) return L"a drop that refused a second drag didn't land";
    if (std::wstring problem = HoldSpaceDrag(lastIndex, cellX(0) - 20, true); !problem.empty()) return L"a drag back: " + problem;
    if (ids() != order) return L"a drag back didn't put the space first again";
    // The spaces changing under a drag (one added) end it, moving nothing.
    if (std::wstring problem = HoldSpaceDrag(0, cellX(lastIndex), false); !problem.empty()) return L"a drag in the space bar: " + problem;
    const std::optional<std::string> added = NewSpace(state_, "Under the drag");
    state_.SelectSpace(selected);
    StateChanged();
    if (sidebar_->DraggingSpace()) return L"a drag went on after the spaces changed";
    SendMouse(window_.Handle(), WM_LBUTTONUP, POINT{std::lround(cellX(lastIndex) * scale), sidebar_->SpaceCellCentre(0)->y}, 0);
    if (std::wstring problem = WaitForDrop(); !problem.empty()) return problem;
    state_.DeleteSpace(*added);
    StateChanged();
    if (ids() != order) return L"a drag ended by the spaces changing moved a space";

    // The menu has the Mac's items, Rename and Delete among them.
    const std::vector<SpaceMenuItem> menu = SpaceMenu(state_, selected);
    if (menu.size() != 10 || std::none_of(menu.begin(), menu.end(), [](const SpaceMenuItem& item) {
            return item.command == SpaceMenuItem::Command::Rename && item.enabled;
        })) {
        return L"the space menu isn't the Mac's";
    }

    // Rename Space…: the field opens with the name, takes what's typed, and Return renames.
    const size_t index = state_.SelectedSpaceIndex();
    const std::string name = state_.spaces[index].name;
    if (std::wstring problem = HoldRename(index, "Smoke"); !problem.empty()) return problem;
    if (std::wstring problem = Draw(); !problem.empty()) return L"the rename field couldn't draw: " + problem;
    SendMessageW(window_.Handle(), WM_KEYDOWN, VK_RETURN, 0);
    if (sidebar_->Renaming() || state_.spaces[index].name != "Smoke") return L"Return didn't rename the space";
    // Escape leaves the name as it was.
    if (std::wstring problem = HoldRename(index, "Not this"); !problem.empty()) return problem;
    SendMessageW(window_.Handle(), WM_KEYDOWN, VK_ESCAPE, 0);
    if (sidebar_->Renaming() || state_.spaces[index].name != "Smoke") return L"Escape renamed the space";
    // A press elsewhere in the sidebar (on the space's own cell) keeps what was typed.
    if (std::wstring problem = HoldRename(index, name); !problem.empty()) return problem;
    const POINT cell = *sidebar_->SpaceCellCentre(index);
    SendMouse(window_.Handle(), WM_LBUTTONDOWN, cell, MK_LBUTTON);
    SendMouse(window_.Handle(), WM_LBUTTONUP, cell, 0);
    if (sidebar_->Renaming() || state_.spaces[index].name != name) return L"leaving the rename field didn't rename the space";
    // Done renames when let go over it.
    if (std::wstring problem = HoldRename(index, "Done"); !problem.empty()) return problem;
    if (std::wstring problem = Draw(); !problem.empty()) return L"the rename field couldn't draw: " + problem;
    const POINT done = *sidebar_->RenameDoneCentre();
    SendMouse(window_.Handle(), WM_LBUTTONDOWN, done, MK_LBUTTON);
    if (!sidebar_->Renaming()) return L"a press on Done ended the rename before it was let go";
    SendMouse(window_.Handle(), WM_LBUTTONUP, done, 0);
    if (sidebar_->Renaming() || state_.spaces[index].name != "Done") return L"Done didn't rename the space";
    // The page taking the keyboard keeps what was typed (a child window of Kite's for the page).
    if (std::wstring problem = HoldRename(index, "Page"); !problem.empty()) return problem;
    if (HWND page = CreateWindowExW(0, L"STATIC", L"", WS_CHILD, 0, 0, 1, 1, window_.Handle(), nullptr, instance_, nullptr)) {
        SendMessageW(window_.Handle(), WM_KILLFOCUS, reinterpret_cast<WPARAM>(page), 0);
        DestroyWindow(page);
    }
    if (sidebar_->Renaming() || state_.spaces[index].name != "Page") return L"the page taking the keyboard didn't rename the space";
    // Another app taking it doesn't end the rename (AppKit keeps a field's editing).
    if (std::wstring problem = HoldRename(index, "Elsewhere"); !problem.empty()) return problem;
    SendMessageW(window_.Handle(), WM_KILLFOCUS, 0, 0);
    if (sidebar_->Renaming() != selected) return L"another app taking the keyboard ended the rename";
    // The space menu opening ends it, keeping what was typed.
    if (OpenSpaceMenu(selected).empty() || sidebar_->Renaming() || state_.spaces[index].name != "Elsewhere") {
        return L"the space menu opening didn't end the rename";
    }
    // Another space shown ends it in the same update, keeping what was typed.
    if (std::wstring problem = HoldRename(index, "Switched"); !problem.empty()) return problem;
    RunCommand(index + 1 < state_.spaces.size() ? "nextSpace" : "previousSpace");
    if (sidebar_->Renaming() || state_.spaces[index].name != "Switched") return L"another space shown didn't end the rename";
    state_.RenameSpace(selected, name);
    if (std::wstring problem = RunToRest(L"A switch ending a rename"); !problem.empty()) return problem;
    state_.SelectSpace(selected);
    SelectionMoved();
    if (std::wstring problem = RunToRest(L"Back"); !problem.empty()) return problem;
    // A click on the current space's name renames it (and one on its icon's slot doesn't).
    if (const std::optional<POINT> nameAt = sidebar_->HeaderNameCentre()) {
        SendMouse(window_.Handle(), WM_LBUTTONDOWN, *nameAt, MK_LBUTTON);
        SendMouse(window_.Handle(), WM_LBUTTONUP, *nameAt, 0);
        if (sidebar_->Renaming() != selected) return L"a click on the space's name didn't rename it";
        SendMessageW(window_.Handle(), WM_KEYDOWN, VK_ESCAPE, 0);
    } else {
        return L"the header has no name to click";
    }

    // New Folder: a folder at the end of the pinned items (taken away again).
    const size_t pinned = state_.spaces[index].pinnedItems.size();
    RunSpaceMenuItem(selected, SpaceMenuItem::Command::NewFolder);
    if (state_.spaces[index].pinnedItems.size() != pinned + 1) return L"New Folder made no folder";
    state_.spaces[index].pinnedItems.pop_back();
    StateChanged();
    // Delete Space on a space with tabs asks first: Cancel keeps it, Delete deletes it and closes its pages.
    {
        const std::optional<std::string> full = NewSpace(state_, "With tabs");
        state_.OpenTab("about:blank", *full, false);
        state_.SelectSpace(selected);
        StateChanged();
        int asked = 0;
        askToDelete_ = [&](const SpaceDeletion& deletion) {
            ++asked;
            return deletion.kind == SpaceDeletion::Kind::Ask && asked == 2;
        };
        RunSpaceMenuItem(*full, SpaceMenuItem::Command::Delete);
        if (asked != 1 || !state_.SpaceIndex(*full)) return L"Delete Space's Cancel deleted the space";
        RunSpaceMenuItem(*full, SpaceMenuItem::Command::Delete);
        askToDelete_ = [](const SpaceDeletion&) { return false; };
        if (asked != 2 || state_.SpaceIndex(*full)) return L"Delete Space's Delete didn't delete the space";
        if (ids() != order) return L"Delete Space left the spaces in another order";
    }
    // Delete Space on a space with no tabs goes at once, and the one before it shows again.
    const std::optional<std::string> made = NewSpace(state_, "Smoke");
    if (!made) return L"New Space made no space";
    SelectionMoved();
    if (std::wstring problem = RunToRest(L"New Space"); !problem.empty()) return problem;
    RunSpaceMenuItem(*made, SpaceMenuItem::Command::Delete);
    if (state_.SpaceIndex(*made) || state_.selectedSpaceID != selected) return L"Delete Space didn't delete an empty space";
    if (ids() != order) return L"Delete Space left the spaces in another order";

    // A swipe whose neighbour goes under it (deleted from the menu mid-gesture) is dropped: the
    // pages and the theme settle back, and the rest of its gesture shows nothing.
    if (touchpad_) {
        using Phase = SwipeInput::Phase;
        using Step = SpaceSwipeGesture::Step;
        const std::optional<std::string> next = NewSpace(state_, "Under the swipe");
        state_.SelectSpace(selected);
        StateChanged();
        const POINT list{std::lround(120 * scale), std::lround(200 * scale)};
        double stamp = FrameClock::Now();
        const auto send = [&](Phase phase, double dx) { return SwipeInputArrived(SwipeInput{phase, dx, 0, stamp += 1.0 / 60}, list); };
        send(Phase::Began, 0);
        for (int i = 0; i < 3; ++i) send(Phase::Changed, -25);
        if (!swipe_.Swiping()) return L"a swipe towards a new neighbour didn't begin";
        RunSpaceMenuItem(*next, SpaceMenuItem::Command::Delete);
        if (send(Phase::Changed, -25) != Step::Move || swipe_.Swiping()) return L"a swipe whose neighbour was deleted wasn't dropped";
        if (send(Phase::Changed, -25) != Step::Swallow || send(Phase::Ended, 0) != Step::Swallow) {
            return L"the rest of a dropped swipe's gesture wasn't swallowed";
        }
        send(Phase::MomentumEnded, 0);
        if (std::wstring problem = RunToRest(L"A dropped swipe"); !problem.empty()) return problem;
        if (state_.selectedSpaceID != selected || ids() != order) return L"a dropped swipe moved the selection";
    }
    frames_.clear();
    return {};
}

}  // namespace kite

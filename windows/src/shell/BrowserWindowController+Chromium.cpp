// The window controller's Chromium wiring (the Mac's engine side of BrowserWindowController and
// its +*.swift extensions): the content card's bounds, the selected tab's page, the pages'
// reports, and Chromium's start and shutdown. See BrowserWindowController.h.

#include "shell/BrowserWindowController.h"

#ifdef KITE_HAS_CEF

#include <algorithm>
#include <utility>

#include "core/LiveTabPolicy.h"
#include "core/TitleBar.h"
#include "shell/Chromium.h"
#include "shell/Text.h"

namespace kite {

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
                // Asked before the close, so the answer comes ahead of the browsers' DoClose
                // and so before the window can go.
                chromium_->ReadEnergySaver([this](std::optional<int> state) {
                    energySaverRead_ = true;
                    energySaverState_ = state;
                });
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
    // Chromium's default would cap pages at 30 fps on a low battery (Chromium::SetEnergySaverEnabled).
    if (!energySaverRead_) return L"Chromium's Energy Saver preference was never read back";
    if (!energySaverState_) return L"Chromium has no Energy Saver preference to turn off";
    if (*energySaverState_ != 0) {
        return L"Chromium's Energy Saver is " + std::to_wstring(*energySaverState_) + L", not off (0)";
    }
    // One WM_CLOSE must close the window (the browsers first); the 30 s timer's second one
    // would otherwise hide a close that hangs.
    if (GetTickCount64() - closeAskedAt_ > 5'000) {
        return L"the window took " + std::to_wstring((GetTickCount64() - closeAskedAt_) / 1000) + L" s to close";
    }
    return {};
}


}  // namespace kite

#endif  // KITE_HAS_CEF

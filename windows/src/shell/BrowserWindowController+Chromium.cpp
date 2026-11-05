// The window controller's Chromium wiring (the Mac's engine side of BrowserWindowController and
// its +*.swift extensions): the selected tab's page, the pages' reports, and Chromium's start and
// shutdown. See BrowserWindowController.h. (The content card's bounds are in
// BrowserWindowController.cpp: the find bar needs them in a capture, which has no Chromium.)

#include "shell/BrowserWindowController.h"

#ifdef KITE_HAS_CEF

#include <algorithm>
#include <utility>

#include "core/ChromiumSwitches.h"
#include "core/LiveTabPolicy.h"
#include "core/TitleBar.h"
#include "shell/Chromium.h"
#include "shell/Sandbox.h"
#include "shell/Text.h"

namespace kite {

void BrowserWindowController::ShowSelectedTab() {
    // Before the page changes: the find bar closes and its search ends in the page it ran in.
    FindBarFollowsSelection();
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

Chromium::StartResult BrowserWindowController::StartChromium(const std::filesystem::path& root, void* sandboxInfo, std::wstring& error) {
    PageEvents events;
    // The Mac's mutatePage: a navigation saves as soon as a sidebar change, a title or favicon
    // later (SessionSaveDelay::PageEvent); a report that changes nothing saves nothing.
    events.addressChanged = [this](const std::string& id, const std::string& url) {
        RecordAddress(id, url);
        Tab* tab = TabNamed(id);
        const bool changed = tab && !url.empty() && tab->url != url;
        if (changed) tab->url = url;
        StateChanged(changed ? std::optional(SessionSaveDelay::Soon) : std::nullopt);
    };
    events.titleChanged = [this](const std::string& id, const std::string& title) {
        RecordTitle(id, title);
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
    events.loadingChanged = [this](const std::string& id, bool loading, bool canGoBack, bool canGoForward) {
        // The Mac's navigationState: the top row shows the selected tab's.
        pageStatus_[id] = PageStatus{loading, canGoBack, canGoForward};
        if (const Tab* tab = state_.SelectedTab(); tab && tab->id == id) ShowPageStatus();
        // A smoke test closes once the first page has loaded (or shown its error page).
        if (loading) {
            pageLoading_ = true;
        } else if (pageLoading_ && !pageLoaded_) {
            pageLoaded_ = true;
            // Find in the page first (its reports come as findResult); the window closes once
            // that and the rest are done.
            if (options_.smokeTest && smokeFind_ == SmokeFind::Idle) StartSmokeFind();
            CloseWhenSmokeTestIsDone();
        }
    };
    events.rendererStarted = [this](const std::string&, DWORD pid) {
        // The smoke test checks the first page's renderer is in Chromium's sandbox (W6b): the
        // pages Kite shows run sign-ins and password managers.
        if (!options_.smokeTest || rendererChecked_) return;
        rendererChecked_ = true;
        std::wstring error;
        if (const auto sandbox = InspectSandbox(pid, error)) {
            rendererProblem_ = RendererSandboxProblem(*sandbox);
            sandboxReport_ = L"Kite: the first page's renderer: " + Describe(*sandbox) + L"\n";
        } else {
            rendererProblem_ = L"couldn't read the renderer's token: " + error;
        }
        CloseWhenSmokeTestIsDone();
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
        pageStatus_.erase(id);
        const auto opener = popupOpeners_.extract(id);
        state_.PageClosedItself(id, opener ? std::optional<std::string>(opener.mapped()) : std::nullopt);
        std::erase_if(popupOpeners_, [&](const auto& entry) { return entry.second == id; });
        ForgetRecorded(id);
        SelectionMoved();
    };
    // A popup and its opener keep their pages while both tabs exist; a page closed for the
    // limit can't be anyone's opener or popup again (the Mac's PagePool.discard).
    events.keepAlive = [this](const std::string& id) { return IsLinkedToPopup(popupOpeners_, state_, id); };
    events.pageDiscarded = [this](const std::string& id) {
        // Its tab loads again, with no history, when it's next shown (BrowserStore.clearPage).
        pageStatus_.erase(id);
        if (const Tab* tab = state_.SelectedTab(); tab && tab->id == id) ShowPageStatus();
        std::erase_if(popupOpeners_, [&](const auto& entry) { return entry.first == id || entry.second == id; });
        // The Mac's clearPage: the page that loads again when the tab is next shown records its
        // address as a new visit.
        ForgetRecorded(id);
    };
    events.findResult = [this](const std::string& id, int count, int activeMatch, bool final) {
        if (findBar_ && findBar_->IsOpen() && id == findTabID_) {
            findBar_->ShowResult(FindResult{count > 0, count, activeMatch});
        }
        if (options_.smokeTest) SmokeTestFind(count, activeMatch, final);
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
        // Kite was launched again: this one comes forward instead (a quiet run stays behind;
        // the other launch, a test on the same profile, fails).
        if (options_.quiet) return;
        if (IsIconic(window_.Handle())) ShowWindow(window_.Handle(), SW_RESTORE);
        SetForegroundWindow(window_.Handle());
    };
    events.downloadUpdated = [this](const DownloadUpdate& update) { DownloadUpdated(update); };
    if (const auto started = Chromium::Start(instance_, window_.Handle(), root, sandboxInfo, std::move(events), options_.quiet,
                                             options_.chromiumSwitches, chromium_, error);
        started != Chromium::StartResult::Started) {
        return started;
    }
    // A verdict that came before Chromium did.
    chromium_->SetOccluded(occluded_);
    // Each profile's download folder and Ask, as each download starts (read once: nothing on
    // Windows changes them yet; Settings comes with W31a).
    chromium_->SetDownloadLocations(DownloadLocations(), options_.downloadFolder);
    if (options_.saveLog && options_.testAutomaticDownloads) chromium_->AllowAutomaticDownloads(*options_.testAutomaticDownloads);
    if (options_.saveLog) chromium_->LogParkedPages();
    window_.onWake = [this] { chromium_->RunPending(); };
    window_.onMinimize = [this] {
        sidebar_->HideTip();
        chromium_->Minimized();
    };
    window_.onMove = [this] {
        sidebar_->HideTip();
        chromium_->WindowMoved();
    };
    window_.mayClose = [this] { return MayQuit() && chromium_->MayCloseWindow(); };
    window_.onFocus = [this] {
        // A field of Kite's with the keyboard (the command bar's, a rename, the find bar's)
        // keeps it in Kite's window; otherwise it goes on to the page.
        if (KeyboardOwner() == KeyboardField::None) chromium_->Focus();
    };
    return Chromium::StartResult::Started;
}

// A smoke test closes once the first page has loaded (or shown its error page) and its
// renderer has been checked, whichever comes last (the renderer reports from its first script
// context, which a page loading has but may report after the load).
void BrowserWindowController::CloseWhenSmokeTestIsDone() {
    if (!options_.smokeTest || !pageLoaded_ || !rendererChecked_ || closeAskedAt_) return;
    // And find in the page (StartSmokeFind), once it has run.
    if (findBar_ && smokeFind_ != SmokeFind::Done) return;
    // Every helper by now (GPU, network, storage, renderers): none but the network service
    // may run at medium integrity.
    std::wstring error;
    const std::vector<Helper> helpers = Helpers(error);
    helperProblem_ = !error.empty()    ? L"couldn't read Kite's helpers: " + error
                     : helpers.empty() ? L"Kite found none of its helper processes"
                                       : HelperSandboxProblem(helpers);
    for (const Helper& helper : helpers) sandboxReport_ += L"Kite: helper " + helper.type + L": " + Describe(helper.sandbox) + L"\n";
    // Asked before the close, so the answer comes ahead of the browsers' DoClose and so before
    // the window can go.
    chromium_->ReadEnergySaver([this](std::optional<int> state) {
        energySaverRead_ = true;
        energySaverState_ = state;
    });
    chromium_->ReadFeatureLists([this](std::string enable, std::string disable) { featureLists_.emplace(std::move(enable), std::move(disable)); });
    closeAskedAt_ = GetTickCount64();
    PostMessageW(window_.Handle(), WM_CLOSE, 0, 0);
}

std::wstring BrowserWindowController::ShutDownChromium() {
    if (!chromium_) return {};
    // Every browser closed within the window's 5 s deadline and Chromium's shutdown wait,
    // rather than Chromium going down under one.
    const bool closedCleanly = chromium_->Shutdown();
    if (!options_.smokeTest) return {};
    if (!closedCleanly) return L"a browser didn't close in time; Chromium shut down under it";
    if (!pageLoaded_) return L"the first page didn't finish loading within 30 s";
    if (!rendererChecked_) return L"the first page's renderer never reported its process";
    if (!rendererProblem_.empty()) return L"the first page's renderer isn't sandboxed: " + rendererProblem_;
    if (!helperProblem_.empty()) return L"a helper isn't sandboxed: " + helperProblem_;
    if (!chromium_->PagesCanBeHidden()) return L"a page had no Chromium widget window to hide: background tabs would keep drawing";
    if (!smokeFindProblem_.empty()) return L"find in page: " + smokeFindProblem_;
    if (findBar_ && smokeFind_ != SmokeFind::Done) return L"find in page: the page's search never finished";
    // On, as in Chrome and on the Mac (Chromium::SetEnergySaverEnabled). That's Chromium's own
    // default too, so only a profile whose Local State has it off (CI's smoke writes 0 first)
    // shows that Kite set it.
    if (!energySaverRead_) return L"Chromium's Energy Saver preference was never read back";
    if (!energySaverState_) return L"Chromium has no Energy Saver preference to turn on";
    if (*energySaverState_ != 1) {
        return L"Chromium's Energy Saver is " + std::to_wstring(*energySaverState_) + L", not on (1)";
    }
    // Chromium's native occlusion tracker off unless --chromium-switches turned it on, merged
    // into CEF's own feature lists, and no feature both on and off (core/ChromiumSwitches.h).
    if (!featureLists_) return L"Chromium's feature lists were never read back";
    if (const std::string problem = chromium_switches::FeatureProblem(options_.chromiumSwitches, featureLists_->first, featureLists_->second);
        !problem.empty()) {
        return L"Chromium's features: " + Widen(problem) + L" (enable-features=" + Widen(featureLists_->first) + L", disable-features=" +
               Widen(featureLists_->second) + L")";
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

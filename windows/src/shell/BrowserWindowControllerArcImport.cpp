// Import from Arc in the window, the Windows side of core/ArcImportController.h, as KiteMac's
// ArcImportController.swift is the Mac's: the "importFromArc" command (also in the window's
// system menu, Alt+Space) reads Arc's folder on a worker thread, asks for Arc's folder with the
// system's folder picker when it can't, confirms what it found, imports into the session and
// saves it, then writes the shortcut changes and routes.
//
// Arc's own import screens aren't ported: the confirmation is a message box with the Mac's
// text, and its "Include unnamed spaces" checkbox is the box's Yes/No. Arc shuts down on
// 2026-12-22; delete this with core/ArcImport* some time after.

#include <shobjidl.h>

#include <atomic>
#include <chrono>
#include <future>
#include <set>

#include "core/ArcImportController.h"
#include "core/SupportDirectory.h"
#include "shell/BrowserWindowController.h"
#include "shell/Text.h"

namespace kite {

// What the worker read. It's written before the worker posts kArcReadMessage and read after
// ArcRead joins it, so it needs no lock. `cancel` asks the read to stop between files, and
// `finished` says when the worker has returned.
struct BrowserWindowController::ArcJob {
    std::optional<std::variant<arc_import::Plan, arc_import::LoadError>> result;
    bool picked = false;
    std::atomic<bool> cancel{false};
    std::promise<void> done;
    std::shared_future<void> finished = done.get_future().share();
};

namespace {

// Where to look: Arc for Windows' package folder (or KITE_ARC_DATA_PATH in a test run).
std::optional<std::filesystem::path> ArcFolder() {
    return arc_import::ArcDirectory(EnvironmentPath("KITE_SUPPORT_PATH"), EnvironmentPath("KITE_ARC_DATA_PATH"), EnvironmentPath("LOCALAPPDATA"));
}

// The system's folder picker, on Arc's folder when there is one (the Mac's open panel). None
// when it's cancelled.
std::optional<std::filesystem::path> PickArcFolder(HWND owner) {
    const HRESULT init = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    std::optional<std::filesystem::path> picked;
    IFileOpenDialog* dialog = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&dialog)))) {
        FILEOPENDIALOGOPTIONS options = 0;
        dialog->GetOptions(&options);
        dialog->SetOptions(options | FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST);
        dialog->SetTitle(L"Kite couldn't read Arc's data. Choose Arc's folder (LocalCache\\Local\\Arc in Arc's package).");
        dialog->SetOkButtonLabel(L"Import");
        if (auto folder = ArcFolder()) {
            IShellItem* item = nullptr;
            if (SUCCEEDED(SHCreateItemFromParsingName(folder->c_str(), nullptr, IID_PPV_ARGS(&item)))) {
                dialog->SetFolder(item);
                item->Release();
            }
        }
        if (SUCCEEDED(dialog->Show(owner))) {
            IShellItem* item = nullptr;
            if (SUCCEEDED(dialog->GetResult(&item))) {
                PWSTR path = nullptr;
                if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &path))) {
                    picked = std::filesystem::path(path);
                    CoTaskMemFree(path);
                }
                item->Release();
            }
        }
        dialog->Release();
    }
    if (SUCCEEDED(init)) CoUninitialize();
    return picked;
}

}  // namespace

void BrowserWindowController::ImportFromArc() {
    // Never a dialog in a test run; and reading Arc's files takes a moment, so a second press
    // meanwhile does nothing.
    if (options_.smokeTest || options_.capture || arcReading_ || closing_) return;
    if (!writer_ || !writer_->MaySave()) {
        // The session didn't read and is never saved: an import would be lost.
        MessageBoxW(window_.Handle(), L"Kite couldn't read its session, so it doesn't save it, and an import would be lost. Restart Kite and try again.",
                    L"Import from Arc", MB_OK | MB_ICONWARNING);
        return;
    }
    arcReading_ = true;
    ReadArc(std::nullopt);
}

void BrowserWindowController::ReadArc(std::optional<std::filesystem::path> picked) {
    if (arcThread_.joinable()) arcThread_.join();
    auto job = std::make_shared<ArcJob>();
    job->picked = picked.has_value();
    arcJob_ = job;
    const HWND window = window_.Handle();
    arcThread_ = std::thread([job, picked = std::move(picked), window] {
        const auto folder = ArcFolder();
        arc_import::ReadOptions options;
        options.cancel = &job->cancel;
        job->result = picked ? arc_import::ReadPicked(*picked, folder, options) : arc_import::ReadAuto(folder, options);
        if (!job->cancel) PostMessageW(window, kArcReadMessage, 0, 0);
        job->done.set_value();
    });
}

void BrowserWindowController::StopArcRead() {
    if (!arcThread_.joinable()) return;
    // The read checks `cancel` between Arc's files, so it ends within one file's parse. Waited
    // for, so it never runs on into the CRT's teardown of statics (Theme::Presets) after main.
    // Only a read still inside one huge file (up to kMaxArcFileBytes) outlasts the wait; that one
    // is let go, the one rare case left.
    if (arcJob_) arcJob_->cancel = true;
    if (!arcJob_ || arcJob_->finished.wait_for(std::chrono::seconds(5)) == std::future_status::ready) arcThread_.join();
    else arcThread_.detach();
}

void BrowserWindowController::ArcRead() {
    // The worker posted as its last step: joining it is quick, and makes its result ours.
    if (arcThread_.joinable()) arcThread_.join();
    std::shared_ptr<ArcJob> job = std::move(arcJob_);
    if (!job || !job->result) return;
    const HWND owner = window_.Handle();
    // A dialog's own message loop runs the window's messages too: when it returns, the window
    // may have begun closing (logoff), its session already saved. Nothing more then.
    auto stillOpen = [&] { return !closing_ && IsWindow(owner); };
    if (auto* error = std::get_if<arc_import::LoadError>(&*job->result)) {
        // Kite couldn't read Arc's data where it keeps it: ask for the folder.
        if (!job->picked && error->failure != arc_import::Failure::NoSpaces) {
            auto folder = PickArcFolder(owner);
            if (folder && stillOpen()) return ReadArc(std::move(*folder));
            arcReading_ = false;
            return;
        }
        arcReading_ = false;
        MessageBoxW(owner, Widen(error->detail).c_str(), Widen(error->message).c_str(), MB_OK | MB_ICONWARNING);
        return;
    }
    const arc_import::Plan& plan = std::get<arc_import::Plan>(*job->result);
    const bool includeByDefault = arc_import::IncludesUntitled(plan, {});
    std::string text;
    for (const std::string& line : arc_import::ConfirmLines(plan, state_, includeByDefault)) text += (text.empty() ? "" : "\n\n") + line;
    const auto [untitledSpaces, untitledTabs] = arc_import::UntitledCounts(plan);
    UINT buttons = MB_OKCANCEL;
    if (untitledSpaces > 0) {
        // The Mac's "Include N unnamed spaces (M tabs)" checkbox, off unless asked; on when Arc
        // has no named space, as they're all there is (Kite for Windows' own choice).
        const std::string spaces = std::to_string(untitledSpaces) + " unnamed space" + (untitledSpaces == 1 ? "" : "s");
        const std::string tabs = std::to_string(untitledTabs) + " tab" + (untitledTabs == 1 ? "" : "s");
        text += "\n\nInclude the " + spaces + " (" + tabs + ")? Yes brings them, No leaves them out. " +
                (includeByDefault ? "Arc has no named space, so they're all of your sidebar." : "Arc often keeps spaces nobody set up.");
        buttons = MB_YESNOCANCEL | (includeByDefault ? MB_DEFBUTTON1 : MB_DEFBUTTON2);
    }
    const int answer = MessageBoxW(owner, Widen(text).c_str(), L"Import from Arc", buttons | MB_ICONQUESTION);
    arcReading_ = false;
    if (answer == IDCANCEL || !stillOpen()) return;

    std::set<std::string> before;
    for (const Space& space : state_.spaces) {
        for (const Tab* tab : space.AllTabs()) before.insert(tab->id);
    }
    arc_import::ImportOptions options;
    if (untitledSpaces > 0) options.includeUntitled = answer == IDYES;
    arc_import::Imported imported = arc_import::Import(state_, plan, options);
    // The session first, so the shortcut changes and routes never come without the spaces: it
    // goes to the writer at once, and this waits for that write (a moment, at most
    // kArcImportFlush), the one wait on the disk here, after the user's answer.
    SaveNow();
    if (std::string error = writer_->Flush(kArcImportFlush); !error.empty()) {
        MessageBoxW(owner, (L"The spaces are in this window, but Kite couldn't save them yet: " + Widen(error) +
                            L"\n\nKite tries again when the window closes. The shortcut changes and routes weren't written.")
                               .c_str(),
                    L"Import from Arc", MB_OK | MB_ICONWARNING);
    } else {
        arc_import::WriteProfileFiles(imported, options_.supportDirectory);
    }
    if (!stillOpen()) return;
    OutputDebugStringW((L"Kite: Arc import: " + Widen(json::Write(arc_import::Summary(imported))) + L"\n").c_str());
    // A space imported again replaces its old self: pages of tabs it no longer has go.
    for (const std::string& id : before) {
        if (!state_.FindTabByID(id)) PageGone(id);
    }
    SelectionMoved();
}

}  // namespace kite

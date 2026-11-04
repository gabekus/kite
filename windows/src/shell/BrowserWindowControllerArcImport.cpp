// Import from Arc in the window, the Windows side of core/ArcImportController.h, as KiteMac's
// ArcImportController.swift is the Mac's: the "importFromArc" command (also in the window's
// system menu, Alt+Space) reads Arc's folder on a worker thread, asks for Arc's folder with the
// system's folder picker when it can't, confirms what it found, and imports into the session.
//
// Arc's own import screens aren't ported: the confirmation is a message box with the Mac's
// text, and its "Include unnamed spaces" checkbox is the box's Yes/No. Arc shuts down on
// 2026-12-22; delete this with core/ArcImport* some time after.

#include <shobjidl.h>

#include <mutex>
#include <set>

#include "core/ArcImportController.h"
#include "core/SupportDirectory.h"
#include "shell/BrowserWindowController.h"
#include "shell/Text.h"

namespace kite {

struct BrowserWindowController::ArcJob {
    std::mutex mutex;
    std::optional<std::variant<arc_import::Plan, arc_import::LoadError>> result;
    bool picked = false;
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
    if (options_.smokeTest || options_.capture || arcReading_) return;
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
        auto result = picked ? arc_import::ReadPicked(*picked, folder) : arc_import::ReadAuto(folder);
        {
            std::lock_guard lock(job->mutex);
            job->result = std::move(result);
        }
        PostMessageW(window, kArcReadMessage, 0, 0);
    });
}

void BrowserWindowController::ArcRead() {
    if (!arcJob_) return;
    std::optional<std::variant<arc_import::Plan, arc_import::LoadError>> result;
    bool picked = false;
    {
        std::lock_guard lock(arcJob_->mutex);
        result = std::move(arcJob_->result);
        picked = arcJob_->picked;
    }
    if (!result) return;
    arcJob_.reset();
    const HWND owner = window_.Handle();
    if (auto* error = std::get_if<arc_import::LoadError>(&*result)) {
        // Kite couldn't read Arc's data where it keeps it: ask for the folder.
        if (!picked && error->failure != arc_import::Failure::NoSpaces) {
            if (auto folder = PickArcFolder(owner)) return ReadArc(std::move(*folder));
            arcReading_ = false;
            return;
        }
        arcReading_ = false;
        MessageBoxW(owner, Widen(error->detail).c_str(), Widen(error->message).c_str(), MB_OK | MB_ICONWARNING);
        return;
    }
    const arc_import::Plan& plan = std::get<arc_import::Plan>(*result);
    std::string text;
    for (const std::string& line : arc_import::ConfirmLines(plan, state_)) text += (text.empty() ? "" : "\n\n") + line;
    const auto [untitledSpaces, untitledTabs] = arc_import::UntitledCounts(plan);
    UINT buttons = MB_OKCANCEL;
    if (untitledSpaces > 0) {
        // The Mac's "Include N unnamed spaces (M tabs)" checkbox, off unless asked.
        text += "\n\nInclude " + std::to_string(untitledSpaces) + " unnamed space" + (untitledSpaces == 1 ? "" : "s") + " (" +
                std::to_string(untitledTabs) + " tab" + (untitledTabs == 1 ? "" : "s") +
                ")? Yes brings them too, No leaves them out. Arc often keeps spaces nobody set up.";
        buttons = MB_YESNOCANCEL | MB_DEFBUTTON2;
    }
    const int answer = MessageBoxW(owner, Widen(text).c_str(), L"Import from Arc", buttons | MB_ICONQUESTION);
    arcReading_ = false;
    if (answer == IDCANCEL) return;

    std::set<std::string> before;
    for (const Space& space : state_.spaces) {
        for (const Tab* tab : space.AllTabs()) before.insert(tab->id);
    }
    const json::Value summary = arc_import::Import(state_, plan, options_.supportDirectory, {.includeUntitled = answer == IDYES});
    OutputDebugStringW((L"Kite: Arc import: " + Widen(json::Write(summary)) + L"\n").c_str());
    // A space imported again replaces its old self: pages of tabs it no longer has go.
    for (const std::string& id : before) {
        if (!state_.FindTabByID(id)) PageGone(id);
    }
    SelectionMoved();
}

}  // namespace kite

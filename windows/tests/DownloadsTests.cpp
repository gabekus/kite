// The download engine's model (W20a): ports of KiteCore's DownloadsTests, ProfileSettingsTests,
// ExtensionsTests.detectsExtensionPackages and WindowPresentationTests' skipped modals, each
// named after the Swift test it comes from, then the shared fixture (DownloadsFixtureTests) and
// what the Mac doesn't test: its DownloadsModel's rules, the background writer, and the
// download's path.

#include <filesystem>
#include <fstream>
#include <iterator>
#include <set>
#include <thread>
#include <atomic>

#ifdef _WIN32
#include <windows.h>
#include <share.h>
#include <stdio.h>
#endif

#include "Check.h"
#include "core/Downloads.h"
#include "core/DownloadsModel.h"
#include "core/DownloadsWriter.h"
#include "core/Models.h"
#include "core/ProfileSettings.h"
#include "core/SkippedModal.h"
#include "core/StoreFile.h"
#include "core/Unicode.h"
#include "core/Uuid.h"

using namespace kite;
namespace fs = std::filesystem;
using S = DownloadState;

namespace {

// DownloadsTests.update(_:_:received:total:path:).
DownloadUpdate Update(int64_t id, S state = S::InProgress, int64_t received = 0, int64_t total = 100,
                      std::string path = "/Users/me/Downloads/report.pdf") {
    DownloadUpdate update;
    update.engineID = id;
    update.url = "https://www.example.com/report.pdf";
    update.path = std::move(path);
    update.state = state;
    update.receivedBytes = received;
    update.totalBytes = total;
    update.speed = 50;
    return update;
}

DownloadUpdate Report(int64_t id, std::string context, bool incognito, std::string url, std::string path, S state, int64_t received,
                      int64_t total) {
    DownloadUpdate update;
    update.engineID = id;
    update.engineContext = std::move(context);
    update.isIncognito = incognito;
    update.url = std::move(url);
    update.path = std::move(path);
    update.state = state;
    update.receivedBytes = received;
    update.totalBytes = total;
    return update;
}

fs::path TempDir() {
    fs::path dir = fs::temp_directory_path() / ("kite-downloads-" + NewUuid());
    fs::create_directories(dir);
    return dir;
}

struct TempFolder {
    fs::path dir = TempDir();
    ~TempFolder() {
        std::error_code ignored;
        fs::remove_all(dir, ignored);
    }
};

void WriteText(const fs::path& path, const std::string& text) { std::ofstream(path, std::ios::binary | std::ios::trunc) << text; }
std::string ReadText(const fs::path& path) { return store_file::Read(path).value_or(""); }

std::string Name(const fs::path& path) {
    auto u8 = path.filename().u8string();
    return std::string(u8.begin(), u8.end());
}

std::vector<S> States(const DownloadList& list) {
    std::vector<S> out;
    for (const auto& item : list.Items()) out.push_back(item.state);
    return out;
}

std::vector<std::optional<int64_t>> EngineIDs(const DownloadList& list) {
    std::vector<std::optional<int64_t>> out;
    for (const auto& item : list.Items()) out.push_back(item.engineID);
    return out;
}

DownloadList RoundTrip(const DownloadList& list) { return DecodeDownloadList(Encode(list)).value_or(DownloadList()); }

// A profile in `profiles`, as Profiles.swift's createProfile(named:) makes one.
std::string AddProfile(BrowserState& state, const std::string& name) {
    json::Array profiles;
    if (auto it = state.extra.find("profiles"); it != state.extra.end() && it->second.AsArray()) profiles = *it->second.AsArray();
    const std::string directory = "Profile " + std::to_string(profiles.size() + 1);
    profiles.push_back(json::Object{{"directory", directory}, {"name", name}, {"dataStoreID", NewUuid()}});
    state.extra["profiles"] = json::Value(std::move(profiles));
    return directory;
}

}  // namespace

// MARK: DownloadsTests

TEST(updatesOneEntryPerDownloadNewestFirst) {
    DownloadList list;
    CHECK(list.Apply(Update(1)).isNew);
    CHECK(!list.Apply(Update(1, S::InProgress, 40)).isNew);
    list.Apply(Update(2));
    CHECK((EngineIDs(list) == std::vector<std::optional<int64_t>>{2, 1}));
    CHECK(list.Items()[1].receivedBytes == 40);
    CHECK(list.Items()[1].Fraction() == 0.4);
}

TEST(keepsTheKnownPathWhenAnUpdateHasNone) {
    DownloadList list;
    list.Apply(Update(1));
    list.Apply(Update(1, S::InProgress, 0, 100, ""));
    CHECK(list.Items()[0].FileName() == "report.pdf");
}

TEST(finishedDownloadsStopReportingSpeed) {
    DownloadList list;
    list.Apply(Update(1, S::InProgress, 10));
    CHECK(list.Items()[0].speed == 50);
    list.Apply(Update(1, S::Complete, 100));
    CHECK(list.Items()[0].speed == 0);
    CHECK(list.Active().empty());
}

TEST(restoredDownloadsAreNoLongerLive) {
    DownloadList list;
    list.Apply(Update(1, S::InProgress, 10));
    list.Apply(Update(2, S::Complete, 100));
    DownloadList restored = RoundTrip(list);
    restored.MarkRestored();
    bool noneLive = true;
    for (const auto& item : restored.Items()) noneLive = noneLive && !item.engineID;
    CHECK(noneLive);
    CHECK((States(restored) == std::vector<S>{S::Complete, S::Interrupted}));
    // A new launch's id 1 is a new download, not the old one.
    CHECK(restored.Apply(Update(1)).isNew);
}

TEST(idsAreKeyedByBrowserContext) {
    DownloadList list;
    list.Apply(Report(1, "", false, "https://a/x", "/d/x", S::Complete, 5, 5));
    // Another profile's and an incognito window's first downloads are new rows, not the first one finishing again.
    CHECK(list.Apply(Report(1, "Profile 1", false, "https://b/y", "/d/y", S::InProgress, 0, 9)).isNew);
    CHECK(list.Apply(Report(1, "incognito-1", true, "https://c/z", "/d/z", S::InProgress, 0, 9)).isNew);
    list.Apply(Report(1, "Profile 1", false, "https://b/y", "/d/y", S::InProgress, 4, 9));
    CHECK(list.Items().size() == 3);
    CHECK(list.Item(1, "") && list.Item(1, "")->state == S::Complete);
    CHECK(list.Item(1, "Profile 1") && list.Item(1, "Profile 1")->receivedBytes == 4);
    CHECK(list.Item(1, "incognito-1") && list.Item(1, "incognito-1")->isIncognito);
    CHECK(!list.Item(1, "Profile 2"));
}

TEST(incognitoDownloadsAreNeverSaved) {
    DownloadList list;
    list.Apply(Update(1, S::Complete));
    list.Apply(Report(1, "incognito-1", true, "https://secret/a", "/d/secret.pdf", S::Complete, 1, 1));
    CHECK(list.Items().size() == 2);
    const std::string data = downloads_file::Encode(list);
    CHECK(data.find("secret") == std::string::npos);
    auto restored = downloads_file::Decode(data);
    CHECK(restored && restored->Items().size() == 1);
    CHECK(restored && !restored->Items()[0].isIncognito);
}

TEST(readsFilesFromBeforeContexts) {
    // downloads.json as Kite wrote it before engineContext and isIncognito.
    const std::string json = R"({"version":1,"downloads":{"items":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","engineID":3,
        "url":"https://a/x","path":"/d/x","state":"complete","receivedBytes":5,"totalBytes":5,"speed":0,
        "startedAt":700000000}]}})";
    auto file = downloads_file::Decode(json);
    CHECK(file && file->Items().size() == 1);
    CHECK(file && !file->Items()[0].isIncognito);
    CHECK(file && !file->Items()[0].engineContext);
}

TEST(anUnreadableFileIsMovedAsideNotOverwritten) {
    TempFolder folder;
    const fs::path file = folder.dir / "downloads.json";

    // No file: an empty list, nothing moved.
    auto empty = downloads_file::Load(file);
    CHECK(empty && empty->list.Items().empty() && !empty->movedAside);

    // A good file restores, with nothing live.
    DownloadList list;
    list.Apply(Update(1, S::InProgress, 10));
    WriteText(file, downloads_file::Encode(list));
    auto good = downloads_file::Load(file);
    CHECK(good && (States(good->list) == std::vector<S>{S::Interrupted}));
    CHECK(good && !good->movedAside);

    // A damaged one is kept beside it, and the path is free for the next save.
    WriteText(file, "{\"version\":1,\"downl");
    auto bad = downloads_file::Load(file);
    CHECK(bad && bad->list.Items().empty());
    CHECK(bad && bad->movedAside);
    CHECK(!fs::exists(file));
    if (bad && bad->movedAside) CHECK(ReadText(*bad->movedAside) == "{\"version\":1,\"downl");
}

TEST(oneBadItemIsDroppedNotTheList) {
    const std::string json = R"({"version":1,"downloads":{"items":[{"id":"not-a-uuid","url":"https://a/x"},
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"https://a/y","path":"/d/y","state":"complete",
        "receivedBytes":5,"totalBytes":5,"startedAt":700000000}]}})";
    auto file = downloads_file::Decode(json);
    CHECK(file && file->Items().size() == 1 && file->Items()[0].FileName() == "y");
}

TEST(aFileWithAnUnreadableItemIsCopiedAsideBeforeTheNextSave) {
    TempFolder folder;
    const fs::path file = folder.dir / "downloads.json";
    const std::string original = R"({"version":1,"downloads":{"items":[{"id":"not-a-uuid","url":"https://a/x","newField":1},
        {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"https://a/y","path":"/d/y","state":"complete",
        "receivedBytes":5,"totalBytes":5,"startedAt":700000000}]}})";
    WriteText(file, original);
    auto loaded = downloads_file::Load(file);
    CHECK(loaded && loaded->list.Items().size() == 1);
    CHECK(loaded && loaded->dropped == 1);
    CHECK(loaded && loaded->canSave);
    CHECK(loaded && loaded->copiedAside);
    if (loaded && loaded->copiedAside) {
        CHECK(Name(*loaded->copiedAside).starts_with("downloads.corrupt-"));
        CHECK(ReadText(*loaded->copiedAside) == original);
    }
    CHECK(ReadText(file) == original);
    // A clean file is left alone.
    if (loaded) WriteText(file, downloads_file::Encode(loaded->list));
    auto clean = downloads_file::Load(file);
    CHECK(clean && clean->dropped == 0 && !clean->copiedAside);
}

TEST(closingAnIncognitoWindowDropsOnlyItsDownloads) {
    DownloadList list;
    list.Apply(Update(1, S::Complete));
    for (const char* context : {"incognito-1", "incognito-2"}) {
        list.Apply(Report(1, context, true, "https://a/x", "/d/x", S::Complete, 1, 1));
    }
    list.RemoveIncognito("incognito-1");
    std::vector<std::string> contexts;
    for (const auto& item : list.Items()) contexts.push_back(item.engineContext.value_or("nil"));
    CHECK((contexts == std::vector<std::string>{"incognito-2", ""}));
}

TEST(readsTheBridgesNotification) {
    const json::Value info(json::Object{{"id", 3},           {"context", "Profile 1"}, {"incognito", false},
                                        {"profileDirectory", "Profile 1"}, {"url", "https://a/x"}, {"path", "/d/x"},
                                        {"state", "in-progress"}, {"receivedBytes", 10}, {"totalBytes", 20}, {"speed", 5}});
    auto update = DownloadUpdate::FromInfo(info);
    DownloadUpdate expected = Report(3, "Profile 1", false, "https://a/x", "/d/x", S::InProgress, 10, 20);
    expected.profileDirectory = "Profile 1";
    expected.speed = 5;
    CHECK(update && *update == expected);
    CHECK(update && DownloadUpdate::NameOf(update->state) == "in-progress");
    auto incognito = DownloadUpdate::FromInfo(json::Value(json::Object{{"id", 1}, {"context", "incognito-2"}, {"incognito", true}}));
    CHECK(incognito && incognito->isIncognito && !incognito->profileDirectory && incognito->totalBytes == -1);
    CHECK(!DownloadUpdate::FromInfo(json::Value(json::Object{{"url", "https://a/x"}})));
    // And back: what kitecore prints is what it reads.
    CHECK(update && DownloadUpdate::FromInfo(update->Info()) == update);
}

TEST(activeFractionCombinesBytes) {
    DownloadList list;
    list.Apply(Update(1, S::InProgress, 50, 100));
    list.Apply(Update(2, S::InProgress, 0, 300));
    list.Apply(Update(3, S::InProgress, 10, -1));
    CHECK(list.ActiveFraction() == 0.125);
}

TEST(clearingKeepsLiveDownloads) {
    DownloadList list;
    list.Apply(Update(1));
    list.Apply(Update(2, S::Complete));
    list.Apply(Update(3, S::Canceled));
    list.ClearFinished();
    CHECK((EngineIDs(list) == std::vector<std::optional<int64_t>>{1}));
}

TEST(oldFinishedDownloadsFallOff) {
    DownloadList list;
    list.Apply(Update(0));
    for (int64_t id = 1; id <= static_cast<int64_t>(DownloadList::kLimit) + 5; ++id) list.Apply(Update(id, S::Complete));
    CHECK(list.Items().size() == DownloadList::kLimit);
    // The live one survives even though it's the oldest.
    CHECK(list.Items().back().engineID == 0);
}

TEST(subtitles) {
    DownloadList list;
    list.Apply(Update(1, S::InProgress, 1'000'000, 4'000'000));
    CHECK(download_text::Subtitle(list.Items()[0]).find(" of ") != std::string::npos);
    list.Apply(Update(1, S::Complete, 4'000'000, 4'000'000));
    const std::string done = download_text::Subtitle(list.Items()[0]);
    CHECK(done.starts_with("PDF \xC2\xB7 "));
    CHECK(done.ends_with(" from example.com"));
    list.Apply(Update(1, S::Interrupted));
    CHECK(download_text::Subtitle(list.Items()[0]) == "Failed to Download");
    CHECK(download_text::Kind("Kite.dmg") == "Disk Image");
    CHECK(download_text::Kind("a.zip") == "ZIP Archive");
}

TEST(stateNamesFromChromium) {
    CHECK(DownloadUpdate::StateNamed("complete") == S::Complete);
    CHECK(DownloadUpdate::StateNamed("canceled") == S::Canceled);
    CHECK(DownloadUpdate::StateNamed("interrupted") == S::Interrupted);
    CHECK(DownloadUpdate::StateNamed("in-progress") == S::InProgress);
}

// MARK: BrowsingDataTests' download history (DownloadList.removeHistory)

TEST(removeHistoryKeepsLiveDownloadsAndOlderOnes) {
    DownloadList list;
    list.Apply(Update(1, S::Complete), 100);
    list.Apply(Update(2, S::Complete), 200);
    list.Apply(Update(3, S::InProgress), 300);
    list.RemoveHistory(150);
    CHECK((EngineIDs(list) == std::vector<std::optional<int64_t>>{3, 1}));
    list.RemoveHistory(std::nullopt);
    CHECK((EngineIDs(list) == std::vector<std::optional<int64_t>>{3}));
}

// MARK: ProfileSettingsTests

TEST(defaultsMatchArc) {
    const BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const ProfileSettings settings = state.Settings(std::string(BrowserState::kDefaultProfile));
    CHECK(!settings.downloadDirectory);
    CHECK(!settings.promptsForDownload);
    CHECK(settings.includesSearchSuggestions);
}

TEST(eachProfileKeepsItsOwn) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    const std::string work = AddProfile(state, "Work");
    state.UpdateSettings(work, [](ProfileSettings& s) {
        s.downloadDirectory = "/tmp/work";
        s.includesSearchSuggestions = false;
    });
    state.UpdateSettings(std::nullopt, [](ProfileSettings& s) { s.promptsForDownload = true; });

    CHECK(state.Settings(work).downloadDirectory == "/tmp/work");
    CHECK(!state.Settings(work).includesSearchSuggestions);
    CHECK(!state.Settings(work).promptsForDownload);
    // None (incognito) is the default profile's.
    CHECK(state.Settings(std::string(BrowserState::kDefaultProfile)).promptsForDownload);
    CHECK(state.Settings(std::string(BrowserState::kDefaultProfile)).includesSearchSuggestions);
}

TEST(survivesSaveAndLoad) {
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    state.UpdateSettings(std::nullopt, [](ProfileSettings& s) {
        s.downloadDirectory = "/tmp/a";
        s.includesSearchSuggestions = false;
    });
    auto loaded = DecodeBrowserState(Encode(state));
    CHECK(loaded && loaded->Settings(std::nullopt) == state.Settings(std::nullopt));
    // Back to the defaults leaves nothing stored.
    state.UpdateSettings(std::nullopt, [](ProfileSettings& s) { s = ProfileSettings(); });
    CHECK(state.profileSettings.empty());
}

TEST(missingFolderFallsBackToDownloads) {
    const fs::path downloads = "/Users/x/Downloads";
    ProfileSettings settings;
    CHECK(settings.DownloadFolder(downloads, [](const std::string&) { return true; }) == downloads);
    settings.downloadDirectory = "/Volumes/Gone";
    CHECK(settings.DownloadFolder(downloads, [](const std::string&) { return false; }) == downloads);
    CHECK(settings.DownloadFolder(downloads, [](const std::string&) { return true; }) == fs::path("/Volumes/Gone"));
}

// MARK: ExtensionsTests, WindowPresentationTests

TEST(detectsExtensionPackages) {
    const std::string blob = "https://clients2.googleusercontent.com/crx/blobs/abc/EXT_1_0.crx";
    // The Mac takes the MIME type from anywhere (url: nil); Windows wants the store's host for it too.
    CHECK(IsExtensionPackage("application/x-chrome-extension", "a.crx", "https://clients2.google.com/service/update2/crx"));
    CHECK(!IsExtensionPackage("application/x-chrome-extension", "a.crx", ""));
    CHECK(!IsExtensionPackage("application/x-chrome-extension", "notes.txt", "https://evil.example/notes.txt"));
    CHECK(!IsExtensionPackage("application/x-chrome-extension", "a.crx", "http://clients2.google.com/a.crx"));
    CHECK(!IsExtensionPackage("application/x-chrome-extension", "a.crx", "https://clients2.google.com.evil.example/a.crx"));
    CHECK(IsExtensionPackage("application/octet-stream", "EXT_1_0.crx", blob));
    CHECK(IsExtensionPackage("", "x.CRX", "https://r1---sn-abc.gvt1.com/edgedl/x.crx"));
    CHECK(!IsExtensionPackage("application/octet-stream", "x.crx", "https://example.com/x.crx"));
    CHECK(!IsExtensionPackage("application/pdf", "paper.pdf", blob));
}

TEST(skippedModalsAnswerAsDismissedExceptDownloadsInProgressWhichQuits) {
    CHECK(!Proceeds(SkippedModal::Alert));
    CHECK(!Proceeds(SkippedModal::OpenOrSavePanel));
    CHECK(!Proceeds(SkippedModal::QuitConfirmation));
    CHECK(Proceeds(SkippedModal::DownloadsInProgress));
}

// MARK: DownloadsFixtureTests: Tests/Fixtures/downloads-v1.json, which the Mac also loads

TEST(decodesTheSharedDownloadsFixture) {
    auto file = downloads_file::Decode(ReadText(fs::path(KITE_FIXTURES_DIR) / "downloads-v1.json"));
    CHECK(file && file->Items().size() == 4);
    if (!file || file->Items().size() != 4) return;
    const auto& items = file->Items();
    CHECK((States(*file) == std::vector<S>{S::InProgress, S::Complete, S::Canceled, S::Interrupted}));
    CHECK(items[0].engineID == 7 && items[0].engineContext == "Profile 1");
    CHECK(items[0].path == R"(C:\Users\me\Downloads\Kite Setup.exe)" && items[0].FileName() == "Kite Setup.exe");
    CHECK(items[0].Fraction() == 0.375 && items[0].speed == 250000 && items[0].startedAt == 783900000.5);
    CHECK(items[1].FileName() == "report.pdf" && items[1].SourceHost() == "example.com" && items[1].startedAt == 783800000);
    CHECK(items[2].FileName() == "big.zip" && !items[2].Fraction());
    CHECK(!items[3].isIncognito && items[3].speed == 0 && !items[3].engineID);
    DownloadList restored = *file;
    restored.MarkRestored();
    CHECK((States(restored) == std::vector<S>{S::Interrupted, S::Complete, S::Canceled, S::Interrupted}));
    // Round trip: what Windows writes reads back the same.
    CHECK(downloads_file::Decode(downloads_file::Encode(*file)) == file);
}

// MARK: Edge cases the Mac doesn't test

TEST(itemsKeepTheMacsJsonShape) {
    DownloadList list;
    list.Apply(Update(4, S::InProgress, 1, 2), 700);
    const json::Value item = Encode(list).Find("items")->AsArray()->front();
    // Live: the engine's id and context are written, as the Mac's encoder writes them.
    CHECK(item.Find("engineID") && item.Find("engineID")->AsInt() == 4);
    CHECK(item.Find("engineContext") && *item.Find("engineContext")->AsString() == "");
    CHECK(*item.Find("state")->AsString() == "inProgress" && item.Find("startedAt")->AsNumber() == 700);
    list.MarkRestored();
    const json::Value restored = Encode(list).Find("items")->AsArray()->front();
    CHECK(!restored.Find("engineID") && !restored.Find("engineContext"));
    // Lowercase ids read as Foundation reads them, uppercased.
    auto lower = DecodeDownloadItem(json::Value(json::Object{{"id", "6f9619ff-8b86-d011-b42d-00c04fc964ff"}, {"url", "u"}, {"path", ""},
                                                             {"state", "complete"}, {"receivedBytes", 1}, {"totalBytes", 1},
                                                             {"startedAt", 1}}));
    CHECK(lower && lower->id == "6F9619FF-8B86-D011-B42D-00C04FC964FF");
    // A fraction of a byte, an unknown state or a string id is an item Swift can't read.
    for (const auto& [key, value] : std::vector<std::pair<std::string, json::Value>>{
             {"receivedBytes", 1.5}, {"state", "paused"}, {"engineID", "1"}, {"isIncognito", 1}}) {
        json::Object o{{"id", NewUuid()}, {"url", "u"}, {"path", ""}, {"state", "complete"},
                       {"receivedBytes", 1}, {"totalBytes", 1}, {"startedAt", 1}};
        o[key] = value;
        CHECK(!DecodeDownloadItem(json::Value(std::move(o))));
    }
    // A file without a version, or whose items aren't a list, isn't a downloads file.
    CHECK(!downloads_file::Decode(R"({"downloads":{"items":[]}})"));
    CHECK(!downloads_file::Decode(R"({"version":1,"downloads":{"items":{}}})"));
    CHECK(downloads_file::Decode(R"({"version":1,"downloads":{}})") == DownloadList());
}

TEST(fileNamesFromWindowsPathsAndURLs) {
    DownloadItem item;
    item.path = R"(C:\Users\me\Downloads\notes.txt)";
    CHECK(item.FileName() == "notes.txt");
    item.path.clear();
    item.url = "https://example.com/files/Kite%20Setup.exe?token=1#x";
    CHECK(item.FileName() == "Kite Setup.exe");
    item.url = "https://example.com/files/";
    CHECK(item.FileName() == "files");
    item.url = "https://example.com/bad%FF";
    CHECK(item.FileName() == "bad%FF");  // not UTF-8 once decoded: left as written
    item.url = "https://www.example.com/x";
    CHECK(item.SourceHost() == "example.com");
    item.url = "data:text/plain,hi";
    CHECK(!item.SourceHost());
}

TEST(sizesReadAsByteCountFormattersFileStyle) {
    CHECK(download_text::Size(0) == "Zero KB");
    CHECK(download_text::Size(-5) == "Zero KB");
    CHECK(download_text::Size(1) == "1 byte");
    CHECK(download_text::Size(999) == "999 bytes");
    CHECK(download_text::Size(1000) == "1 KB");
    CHECK(download_text::Size(1500) == "2 KB");
    CHECK(download_text::Size(999'950) == "1 MB");
    CHECK(download_text::Size(1'500'000) == "1.5 MB");
    CHECK(download_text::Size(4'000'000) == "4 MB");
    CHECK(download_text::Size(1'250'000'000) == "1.25 GB");
    CHECK(download_text::Size(3'000'000'000) == "3 GB");
    DownloadItem item;
    item.receivedBytes = 1'000'000;
    item.totalBytes = -1;
    item.speed = 2'000'000;
    CHECK(download_text::Subtitle(item) == "1 MB \xC2\xB7 2 MB/s");
    item.state = S::Canceled;
    CHECK(download_text::Subtitle(item) == "Canceled");
    CHECK(download_text::Kind("archive.tar.gz") == "Archive" && download_text::Kind("PHOTO.JPG") == "Image" &&
          download_text::Kind(".mov") == "File" && download_text::Kind("README") == "File");
}

TEST(uniqueNamesNumberTheCopiesAsTheMacDoes) {
    const fs::path folder = "D:/Downloads";
    std::set<fs::path> used{folder / "report.pdf", folder / "report 2.pdf", folder / "notes"};
    const auto taken = [&](const fs::path& path) { return used.contains(path); };
    CHECK(UniqueDownloadPath("report.pdf", folder, taken) == folder / "report 3.pdf");
    CHECK(UniqueDownloadPath("notes", folder, taken) == folder / "notes 2");
    CHECK(UniqueDownloadPath("archive.tar.gz", folder, taken) == folder / "archive.tar.gz");
    used.insert(folder / "archive.tar.gz");
    CHECK(UniqueDownloadPath("archive.tar.gz", folder, taken) == folder / "archive.tar 2.gz");
    // A name never takes the download out of its folder.
    CHECK(UniqueDownloadPath(R"(..\..\evil.exe)", folder, taken) == folder / "evil.exe");
    CHECK(UniqueDownloadPath("../x/", folder, taken) == folder / "x");
    CHECK(UniqueDownloadPath("..", folder, taken) == folder / "download");
    CHECK(UniqueDownloadPath("", folder, taken) == folder / "download");
    // UTF-8 names stay whole.
    CHECK(UniqueDownloadPath("\xE6\x97\xA5\xE6\x9C\xAC.txt", folder, taken)->filename().u8string() == u8"\u65E5\u672C.txt");
    // Bounded: a folder where every name is taken (or a check that always fails) gives up.
    CHECK(!UniqueDownloadPath("x.bin", folder, [](const fs::path&) { return true; }));
    int asked = 0;
    CHECK(!UniqueDownloadPath("x.bin", folder, [&](const fs::path&) { return ++asked > 0; }) && asked == kUniqueNameTries);
}

TEST(downloadNamesAreSafeOnWindows) {
    // A drive-relative name, an alternate data stream and the characters Windows refuses.
    CHECK(SafeDownloadName("C:evil.exe") == "evil.exe");
    CHECK(SafeDownloadName("report.pdf:Zone.Identifier") == "report.pdf_Zone.Identifier");
    CHECK(SafeDownloadName("a<b>c\"d|e?f*g") == "a_b_c_d_e_f_g");
    CHECK(SafeDownloadName(std::string("tab\there\x01")) == "tab_here_");
    // Trailing dots and spaces go (Windows would drop them, and a name could change under it).
    CHECK(SafeDownloadName("setup.exe. . ") == "setup.exe");
    CHECK(SafeDownloadName("...") == "download");
    CHECK(SafeDownloadName(" .") == "download");
    // Device names, any case, with an extension or not.
    CHECK(SafeDownloadName("CON") == "_CON");
    CHECK(SafeDownloadName("nul.txt") == "_nul.txt");
    CHECK(SafeDownloadName("Com1.tar.gz") == "_Com1.tar.gz");
    CHECK(SafeDownloadName("lpt9") == "_lpt9");
    CHECK(SafeDownloadName("console.txt") == "console.txt" && SafeDownloadName("com10") == "com10" && SafeDownloadName("comx") == "comx");
    // COM0 and LPT0 are reserved too, and so are COM and LPT with ¹ ² ³ (Microsoft's naming rules).
    CHECK(SafeDownloadName("COM0") == "_COM0" && SafeDownloadName("lpt0.log") == "_lpt0.log");
    CHECK(SafeDownloadName("COM\xC2\xB9") == "_COM\xC2\xB9" && SafeDownloadName("lpt\xC2\xB3.txt") == "_lpt\xC2\xB3.txt");
    CHECK(SafeDownloadName("COM\xC2\xB4") == "COM\xC2\xB4");
    // Spaces before the dot don't hide one: Windows reads "CON .txt" as CON.
    CHECK(SafeDownloadName("CON .txt") == "_CON .txt" && SafeDownloadName("nul  .tar.gz") == "_nul  .tar.gz");
    // At most 255 UTF-16 units, the extension kept; a number added after still fits.
    const std::string longName = std::string(300, 'a') + ".pdf";
    CHECK(SafeDownloadName(longName) == std::string(251, 'a') + ".pdf");
    std::string wide;
    for (int i = 0; i < 200; ++i) wide += "\xF0\x9F\x98\x80";  // U+1F600, two UTF-16 units each
    const auto points = unicode::Decode(SafeDownloadName(wide + ".txt"));
    CHECK(points.size() == 125 + 4);
    const fs::path folder = "D:/Downloads";
    auto numbered = UniqueDownloadPath(longName, folder, [&](const fs::path& p) { return p == folder / (std::string(251, 'a') + ".pdf"); });
    CHECK(numbered && numbered->filename().u8string().size() == 255 && numbered->extension() == ".pdf");
    // In a deep folder the name shortens to keep the path within MAX_PATH (259 units), as Chrome does.
    const fs::path deep = fs::path("D:/") / std::string(200, 'd');
    auto fitted = UniqueDownloadPath(std::string(100, 'n') + ".pdf", deep, [](const fs::path&) { return false; }, 259);
    CHECK(fitted && fitted->u8string().size() == 259 && fitted->extension() == ".pdf");
    auto fittedCopy = UniqueDownloadPath(std::string(100, 'n') + ".pdf", deep, [&](const fs::path& p) { return p == *fitted; }, 259);
    CHECK(fittedCopy && fittedCopy->u8string().size() == 259 && fittedCopy->stem().u8string().ends_with(u8" 2"));
    // Without a limit the name stays whole.
    auto whole = UniqueDownloadPath(std::string(100, 'n') + ".pdf", deep, [](const fs::path&) { return false; });
    CHECK(whole && whole->filename().u8string().size() == 104);
}

TEST(aBurstOfSameNameDownloadsGetsAPathEach) {
    // Ten downloads of one name at once, each finding its name on its own thread (CEF's file
    // thread pool) while none has a file on disk yet: every one gets a path of its own.
    TempFolder folder;
    DownloadReservations reservations;
    std::vector<std::optional<fs::path>> paths(10);
    std::vector<std::thread> threads;
    std::atomic<int> ready{0};
    for (size_t i = 0; i < paths.size(); ++i) {
        threads.emplace_back([&, i] {
            ++ready;
            while (ready < 10) std::this_thread::yield();
            paths[i] = reservations.Reserve("download-" + std::to_string(i), "same.bin", folder.dir, [](const fs::path& candidate) {
                std::error_code error;
                return fs::exists(candidate, error);
            });
        });
    }
    for (auto& thread : threads) thread.join();
    std::set<std::u32string> unique;
    for (const auto& path : paths) {
        CHECK(path.has_value());
        if (path) unique.insert(unicode::Folded(std::string(reinterpret_cast<const char*>(path->u8string().c_str()))));
    }
    CHECK(unique.size() == 10 && reservations.Count() == 10);
    CHECK(reservations.Held(folder.dir / "same.bin") && reservations.Held(folder.dir / "same 10.bin"));
    // Case doesn't make a second file on Windows: a held name is held in any case.
    CHECK(reservations.Held(folder.dir / "SAME 3.BIN"));
    CHECK(!reservations.Held(folder.dir / "same.bin", "download-" + std::to_string(std::distance(paths.begin(),
        std::find(paths.begin(), paths.end(), std::optional<fs::path>(folder.dir / "same.bin"))))));
    // A finished one gives its name back; asking again for the same download keeps nothing of its old one.
    const std::string first = "download-0";
    const fs::path firstPath = *paths[0];
    reservations.Release(first);
    CHECK(!reservations.Held(firstPath) && reservations.Count() == 9);
    auto again = reservations.Reserve(first, "same.bin", folder.dir, [](const fs::path&) { return false; });
    CHECK(again && *again == firstPath);
    auto restarted = reservations.Reserve(first, "same.bin", folder.dir, [](const fs::path&) { return false; });
    CHECK(restarted && *restarted == firstPath && reservations.Count() == 10);
    // A name the disk has is never handed out, and the Save As path is held as the real one.
    auto skipped = reservations.Reserve(first, "same.bin", folder.dir, [&](const fs::path& p) { return p == firstPath; });
    CHECK(skipped && *skipped != firstPath && !reservations.Held(firstPath));
    reservations.Hold(first, folder.dir / "elsewhere.bin");
    CHECK(reservations.Held(folder.dir / "elsewhere.bin") && !reservations.Held(firstPath));
}

TEST(reservedNamesCompareAsTheShellSays) {
    // Without a comparison, names compare by case folding; with one, its answer counts.
    const fs::path folder = "D:/Downloads";
    const auto never = [](const fs::path&) { return false; };
    DownloadReservations folded;
    CHECK(folded.Reserve("a", "Report.pdf", folder, never) == folder / "Report.pdf");
    CHECK(folded.Reserve("b", "REPORT.PDF", folder, never) == folder / "REPORT 2.PDF");
    DownloadReservations exact([](const fs::path& a, const fs::path& b) { return a.native() == b.native(); });
    CHECK(exact.Reserve("a", "Report.pdf", folder, never) == folder / "Report.pdf");
    CHECK(exact.Reserve("b", "REPORT.PDF", folder, never) == folder / "REPORT.PDF");
    // Dot segments, and on Windows mixed slashes, spell one path before any comparison sees it.
    exact.Hold("c", fs::path("D:/x/y/./a.pdf"));
    CHECK(exact.Held(fs::path("D:/x/y/a.pdf")) && exact.Held(fs::path("D:/x/z/../y/a.pdf")));
#ifdef _WIN32
    exact.Hold("d", fs::path("D:/w\\v/b.pdf"));
    CHECK(exact.Held(fs::path("D:\\w\\v\\b.pdf")) && exact.Held(fs::path("D:/w/v/b.pdf")));
    folded.Hold("c", fs::path("D:/x\\y/A.pdf"));
    CHECK(folded.Held(fs::path("D:\\x/y\\a.pdf")));
    DownloadReservations ntfsSlashes([](const fs::path& a, const fs::path& b) {
        return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
    });
    ntfsSlashes.Hold("e", fs::path("C:/x\\a.pdf"));
    CHECK(ntfsSlashes.Held(fs::path("C:\\x\\A.pdf")));
#endif
#ifdef _WIN32
    // The shell's comparison (CompareStringOrdinal, ignoring case) says what the disk says: a file
    // made under one name is or isn't found under the other. Checked for plain case and for the
    // pairs case folding joins but NTFS keeps apart on this PC (ſ and s, ı and I, ς and σ, µ and μ).
    const auto windows = [](const fs::path& a, const fs::path& b) {
        return CompareStringOrdinal(a.c_str(), -1, b.c_str(), -1, TRUE) == CSTR_EQUAL;
    };
    TempFolder disk;
    for (const auto& [one, other] : std::vector<std::pair<std::wstring, std::wstring>>{
             {L"abc.txt", L"ABC.txt"}, {L"\u017Fet.txt", L"SET.txt"}, {L"\u0131d.txt", L"ID.txt"},
             {L"\u03C2.txt", L"\u03C3.txt"}, {L"\u00B5.txt", L"\u03BC.txt"}}) {
        { std::ofstream(disk.dir / one) << "x"; }
        std::error_code error;
        const bool sameOnDisk = fs::exists(disk.dir / other, error);
        CHECK(windows(fs::path(one), fs::path(other)) == sameOnDisk);
        fs::remove(disk.dir / one, error);
    }
    DownloadReservations ntfs(windows);
    CHECK(ntfs.Reserve("a", "report.pdf", folder, never) == folder / "report.pdf");
    CHECK(ntfs.Reserve("b", "REPORT.pdf", folder, never) == folder / "REPORT 2.pdf");
#endif
}

TEST(aShortenedNameIsNeverADeviceName) {
    // A deep folder leaves room for 7 units: "AUXreport.pdf" would be "AUX.pdf".
    const fs::path deep = fs::path("D:/") / std::string(40, 'd');
    const size_t folderUnits = deep.u8string().size();
    const auto never = [](const fs::path&) { return false; };
    auto aux = UniqueDownloadPath("AUXreport.pdf", deep, never, folderUnits + 1 + 7);
    CHECK(aux && aux->filename() == "_AU.pdf");
    auto con = UniqueDownloadPath("CONTRACT.pdf", deep, never, folderUnits + 1 + 7);
    CHECK(con && con->filename() == "_CO.pdf");
    // A long extension goes before the name does.
    auto longExtension = UniqueDownloadPath("notes." + std::string(40, 'x'), deep, never, folderUnits + 1 + 20);
    CHECK(longExtension && longExtension->filename() == "notes");
}

TEST(theStallCheckRunsOnlyWhileAPageIsParked) {
    using T = ParkedStallCheck::Timer;
    ParkedStallCheck check;
    CHECK(check.Parked(0) == T::Leave);
    CHECK(check.Parked(1) == T::Start && check.running);
    CHECK(check.Parked(2) == T::Leave);
    CHECK(check.Parked(1) == T::Leave);
    CHECK(check.Parked(0) == T::Stop && !check.running);
    CHECK(check.Parked(0) == T::Leave);
    CHECK(check.Parked(3) == T::Start);
    CHECK(!ParkedStallCheck::Stalled(1000, 1000 + ParkedStallCheck::kStallMs));
    CHECK(ParkedStallCheck::Stalled(1000, 1001 + ParkedStallCheck::kStallMs));
    CHECK(!ParkedStallCheck::Stalled(5000, 4000));  // a clock that went back isn't a stall
}

TEST(theDownloadFolderNeverLeavesATestProfile) {
    // Absolute on every OS (a test folder must be).
    const fs::path base = fs::temp_directory_path();
    const fs::path support = base / "profile", user = base / "Users" / "me" / "Downloads", test = base / "downloads";
    // KITE_TEST_DOWNLOADS_PATH counts only with KITE_SUPPORT_PATH.
    CHECK(DefaultDownloadFolder(test, true, false, support, user) == test);
    CHECK(DefaultDownloadFolder(test, false, false, support, user) == user);
    CHECK(DefaultDownloadFolder(fs::path(), true, false, support, user) == user);
    // A quiet run without it uses its profile's own folder, never the user's.
    CHECK(DefaultDownloadFolder(std::nullopt, true, true, support, user) == support / "Downloads");
    CHECK(DefaultDownloadFolder(test, true, true, support, user) == test);
    CHECK(DefaultDownloadFolder(std::nullopt, false, false, support, user) == user);
    // A relative folder isn't a test folder (Kite.exe refuses it).
    CHECK(DefaultDownloadFolder(fs::path("downloads"), true, false, support, user) == user);
    // A test profile is anything but %LOCALAPPDATA%\Kite, decided the same way by Kite.exe and kitecore.
    TempFolder local;
    fs::create_directories(local.dir / "Kite");
    CHECK(!IsTestProfile(local.dir / "Kite", local.dir));
    CHECK(!IsTestProfile(local.dir / "x" / ".." / "Kite", local.dir));
    CHECK(IsTestProfile(local.dir / "other", local.dir));
    CHECK(IsTestProfile(local.dir / "Kite", std::nullopt));
}

TEST(readingWithoutWritingCountsWhatItCouldntRead) {
    TempFolder folder;
    const fs::path file = folder.dir / "downloads.json";
    CHECK(downloads_file::ReadOnly(file) && downloads_file::ReadOnly(file)->list.Items().empty());
    WriteText(file, R"({"version":1,"downloads":{"items":[{"id":"nope"},{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","url":"u",
        "path":"","state":"inProgress","receivedBytes":1,"totalBytes":2,"startedAt":1}]}})");
    auto read = downloads_file::ReadOnly(file);
    CHECK(read && read->dropped == 1 && read->list.Items().size() == 1 && read->list.Items()[0].state == S::Interrupted);
    WriteText(file, "{nope");
    CHECK(!downloads_file::ReadOnly(file));
    CHECK(ReadText(file) == "{nope");  // never moved
}

TEST(profileSettingsDecodeAsSwiftDoes) {
    // Members of the wrong type fail the session, as the Mac's decoder does; null is absent, and
    // members Windows doesn't know are kept.
    auto settings = DecodeProfileSettings(json::Value(json::Object{{"promptsForDownload", true}, {"downloadDirectory", nullptr},
                                                                   {"futureSetting", 3}}));
    CHECK(settings && settings->promptsForDownload && !settings->downloadDirectory && settings->includesSearchSuggestions);
    CHECK(settings && Encode(*settings).Find("futureSetting") && !Encode(*settings).Find("downloadDirectory"));
    CHECK(!DecodeProfileSettings(json::Value(json::Object{{"promptsForDownload", "yes"}})));
    CHECK(!DecodeProfileSettings(json::Value(json::Object{{"downloadDirectory", 1}})));
    BrowserState state = BrowserState::MakeDefault(std::nullopt);
    json::Value encoded = Encode(state);
    CHECK(!encoded.Find("profileSettings"));  // none stored: none written
    encoded.AsObject()->insert_or_assign("profileSettings", json::Object{{kDefaultDataStoreID, json::Object{{"promptsForDownload", 2}}}});
    CHECK(!DecodeBrowserState(encoded));
    // A profile's settings follow its dataStoreID (uppercased), and a profile that's gone reads the default's.
    const std::string work = AddProfile(state, "Work");
    state.UpdateSettings(work, [](ProfileSettings& s) { s.promptsForDownload = true; });
    CHECK(state.profileSettings.size() == 1 && state.profileSettings.begin()->first != kDefaultDataStoreID);
    CHECK(state.Settings(std::string("Profile 9")) == ProfileSettings());
    auto again = DecodeBrowserState(Encode(state));
    CHECK(again && again->Settings(work).promptsForDownload && again->profileSettings == state.profileSettings);
}

// MARK: DownloadsModel (KiteMac's, untested there)

TEST(theModelSavesStartsAndFinishesSoonAndProgressLater) {
    DownloadsModel model;
    model.Restore(DownloadList(), true, 0);
    auto started = model.Apply(Update(1), 0);
    CHECK(started.applied && started.isNew && started.save == DownloadsSaveSchedule::kSoon);
    model.Schedule().Saved();
    // A tick: 5 s. Another tick doesn't push it back.
    CHECK(model.Apply(Update(1, S::InProgress, 10), 1).save == DownloadsSaveSchedule::kProgress);
    CHECK(!model.Apply(Update(1, S::InProgress, 20), 2).save);
    CHECK(model.Schedule().DueAt() == 6);
    // Finishing replaces the waiting tick's save with a sooner one.
    auto finished = model.Apply(Update(1, S::Complete, 100), 3);
    CHECK(finished.stateChanged && finished.save == DownloadsSaveSchedule::kSoon && model.Schedule().DueAt() == 3.2);
    // A finished download is final: a late tick or repeat changes nothing.
    CHECK(!model.Apply(Update(1, S::InProgress, 50, 100, "/elsewhere"), 4).applied);
    CHECK(model.List().Items()[0].state == S::Complete && model.List().Items()[0].path == "/Users/me/Downloads/report.pdf");
}

TEST(theModelKeepsIncognitoOutOfTheFile) {
    DownloadsModel model;
    model.Restore(DownloadList(), true, 0);
    auto secret = model.Apply(Report(1, "incognito-1", true, "https://secret/a", "/d/a", S::InProgress, 0, 9), 0);
    CHECK(secret.applied && !secret.save);
    model.EndIncognitoSession("incognito-1");
    CHECK(model.List().Items().empty());
    // A late report from the ended session doesn't bring the row back.
    CHECK(!model.Apply(Report(1, "incognito-1", true, "https://secret/a", "/d/a", S::Complete, 9, 9), 1).applied);
    CHECK(model.List().Items().empty());
}

TEST(nothingIsSavedBeforeTheFileIsRead) {
    DownloadsModel model;
    DownloadList restored;
    restored.Apply(Update(9, S::Complete), 10);
    restored.MarkRestored();
    // A download that starts before the worker has read downloads.json waits for it.
    auto early = model.Apply(Update(1), 0, 50);
    CHECK(early.applied && !early.save && !model.MaySave());
    // The read joins the list under the live one, and the waiting save is armed.
    CHECK(model.Restore(restored, true, 1) == DownloadsSaveSchedule::kSoon);
    CHECK(model.List().Items().size() == 2 && model.List().Items()[0].engineID == 1 && !model.List().Items()[1].engineID);
    CHECK(model.MaySave());
    // Once only.
    CHECK(!model.Restore(restored, true, 2) && model.List().Items().size() == 2);
    // A file that couldn't be kept aside is never replaced.
    DownloadsModel locked;
    locked.Apply(Update(1), 0);
    CHECK(!locked.Restore(DownloadList(), false, 1) && !locked.MaySave());
    CHECK(!locked.Apply(Update(1, S::Complete), 2).save);
}

TEST(theModelsListActions) {
    DownloadsModel model;
    model.Restore(DownloadList(), true, 0);
    model.Apply(Update(1, S::Complete), 0, 100);
    model.Apply(Update(2), 0, 200);
    model.Schedule().Saved();
    const std::string live = model.List().Items()[0].id;
    const std::string done = model.List().Items()[1].id;
    CHECK(model.Moved(done, "/d/renamed.pdf", 1) == DownloadsSaveSchedule::kSoon);
    CHECK(model.List().Find(done)->path == "/d/renamed.pdf");
    CHECK(!model.Moved("6F9619FF-8B86-D011-B42D-00C04FC964FF", "/x", 1));
    // Chromium had already let it go: canceled here, nothing saved for it.
    model.CanceledWithoutEngine(*model.List().Find(live));
    CHECK(model.List().Find(live)->state == S::Canceled && model.List().Find(live)->speed == 0);
    model.RemoveHistory(150, 2);
    CHECK(model.List().Items().size() == 1 && model.List().Items()[0].id == done);
    CHECK(model.ClearFinished(3) && model.List().Items().empty());
}

TEST(restoringJoinsUnderTheLiveDownloadsAndTrims) {
    DownloadList live;
    live.Apply(Update(1));
    DownloadList restored;
    for (int64_t id = 0; id < static_cast<int64_t>(DownloadList::kLimit); ++id) restored.Apply(Update(id + 10, S::Complete));
    restored.MarkRestored();
    live.AdoptRestored(restored);
    CHECK(live.Items().size() == DownloadList::kLimit && live.Items()[0].engineID == 1);
    // The oldest restored one fell off; adopting the same list again adds nothing.
    CHECK(!live.Find(restored.Items().back().id));
    live.AdoptRestored(restored);
    CHECK(live.Items().size() == DownloadList::kLimit);
}

// MARK: DownloadsWriter

TEST(theWriterReadsFirstThenWritesAtomically) {
    TempFolder folder;
    const fs::path file = folder.dir / "downloads.json";
    DownloadList onDisk;
    onDisk.Apply(Update(5, S::InProgress, 10));
    WriteText(file, downloads_file::Encode(onDisk));
    DownloadsWriter writer(file);
    std::optional<downloads_file::Loaded> got;
    bool called = false;
    std::thread::id loadThread;
    // A snapshot handed over before the read waits for it.
    DownloadList early;
    early.Apply(Update(1));
    writer.Save(early);
    writer.Load([&](std::optional<downloads_file::Loaded> loaded) {
        called = true;
        got = std::move(loaded);
        loadThread = std::this_thread::get_id();
    });
    CHECK(writer.Flush(std::chrono::seconds(10)).empty());
    CHECK(called && got && (States(got->list) == std::vector<S>{S::Interrupted}));
    CHECK(loadThread != std::this_thread::get_id());
    auto stats = writer.Stats();
    CHECK(stats.loaded && stats.canSave && stats.written == 1);
    CHECK(downloads_file::Decode(ReadText(file)) == early);
    // The same bytes aren't written again; a newer list is.
    writer.Save(early);
    CHECK(writer.Flush(std::chrono::seconds(10)).empty() && writer.Stats().unchanged == 1);
    early.Apply(Update(1, S::Complete, 100));
    writer.Save(early);
    CHECK(writer.Flush(std::chrono::seconds(10)).empty() && writer.Stats().written == 2);
    CHECK(downloads_file::Decode(ReadText(file)) == early);
    // No temp is left beside it.
    size_t files = 0;
    for (const auto& entry : fs::directory_iterator(folder.dir)) files += entry.is_regular_file();
    CHECK(files == 1);
}

TEST(theWriterNeverReplacesAFileItCouldntKeep) {
    TempFolder folder;
    const fs::path file = folder.dir / "downloads.json";
    // A damaged file is moved aside on the worker; saving then goes ahead.
    WriteText(file, "{\"version\":1,\"downl");
    {
        DownloadsWriter writer(file);
        std::optional<downloads_file::Loaded> got;
        writer.Load([&](std::optional<downloads_file::Loaded> loaded) { got = std::move(loaded); });
        DownloadList list;
        list.Apply(Update(1));
        writer.Save(list);
        CHECK(writer.Flush(std::chrono::seconds(10)).empty());
        CHECK(got && got->movedAside && fs::exists(*got->movedAside));
        CHECK(downloads_file::Decode(ReadText(file)) == list);
    }
#ifdef _WIN32
    // One that can't be read or moved (held open by another program, as antivirus or a sync
    // client can) is left as it is: nothing is written over it this launch.
    const fs::path held = folder.dir / "held.json";
    WriteText(held, "{\"version\":1,\"downloads\":{\"items\":[]}}");
    if (FILE* lock = _wfsopen(held.c_str(), L"rb", _SH_DENYRW)) {
        DownloadsWriter writer(held);
        bool called = false, none = false;
        writer.Load([&](std::optional<downloads_file::Loaded> loaded) {
            called = true;
            none = !loaded;
        });
        DownloadList list;
        list.Apply(Update(1));
        writer.Save(list);
        CHECK(writer.Flush(std::chrono::seconds(10)).empty());
        CHECK(called && none && writer.Stats().refused == 1 && !writer.Stats().canSave);
        std::fclose(lock);
        CHECK(ReadText(held) == "{\"version\":1,\"downloads\":{\"items\":[]}}");
    } else {
        const bool heldOpen = false;  // couldn't hold the file open
        CHECK(heldOpen);
    }
#endif
    // Without a read nobody asked for, a flush doesn't wait for one.
    DownloadsWriter idle(folder.dir / "other.json");
    idle.Save(DownloadList());
    CHECK(idle.Flush(std::chrono::seconds(5)).empty() && !idle.Writing() && !fs::exists(folder.dir / "other.json"));
}

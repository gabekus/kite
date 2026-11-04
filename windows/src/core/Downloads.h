#pragma once
// The downloads list: a port of KiteCore's Downloads.swift (DownloadItem, DownloadUpdate,
// DownloadList, DownloadsFile, DownloadText), BrowsingData.swift's DownloadList.removeHistory,
// Extensions.swift's ExtensionPackage, and KCBrowser.mm's UniqueDownloadURL.
//
// downloads.json in the support folder is the Mac's file, read and written by both apps:
// {"version": 1, "downloads": {"items": [...]}}, newest first, at most 100 (older finished ones
// fall off; live ones never do). An item Kite can't read is dropped, not the list, and the file
// is copied aside first; a file that doesn't read at all is moved aside, so the next save never
// replaces someone's history with an empty list. Incognito downloads are listed for the launch
// only and never written.

#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

#include "core/Json.h"
#include "core/Models.h"

namespace kite {

enum class DownloadState { InProgress, Complete, Canceled, Interrupted };

// DownloadItem.State's raw values in downloads.json ("inProgress", "complete", ...).
std::string_view RawValue(DownloadState state);
std::optional<DownloadState> DownloadStateFromRaw(std::string_view raw);

// One download in the list, kept across launches.
struct DownloadItem {
    // Unique for the life of the list: the engine's own id restarts at 1 every launch.
    std::string id;
    // The engine's id while this launch's download is live; none once restored from disk.
    std::optional<int64_t> engineID;
    // Which engine profile (browser context) engineID belongs to: Chromium numbers each
    // profile's downloads from 1. "" for the default profile; none once restored from disk.
    std::optional<std::string> engineContext;
    // Started in an incognito window: listed for this launch only, never written to disk.
    bool isIncognito = false;
    std::string url;
    // Where the file is (or will be) on disk. Empty until the engine picks a path.
    std::string path;
    DownloadState state = DownloadState::InProgress;
    int64_t receivedBytes = 0;
    int64_t totalBytes = -1;  // -1 while the size isn't known
    int64_t speed = 0;        // bytes per second, live downloads only
    Timestamp startedAt = 0;

    // The file's name: the path's last part, else the URL's.
    std::string FileName() const;
    // 0...1, or none while the size isn't known.
    std::optional<double> Fraction() const;
    // The site it came from, for Arc's "from example.com": the URL's host without "www.".
    std::optional<std::string> SourceHost() const;
    bool operator==(const DownloadItem&) const = default;
};

json::Value Encode(const DownloadItem&);
// Swift's DownloadItem(from:): none when a required member is missing or has the wrong type.
std::optional<DownloadItem> DecodeDownloadItem(const json::Value&);

// What an engine reports as a download moves along.
struct DownloadUpdate {
    int64_t engineID = 0;
    // The browser context the id is unique within ("" for the default profile, the folder for
    // another profile, "incognito-N" for an incognito window).
    std::string engineContext;
    bool isIncognito = false;
    // The profile folder, for a non-default profile's download.
    std::optional<std::string> profileDirectory;
    std::string url;
    std::string path;
    DownloadState state = DownloadState::InProgress;
    int64_t receivedBytes = 0;
    int64_t totalBytes = -1;
    int64_t speed = 0;

    // The bridge's report as JSON, the keys of the Mac's KCDownloadDidUpdateNotification
    // userInfo ("id", "context", "incognito", "profileDirectory", "url", "path", "state",
    // "receivedBytes", "totalBytes", "speed"): what `kitecore downloads apply` reads. None
    // without an id.
    static std::optional<DownloadUpdate> FromInfo(const json::Value& info);
    json::Value Info() const;
    // Chromium's names ("complete", "canceled", "interrupted", "in-progress"; anything else is
    // in progress).
    static DownloadState StateNamed(std::string_view name);
    static std::string_view NameOf(DownloadState state);
    bool operator==(const DownloadUpdate&) const = default;
};

// Recent downloads, newest first.
class DownloadList {
public:
    static constexpr int kCurrentVersion = 1;
    // Older finished downloads fall off the end.
    static constexpr size_t kLimit = 100;

    DownloadList() = default;
    explicit DownloadList(std::vector<DownloadItem> items) : items_(std::move(items)) {}

    const std::vector<DownloadItem>& Items() const { return items_; }

    // The live download an engine reports under `engineID` in `context`.
    const DownloadItem* Item(int64_t engineID, std::string_view context) const;
    const DownloadItem* Find(const std::string& id) const;

    // Returns the item, and whether it's new to the list (at the top).
    struct Applied {
        DownloadItem item;
        bool isNew = false;
    };
    Applied Apply(const DownloadUpdate& update, Timestamp now = Now());

    // Restored from disk: nothing is live any more, so a download cut off by quitting reads
    // as interrupted.
    void MarkRestored();
    // Ends an incognito session (its window closed): its downloads leave the list.
    void RemoveIncognito(std::string_view context);
    // The file was renamed or moved on disk. False when the item isn't listed.
    bool SetPath(const std::string& path, const std::string& id);
    void Remove(const std::string& id);
    // Drops every finished download; live ones stay.
    void ClearFinished();
    // Delete browsing data's download history: finished downloads started at or after `since`
    // (none: all). Files stay, and downloads still running stay listed.
    void RemoveHistory(std::optional<Timestamp> since);
    // The list read from disk joins this launch's (Windows reads downloads.json on a worker,
    // so a download can start before it arrives): this launch's stay on top, being newer.
    void AdoptRestored(const DownloadList& restored);

    std::vector<DownloadItem> Active() const;
    // Progress across every live download (bytes over bytes), none when none has a known size.
    std::optional<double> ActiveFraction() const;

    bool operator==(const DownloadList&) const = default;

private:
    void Trim();
    std::vector<DownloadItem> items_;
};

// The list's JSON ({"items": [...]}): incognito downloads stay in memory, never in the file.
json::Value Encode(const DownloadList&);
// One item Kite can't read is dropped, not the whole list; none when it isn't a list at all.
std::optional<DownloadList> DecodeDownloadList(const json::Value&);

// downloads.json: the list with its version.
namespace downloads_file {

std::string Encode(const DownloadList& list);
// The file's list, none when it isn't a downloads file.
std::optional<DownloadList> Decode(std::string_view text);

struct Loaded {
    DownloadList list;
    // Where an unreadable file was moved.
    std::optional<std::filesystem::path> movedAside;
    // Where the original was copied when some of its items couldn't be read (a newer Kite's,
    // say): the next save leaves them out.
    std::optional<std::filesystem::path> copiedAside;
    size_t dropped = 0;  // how many items couldn't be read
    // False when unreadable items couldn't be copied aside: saving would lose them.
    bool canSave = true;
};

// The list in `file`, restored (nothing live). A file that's there but can't be read is moved
// aside first; one with items that can't be read is copied aside and the rest load. None when an
// unreadable file couldn't be moved aside: then nothing should be saved over it.
std::optional<Loaded> Load(const std::filesystem::path& file);
// The list in `file` without moving or copying anything (kitecore only looks): an empty list
// when there's no file, none when it doesn't read.
std::optional<DownloadList> Read(const std::filesystem::path& file);

// Next to the file, named as the session's are ("corrupt-<stamp>"), with milliseconds and a
// few random characters so two in one second can't collide.
std::filesystem::path AsidePath(const std::filesystem::path& file);

}  // namespace downloads_file

// The text under a download's name (Arc's copy names the cases; the wording is Kite's).
namespace download_text {

// ByteCountFormatter's .file style: decimal units, "Zero KB", "1 byte", "512 bytes", "4 KB",
// "1.5 MB", "1.25 GB".
std::string Size(int64_t bytes);
std::string Subtitle(const DownloadItem& item);
// Arc's sidebar download cell names a file's type: "PDF", "Disk Image", "Movie", "Video",
// "Image", "Audio", "ZIP Archive", "Archive", else "File".
std::string Kind(std::string_view fileName);

}  // namespace download_text

// A Chrome Web Store package (Extensions.swift's ExtensionPackage): Chromium's installer
// takes it, so it never reaches Downloads or the list. By its MIME type, or a .crx name from
// Google's extension hosts (the store serves packages as octet-stream from them).
bool IsExtensionPackage(std::string_view mimeType, std::string_view suggestedName, std::string_view url);

// KCBrowser.mm's UniqueDownloadURL: `name` in `directory`, or "name 2.ext", "name 3.ext"...
// when `taken` says a path is used (a file there, or reserved by a download still running,
// since Chromium creates the file only once data arrives). A name with path separators keeps
// its last part, so a download never lands outside the folder.
std::filesystem::path UniqueDownloadPath(std::string_view name, const std::filesystem::path& directory,
                                         const std::function<bool(const std::filesystem::path&)>& taken);

}  // namespace kite

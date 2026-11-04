#pragma once
// Browsing history, one entry per URL, for the command bar's history rows (and Import from Arc,
// W33a). A port of KiteCore's History.swift (HistoryEntry, History, and the History extension in
// BrowsingData.swift) and HistoryFile.swift: history.json, and each other profile's
// Chromium/<dir>/Kite History.json, in the Mac's format, so either app reads the other's.
//
//   {"version": 1, "history": {"entries": {"<url>": {"url": "<url>", "title": "...",
//                                                     "lastVisit": <Date>, "visitCount": 3}}}}
//
// Dates are Foundation's (seconds since 2001, core/Models.h's Timestamp). Only web pages are
// kept, and at most kMaxEntries of them (the oldest go first). A URL is kept as the Mac keeps it,
// its absoluteString after NSURL has read it (Normalized). The history page's days and headings
// (History.days, HistoryDay) come with the history page.
//
// History is a value, as the Mac's struct is, and copying one is cheap: the entries live in
// kShards shards shared between copies and copied on write, one shard at a time. That's how the
// app hands a snapshot to its writer thread (core/HistoryStore.h) without copying 20,000 entries
// on the UI thread, and the first visit after a save copies one shard (about 80 entries), not
// the whole history, as Swift's copy-on-write dictionary would.
//
// Each entry also keeps its title, URL and host lowercased and decomposed (TextMatch.h's
// FoldedBytes): Search looks for what's typed in those with a byte search, and ranks only the
// entries that can match the way the Mac does.

#include <array>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <unordered_map>
#include <variant>
#include <vector>

#include "core/Models.h"

namespace kite {

// One visited page.
struct HistoryEntry {
    std::string url;
    std::string title;
    Timestamp lastVisit = 0;
    int64_t visitCount = 1;

    // The title, else the host, else the URL.
    std::string DisplayTitle() const;
    bool operator==(const HistoryEntry&) const = default;
};

class History {
public:
    static constexpr int kCurrentVersion = 1;
    // Oldest entries beyond this are dropped.
    static constexpr size_t kMaxEntries = 20'000;
    static constexpr size_t kShards = 256;

    // Web pages only, as the Mac's records(_:): http and https. Also a URL the Mac can read back
    // (url::HasValidAuthority): one Foundation rejects would make the Mac drop the whole file.
    static bool Records(std::string_view url);
    // `url` as the Mac keeps it: NSURL (RFC 3986, macOS 14) percent-encodes what a path, query
    // or fragment may not hold (space, " < > \ ^ ` { | } [ ], a second #, a % that starts no
    // escape, controls and anything past ASCII), and Chromium leaves some of those as typed. The
    // authority is left alone. Every method here that takes a URL takes it through this.
    static std::string Normalized(std::string_view url);

    // False when the URL isn't one history keeps (Records): nothing changed.
    bool RecordVisit(std::string_view url, std::string_view title, Timestamp at);
    // A page's title usually arrives after its URL. Returns whether the entry changed: pages that
    // set document.title on a timer mostly repeat it, and a repeat needn't be saved.
    bool UpdateTitle(std::string_view url, std::string_view title);
    // Whether UpdateTitle would change anything, without touching the history.
    bool UpdatesTitle(std::string_view url, std::string_view title) const;
    void RemoveAll();
    // Adds history from another browser (Import from Arc). A page already here keeps the later
    // visit and the higher count, so importing twice doesn't double anything. Returns how many
    // pages were new.
    size_t Merge(const std::vector<HistoryEntry>& imported);
    // Chromium's history timestamps: microseconds since 1601-01-01 UTC.
    static Timestamp ChromiumDate(int64_t microseconds);
    // The history page's Remove from History.
    void Remove(const std::vector<std::string>& urls);
    // Delete browsing data's history: pages last visited at or after `since` (none: all). Kite
    // keeps one last visit per page, so a page visited in the range goes entirely.
    void RemoveVisits(std::optional<Timestamp> since);
    // Past kMaxEntries, the oldest go, as Merge does (a file over the cap, as it's read).
    void TrimToCap();

    // Best matches first: how well the title, host or URL matches, then how often and how
    // recently the page was visited. Ties: the later visit, then the URL (the Mac leaves those
    // in no set order).
    std::vector<HistoryEntry> Search(std::string_view query, size_t limit = 4, Timestamp now = Now()) const;
    // `query` trimmed and lowercased: 100 host prefix, 90 title prefix, 75 a title word's
    // prefix, 55 in the title, 40 in the URL.
    static std::optional<int> Score(std::string_view query, const HistoryEntry& entry);

    size_t Count() const { return count_; }
    bool Empty() const { return count_ == 0; }
    std::optional<HistoryEntry> Find(std::string_view url) const;
    // Every entry, sorted by URL (the file's order).
    std::vector<HistoryEntry> Entries() const;
    void ForEach(const std::function<void(const HistoryEntry&)>& body) const;

    bool operator==(const History& other) const;

    // The file: {"history": {"entries": {...}}, "version": 1}. Decode is as strict as the Mac's
    // JSONDecoder (every member there and of its type, a whole-number visitCount), but reads any
    // string as a URL: a URL the Mac wrote is one Foundation took.
    std::string EncodeFile() const;
    static std::variant<History, std::string> DecodeFile(std::string_view text);

private:
    // What's typed, ready for Search: lowercased, decomposed, and where its Characters start.
    struct Needle;

    struct Item {
        std::string title;
        Timestamp lastVisit = 0;
        int64_t visitCount = 1;
        // What Search looks in: FoldedBytes(title) '\0' FoldedBytes(url), then '\0' FoldedBytes
        // of the host when it isn't in the URL's part already (a "www." removed from inside it),
        // up to textEnd. After that, for a title that isn't ASCII, a bitmap of where its folded
        // bytes start a Character (titleEnd + 1 bits): ranking compares Characters, as Swift's
        // String does, without folding the title again.
        std::string folded;
        uint32_t titleEnd = 0;
        uint32_t urlEnd = 0;
        uint32_t textEnd = 0;
        // Where the URL (the key) spells the host as Score compares it, so ranking needn't make
        // it again; kNoHost when it doesn't (an uppercase host, a "www." inside it).
        uint16_t hostAt = 0;
        uint16_t hostLength = 0;
    };
    static constexpr uint16_t kNoHost = 0xFFFF;
    // Looked up by string_view, so a visit to a page already here allocates nothing.
    struct KeyHash {
        using is_transparent = void;
        size_t operator()(std::string_view key) const noexcept { return std::hash<std::string_view>{}(key); }
    };
    using Shard = std::unordered_map<std::string, Item, KeyHash, std::equal_to<>>;

    // Normalized, into `scratch` only when something changes: `url` itself otherwise.
    static std::string_view Key(std::string_view url, std::string& scratch);
    static size_t ShardOf(std::string_view url);
    static void Index(std::string_view url, Item& item);
    static HistoryEntry EntryOf(const std::string& url, const Item& item);
    static std::optional<int> ScoreItem(const Needle& needle, std::string_view url, const Item& item);
    // `url` already Normalized.
    const Item* FindItem(std::string_view url) const;
    // The shard for writing: unshared first.
    Shard& Writable(size_t shard);
    Item* FindWritable(std::string_view url);
    void Insert(const HistoryEntry& entry);
    void Prune(size_t count);
    // Whether a copy (a snapshot the writer holds) still shares a shard with this one.
    bool SharesShards() const;

    std::array<std::shared_ptr<Shard>, kShards> shards_{};
    size_t count_ = 0;
};

// Reads and writes history.json (and each other profile's Kite History.json). A plain value, so
// HistoryStore can encode and write a snapshot off the UI thread.
class HistoryFile {
public:
    explicit HistoryFile(std::filesystem::path file) : file_(std::move(file)) {}
    const std::filesystem::path& File() const { return file_; }

    struct Missing {};
    struct Error {
        std::string message;
        // Where the unreadable file went; none when it's still in place (it couldn't be read or
        // moved, or is past store_file::kMaxHistoryReadBytes), so saving would overwrite it.
        std::optional<std::filesystem::path> quarantinedTo;
    };
    using LoadResult = std::variant<History, Missing, Error>;
    enum class Unreadable { MoveAside, Leave };
    // An unreadable file is moved aside (<name>.corrupt-<unix time>.json) for a bug report rather
    // than overwritten, as the Mac's; kitecore leaves it where it is. A file past 64 MB isn't
    // read at all (and is left where it is).
    LoadResult Load(Unreadable unreadable = Unreadable::MoveAside) const;
    // Whether saving after this load can't destroy history the user has: false when the file is
    // still there unread. (The Mac's try? reads it as no file and overwrites it.)
    static bool MaySave(const LoadResult& result);

    // Empty on success: the parent folder made, the file written atomically (core/StoreFile.h).
    std::string Save(const History& history) const;
    std::string Write(std::string_view bytes) const;

private:
    std::filesystem::path file_;
};

}  // namespace kite

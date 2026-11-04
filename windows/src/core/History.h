#pragma once
// Browsing history, one entry per URL, for the command bar's history rows (and the history page
// and Import from Arc, which come later). A port of KiteCore's History.swift (HistoryEntry,
// HistoryDay, History, and the History extensions in BrowsingData.swift and BrowserImport.swift)
// and HistoryFile.swift: history.json, and each other profile's Chromium/<dir>/Kite History.json,
// in the Mac's format, so either app reads the other's.
//
//   {"version": 1, "history": {"entries": {"<url>": {"url": "<url>", "title": "...",
//                                                     "lastVisit": <Date>, "visitCount": 3}}}}
//
// Dates are Foundation's (seconds since 2001, core/Models.h's Timestamp). Only web pages are
// kept, and at most kMaxEntries of them (the oldest go first).
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

// The calendar the history page groups days by: the start of the day a moment falls in, and
// that day's date. Local() is the system's time zone; Utc() is for tests.
struct HistoryCalendar {
    struct Date {
        int year, month, day;  // month 1–12
        int weekday;           // 0 Sunday … 6 Saturday
    };
    std::function<Timestamp(Timestamp)> startOfDay;
    std::function<Date(Timestamp)> date;

    static HistoryCalendar Utc();
    static HistoryCalendar Local();
};

// One day of the history page, newest entry first.
struct HistoryDay {
    Timestamp start = 0;
    std::vector<HistoryEntry> entries;

    // Chromium's history page headings: "Today - Saturday, October 31, 2026", "Yesterday - Friday,
    // October 30, 2026", then the date alone. In English: the Mac's formats in the user's locale,
    // which the history page (a later checkpoint) gets from Windows.
    std::string Heading(Timestamp now, const HistoryCalendar& calendar) const;
    bool operator==(const HistoryDay&) const = default;
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

    void RecordVisit(std::string_view url, std::string_view title, Timestamp at);
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
    // Firefox's (microseconds since 1970) and Safari's (seconds since 2001).
    static Timestamp FirefoxDate(int64_t microseconds);
    static Timestamp SafariDate(double seconds) { return seconds; }
    // The history page's Remove from History.
    void Remove(const std::vector<std::string>& urls);
    // Delete browsing data's history: pages last visited at or after `since` (none: all). Kite
    // keeps one last visit per page, so a page visited in the range goes entirely.
    void RemoveVisits(std::optional<Timestamp> since);

    // The history page's list: newest first, grouped by the day of the last visit, keeping
    // entries whose title or URL contains `query` (case-insensitive), as Chromium's search does.
    std::vector<HistoryDay> Days(std::string_view query, const HistoryCalendar& calendar) const;

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

public:
    // What's typed, ready for Search: lowercased, decomposed, and where its Characters start.
    struct Needle;

private:
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
    using Shard = std::unordered_map<std::string, Item>;

    static size_t ShardOf(std::string_view url);
    static void Index(std::string_view url, Item& item);
    static HistoryEntry EntryOf(const std::string& url, const Item& item);
    static std::optional<int> ScoreItem(const Needle& needle, std::string_view url, const Item& item);
    const Item* FindItem(std::string_view url) const;
    // The shard for writing: unshared first.
    Shard& Writable(size_t shard);
    Item* FindWritable(std::string_view url);
    void Insert(const HistoryEntry& entry);
    void Prune(size_t count);

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
        // moved), so saving would overwrite it.
        std::optional<std::filesystem::path> quarantinedTo;
    };
    using LoadResult = std::variant<History, Missing, Error>;
    enum class Unreadable { MoveAside, Leave };
    // An unreadable file is moved aside (<name>.corrupt-<unix time>.json) for a bug report rather
    // than overwritten, as the Mac's; kitecore leaves it where it is.
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

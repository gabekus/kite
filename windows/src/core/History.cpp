// See History.h.

#include "core/History.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>

#include "core/Json.h"
#include "core/StoreFile.h"
#include "core/TextMatch.h"
#include "core/Unicode.h"
#include "core/Url.h"

namespace kite {

namespace fs = std::filesystem;
using text_match::Field;
using text_match::FoldedBytes;
using text_match::Query;
using text_match::ReplaceAll;
using text_match::TrimmedLowercase;

namespace {

constexpr double kDay = 86'400;

// The host as the Mac's History.score and the row's subtitle use it: lowercased, every "www."
// removed (replacingOccurrences, so not only a leading one).
std::string HostKey(std::string_view url) { return ReplaceAll(unicode::Lowercased(url::Host(url).value_or("")), "www.", ""); }

bool IsHex(char c) { return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'); }

// What RFC 3986 lets a path, query or fragment hold as it is: unreserved, sub-delims, ":@/?",
// and a % that starts an escape. Everything else NSURL (macOS 14) percent-encodes.
bool Allowed(std::string_view text, size_t at) {
    const unsigned char c = static_cast<unsigned char>(text[at]);
    if (c >= 0x80 || c <= 0x20 || c == 0x7F) return false;
    switch (c) {
    case '"': case '<': case '>': case '\\': case '^': case '`': case '{': case '|': case '}': case '[': case ']': return false;
    case '%': return at + 2 < text.size() && IsHex(text[at + 1]) && IsHex(text[at + 2]);
    default: return true;
    }
}

// Where the authority ends: the path, query and fragment follow.
size_t AfterAuthority(std::string_view url) {
    const size_t colon = url.find(':');
    if (colon == std::string_view::npos) return 0;
    size_t at = colon + 1;
    if (url.substr(at, 2) != "//") return at;
    const size_t end = url.find_first_of("/?#", at + 2);
    return end == std::string_view::npos ? url.size() : end;
}

// A shard's entry by key, with no std::string made where the library can look up by string_view.
template <class Map>
auto Lookup(Map& map, std::string_view key) {
#if defined(__cpp_lib_generic_unordered_lookup)
    return map.find(key);
#else
    return map.find(std::string(key));
#endif
}

}  // namespace

std::string HistoryEntry::DisplayTitle() const {
    if (!title.empty()) return title;
    return url::Host(url).value_or(url);
}

// MARK: History

bool History::Records(std::string_view url) {
    // URL.scheme as written: "HTTPS://" isn't recorded on the Mac either.
    const bool web = url.starts_with("https:") || url.starts_with("http:");
    return web && url::HasValidAuthority(url);
}

std::string History::Normalized(std::string_view url) {
    std::string scratch;
    return std::string(Key(url, scratch));
}

std::string_view History::Key(std::string_view url, std::string& out) {
    static constexpr char kHexDigits[] = "0123456789ABCDEF";
    // The path, the query and the fragment, each on its own, as NSURL (macOS 14 and later) reads
    // them: a part that holds anything it may not is percent-encoded whole, its % signs too, as
    // if nothing in it had been escaped (macOS 15.7.4 makes "caf%C3%A9/café" into
    // "caf%25C3%25A9/caf%C3%A9"); a part that's valid is left as it is.
    struct Part {
        size_t begin, end;
        bool fragment;
    };
    const size_t from = AfterAuthority(url);
    const size_t hash = url.find('#', from);
    const size_t beforeFragment = hash == std::string_view::npos ? url.size() : hash;
    const size_t question = url.substr(0, beforeFragment).find('?', from);
    const size_t pathEnd = question == std::string_view::npos ? beforeFragment : question;
    Part parts[3];
    size_t count = 0;
    parts[count++] = {from, pathEnd, false};
    if (question != std::string_view::npos) parts[count++] = {question + 1, beforeFragment, false};
    if (hash != std::string_view::npos) parts[count++] = {hash + 1, url.size(), true};
    const auto invalid = [&](const Part& part) {
        for (size_t i = part.begin; i < part.end; ++i) {
            if ((part.fragment && url[i] == '#') || !Allowed(url.substr(0, part.end), i)) return true;
        }
        return false;
    };
    bool any = false;
    bool encode[3] = {false, false, false};
    for (size_t k = 0; k < count; ++k) any |= (encode[k] = invalid(parts[k]));
    if (!any) return url;
    out.assign(url.substr(0, from));
    size_t at = from;
    for (size_t k = 0; k < count; ++k) {
        out.append(url.substr(at, parts[k].begin - at));  // the ? or # before it
        if (!encode[k]) {
            out.append(url.substr(parts[k].begin, parts[k].end - parts[k].begin));
        } else {
            for (size_t i = parts[k].begin; i < parts[k].end; ++i) {
                const unsigned char c = static_cast<unsigned char>(url[i]);
                if (c == '%' || c == '#' || !Allowed(url, i)) {
                    out += '%';
                    out += kHexDigits[c >> 4];
                    out += kHexDigits[c & 0xF];
                } else {
                    out += static_cast<char>(c);
                }
            }
        }
        at = parts[k].end;
    }
    return out;
}

size_t History::ShardOf(std::string_view url) {
    // FNV-1a: the same shard on every platform (std::hash isn't), so a run is reproducible.
    uint64_t hash = 14695981039346656037ull;
    for (char c : url) {
        hash ^= static_cast<unsigned char>(c);
        hash *= 1099511628211ull;
    }
    return static_cast<size_t>(hash % kShards);
}

void History::Index(std::string_view url, Item& item) {
    std::string folded = FoldedBytes(item.title);
    item.titleEnd = static_cast<uint32_t>(folded.size());
    folded += '\0';
    folded += FoldedBytes(url);
    item.urlEnd = static_cast<uint32_t>(folded.size());
    const std::string key = HostKey(url);
    item.hostAt = kNoHost;
    item.hostLength = 0;
    if (size_t at = url.find(key); at != std::string_view::npos && at < kNoHost && key.size() < kNoHost) {
        item.hostAt = static_cast<uint16_t>(at);
        item.hostLength = static_cast<uint16_t>(key.size());
    }
    // What Search finds in the host is almost always in the URL already.
    const std::string host = FoldedBytes(key);
    if (std::string_view(folded).substr(item.titleEnd + 1).find(host) == std::string_view::npos) {
        folded += '\0';
        folded += host;
    }
    item.textEnd = static_cast<uint32_t>(folded.size());
    if (!text_match::IsAscii(item.title)) {
        // Where the folded title's Characters start, by byte (and its end, always one).
        const std::u32string codePoints = unicode::Folded(item.title);
        const std::vector<bool> starts = unicode::CharacterStarts(codePoints);
        std::string bitmap((item.titleEnd + 1 + 7) / 8, '\0');
        size_t at = 0;
        for (size_t i = 0; i <= codePoints.size(); ++i) {
            if (starts[i]) bitmap[at / 8] = static_cast<char>(bitmap[at / 8] | (1 << (at % 8)));
            if (i < codePoints.size()) at += unicode::Encode(std::u32string_view(&codePoints[i], 1)).size();
        }
        folded += bitmap;
    }
    folded.shrink_to_fit();
    item.folded = std::move(folded);
}

HistoryEntry History::EntryOf(const std::string& url, const Item& item) { return {url, item.title, item.lastVisit, item.visitCount}; }

const History::Item* History::FindItem(std::string_view url) const {
    const auto& shard = shards_[ShardOf(url)];
    if (!shard) return nullptr;
    auto it = Lookup(*shard, url);
    return it == shard->end() ? nullptr : &it->second;
}

History::Shard& History::Writable(size_t shard) {
    auto& slot = shards_[shard];
    if (!slot) {
        slot = std::make_shared<Shard>();
    } else if (slot.use_count() > 1) {
        slot = std::make_shared<Shard>(*slot);  // a snapshot holds it: copy this shard only
    } else {
        // The writer's thread may have just let its snapshot go. use_count isn't an acquire load
        // (relaxed on libstdc++, a plain read of the count on MSVC), so this fence orders the
        // thread's reads of the shard, released by its decrement, before the writes here.
        std::atomic_thread_fence(std::memory_order_acquire);
    }
    return *slot;
}

History::Item* History::FindWritable(std::string_view url) {
    const size_t shard = ShardOf(url);
    if (!shards_[shard]) return nullptr;
    // Looked up first, so a lookup that misses never copies a shard a snapshot holds.
    if (Lookup(*shards_[shard], url) == shards_[shard]->end()) return nullptr;
    Shard& writable = Writable(shard);
    return &Lookup(writable, url)->second;
}

void History::Insert(const HistoryEntry& entry) {
    Shard& shard = Writable(ShardOf(entry.url));
    Item item;
    item.title = entry.title;
    item.lastVisit = entry.lastVisit;
    item.visitCount = entry.visitCount;
    Index(entry.url, item);
    auto [it, inserted] = shard.insert_or_assign(entry.url, std::move(item));
    (void)it;
    if (inserted) ++count_;
}

bool History::SharesShards() const {
    return std::any_of(shards_.begin(), shards_.end(), [](const auto& shard) { return shard && shard.use_count() > 1; });
}

bool History::RecordVisit(std::string_view raw, std::string_view title, Timestamp at) {
    if (!Records(raw)) return false;
    std::string scratch;
    const std::string_view url = Key(raw, scratch);
    if (Item* item = FindWritable(url)) {
        ++item->visitCount;
        item->lastVisit = at;
        if (!title.empty() && item->title != title) {
            item->title = std::string(title);
            Index(url, *item);
        }
    } else {
        Insert({std::string(url), std::string(title), at, 1});
    }
    // Past the cap the oldest tenth goes, as the Mac's prune(to: maxEntries * 9 / 10). Not while
    // the writer holds a snapshot: erasing then would copy every shard on the UI thread. The
    // next visit after the writer has let it go (milliseconds later) prunes instead.
    if (count_ > kMaxEntries && !SharesShards()) Prune(kMaxEntries * 9 / 10);
    return true;
}

bool History::UpdatesTitle(std::string_view url, std::string_view title) const {
    if (title.empty()) return false;
    std::string scratch;
    const Item* item = FindItem(Key(url, scratch));
    return item && item->title != title;
}

bool History::UpdateTitle(std::string_view raw, std::string_view title) {
    if (title.empty()) return false;
    std::string scratch;
    const std::string_view url = Key(raw, scratch);
    const Item* found = FindItem(url);
    if (!found || found->title == title) return false;
    Item* item = FindWritable(url);
    item->title = std::string(title);
    Index(url, *item);
    return true;
}

void History::RemoveAll() {
    shards_ = {};
    count_ = 0;
}

size_t History::Merge(const std::vector<HistoryEntry>& imported) {
    size_t added = 0;
    for (const HistoryEntry& raw : imported) {
        if (!Records(raw.url)) continue;
        HistoryEntry entry = raw;
        entry.url = Normalized(raw.url);
        Item* existing = FindWritable(entry.url);
        if (!existing) {
            Insert(entry);
            ++added;
            continue;
        }
        existing->visitCount = std::max(existing->visitCount, entry.visitCount);
        bool retitled = false;
        if (entry.lastVisit > existing->lastVisit) {
            existing->lastVisit = entry.lastVisit;
            if (!entry.title.empty() && existing->title != entry.title) {
                existing->title = entry.title;
                retitled = true;
            }
        }
        if (existing->title.empty() && !entry.title.empty()) {
            existing->title = entry.title;
            retitled = true;
        }
        if (retitled) Index(entry.url, *existing);
    }
    if (count_ > kMaxEntries) Prune(kMaxEntries);
    return added;
}

Timestamp History::ChromiumDate(int64_t microseconds) {
    return FromUnixTime(static_cast<double>(microseconds) / 1'000'000 - 11'644'473'600);
}

void History::Remove(const std::vector<std::string>& urls) {
    for (const std::string& raw : urls) {
        std::string scratch;
        const std::string_view url = Key(raw, scratch);
        const size_t shard = ShardOf(url);
        if (!shards_[shard] || Lookup(*shards_[shard], url) == shards_[shard]->end()) continue;
        Shard& writable = Writable(shard);
        writable.erase(Lookup(writable, url));
        --count_;
    }
}

void History::TrimToCap() {
    if (count_ > kMaxEntries) Prune(kMaxEntries);
}

void History::RemoveVisits(std::optional<Timestamp> since) {
    if (!since) return RemoveAll();
    std::vector<std::string> urls;
    ForEach([&](const HistoryEntry& entry) {
        if (entry.lastVisit >= *since) urls.push_back(entry.url);
    });
    Remove(urls);
}

void History::Prune(size_t count) {
    struct Ref {
        Timestamp lastVisit;
        const std::string* url;
        const Item* item;
    };
    std::vector<Ref> all;
    all.reserve(count_);
    for (const auto& shard : shards_) {
        if (!shard) continue;
        for (const auto& [url, item] : *shard) all.push_back({item.lastVisit, &url, &item});
    }
    if (all.size() <= count) return;
    // The newest `count`; the Mac's sort leaves equal visits in no set order, Kite keeps the
    // lower URL, so a prune is the same every time. The rest are erased where they are (a
    // tenth of the history, on the UI thread), not the kept ones copied.
    std::nth_element(all.begin(), all.begin() + static_cast<std::ptrdiff_t>(count), all.end(), [](const Ref& a, const Ref& b) {
        return a.lastVisit != b.lastVisit ? a.lastVisit > b.lastVisit : *a.url < *b.url;
    });
    std::vector<std::string> dropped;
    dropped.reserve(all.size() - count);
    for (size_t i = count; i < all.size(); ++i) dropped.push_back(*all[i].url);
    all.clear();
    Remove(dropped);
}

std::optional<HistoryEntry> History::Find(std::string_view raw) const {
    std::string scratch;
    const std::string_view url = Key(raw, scratch);
    const Item* item = FindItem(url);
    if (!item) return std::nullopt;
    return EntryOf(std::string(url), *item);
}

void History::ForEach(const std::function<void(const HistoryEntry&)>& body) const {
    for (const auto& shard : shards_) {
        if (!shard) continue;
        for (const auto& [url, item] : *shard) body(EntryOf(url, item));
    }
}

std::vector<HistoryEntry> History::Entries() const {
    std::vector<HistoryEntry> out;
    out.reserve(count_);
    ForEach([&](const HistoryEntry& entry) { out.push_back(entry); });
    std::sort(out.begin(), out.end(), [](const HistoryEntry& a, const HistoryEntry& b) { return a.url < b.url; });
    return out;
}

bool History::operator==(const History& other) const {
    if (count_ != other.count_) return false;
    for (size_t s = 0; s < kShards; ++s) {
        const auto& mine = shards_[s];
        const auto& theirs = other.shards_[s];
        if (mine == theirs) continue;
        const size_t mineSize = mine ? mine->size() : 0;
        const size_t theirSize = theirs ? theirs->size() : 0;
        if (mineSize != theirSize) return false;
        if (!mineSize) continue;
        for (const auto& [url, item] : *mine) {
            auto it = theirs->find(url);
            if (it == theirs->end() || it->second.title != item.title || it->second.lastVisit != item.lastVisit ||
                it->second.visitCount != item.visitCount) {
                return false;
            }
        }
    }
    return true;
}

struct History::Needle {
    explicit Needle(std::string_view lowered);
    Query query;  // for the text that isn't indexed (a URL or host that isn't ASCII)
    std::string bytes;
    std::vector<uint32_t> offsets;  // each code point's first byte
    std::vector<bool> starts;       // whether each code point starts a Character, and the end
};

History::Needle::Needle(std::string_view lowered) : query(lowered) {
    const std::u32string& text = query.folded.text;
    for (size_t i = 0; i < text.size(); ++i) {
        offsets.push_back(static_cast<uint32_t>(bytes.size()));
        bytes += unicode::Encode(std::u32string_view(&text[i], 1));
    }
    starts = query.folded.starts;
}

namespace {

// A title, URL or host as the index keeps it (folded: lowercased, decomposed, UTF-8), with
// where its Characters start: the bitmap's bits for a title that isn't ASCII, else every byte
// but a LF after a CR. Matching here is text_match::Field's, without folding the text again.
struct FoldedText {
    std::string_view bytes;
    const unsigned char* bitmap = nullptr;

    bool StartAt(size_t i) const {
        if (i == 0 || i >= bytes.size()) return true;
        if (!bitmap) return !(bytes[i - 1] == '\r' && bytes[i] == '\n');
        return (bitmap[i / 8] >> (i % 8)) & 1;
    }

    char32_t CodePointAt(size_t i) const {
        const auto byte = [&](size_t k) { return k < bytes.size() ? static_cast<unsigned char>(bytes[k]) : 0u; };
        const unsigned b = byte(i);
        if (b < 0x80) return b;
        if (b >= 0xF0) return ((b & 0x07) << 18) | ((byte(i + 1) & 0x3F) << 12) | ((byte(i + 2) & 0x3F) << 6) | (byte(i + 3) & 0x3F);
        if (b >= 0xE0) return ((b & 0x0F) << 12) | ((byte(i + 1) & 0x3F) << 6) | (byte(i + 2) & 0x3F);
        return ((b & 0x1F) << 6) | (byte(i + 1) & 0x3F);
    }

    bool IsWord(size_t i) const {
        const char32_t c = CodePointAt(i);
        return unicode::IsLetter(c) || unicode::IsNumber(c);
    }

    // Folded::IsWordStart: a Character starting with a letter or number, after one that doesn't.
    bool IsWordStart(size_t at) const {
        if (!StartAt(at) || !IsWord(at)) return false;
        if (at == 0) return true;
        size_t previous = at - 1;
        while (previous > 0 && !StartAt(previous)) --previous;
        return !IsWord(previous);
    }

    // Folded::MatchesAt with both ends on Character boundaries. UTF-8 only matches at a code
    // point's first byte, so comparing the bytes compares the code points.
    template <class Needle>
    bool MatchesAt(size_t at, const Needle& needle) const {
        if (at + needle.bytes.size() > bytes.size() || bytes.compare(at, needle.bytes.size(), needle.bytes) != 0) return false;
        for (size_t k = 0; k < needle.offsets.size(); ++k) {
            if (StartAt(at + needle.offsets[k]) != needle.starts[k]) return false;
        }
        return StartAt(at + needle.bytes.size());
    }

    template <class Needle>
    bool HasPrefix(const Needle& needle) const {
        return MatchesAt(0, needle);
    }

    template <class Needle>
    bool Contains(const Needle& needle, bool wordStart = false) const {
        for (size_t at = bytes.find(needle.bytes); at != std::string_view::npos; at = bytes.find(needle.bytes, at + 1)) {
            if (MatchesAt(at, needle) && (!wordStart || IsWordStart(at))) return true;
        }
        return false;
    }
};

}  // namespace

std::optional<int> History::Score(std::string_view q, const HistoryEntry& entry) {
    Item item;
    item.title = entry.title;
    Index(entry.url, item);
    return ScoreItem(Needle(q), entry.url, item);
}

std::optional<int> History::ScoreItem(const Needle& needle, std::string_view url, const Item& item) {
    const std::string_view folded(item.folded);
    // The host: in place in the URL when it's spelled there as compared (lowercase ASCII, the
    // usual case), else made again.
    if (item.hostAt != kNoHost && text_match::IsAscii(url.substr(item.hostAt, item.hostLength))) {
        if (FoldedText{url.substr(item.hostAt, item.hostLength)}.HasPrefix(needle)) return 100;
    } else if (Field(HostKey(url)).HasPrefix(needle.query)) {
        return 100;
    }
    const unsigned char* bitmap =
        item.textEnd < folded.size() ? reinterpret_cast<const unsigned char*>(folded.data()) + item.textEnd : nullptr;
    const FoldedText title{folded.substr(0, item.titleEnd), bitmap};
    // Each test needs what's typed somewhere in the title: one byte search decides all three.
    if (title.bytes.find(needle.bytes) != std::string_view::npos) {
        if (title.HasPrefix(needle)) return 90;
        if (needle.query.allWordCharacters && title.Contains(needle, true)) return 75;
        if (title.Contains(needle)) return 55;
    }
    if (text_match::IsAscii(url)) {
        if (FoldedText{folded.substr(item.titleEnd + 1, item.urlEnd - item.titleEnd - 1)}.Contains(needle)) return 40;
    } else if (Field(url).Contains(needle.query)) {
        return 40;
    }
    return std::nullopt;
}

std::vector<HistoryEntry> History::Search(std::string_view query, size_t limit, Timestamp now) const {
    const std::string q = TrimmedLowercase(query);
    if (q.empty() || limit == 0) return {};
    const Needle typed(q);
    const std::string_view needle = typed.bytes;
    // A NUL typed would match across an entry's folded parts: every entry is scored then.
    const bool prefilter = needle.find('\0') == std::string_view::npos;
    struct Scored {
        double score;
        Timestamp lastVisit;
        const std::string* url;
        const Item* item;
    };
    // Better first: score, then the later visit, then the lower URL.
    const auto better = [](const Scored& a, const Scored& b) {
        if (a.score != b.score) return a.score > b.score;
        if (a.lastVisit != b.lastVisit) return a.lastVisit > b.lastVisit;
        return *a.url < *b.url;
    };
    // The best `limit` so far, as a heap whose top is the worst of them.
    std::vector<Scored> best;
    best.reserve(limit);
    for (const auto& shard : shards_) {
        if (!shard) continue;
        for (const auto& [url, item] : *shard) {
            if (prefilter && std::string_view(item.folded).substr(0, item.textEnd).find(needle) == std::string_view::npos) continue;
            auto match = ScoreItem(typed, url, item);
            if (!match) continue;
            const double days = std::max(0.0, now - item.lastVisit) / kDay;
            const double visits = static_cast<double>(std::max<int64_t>(0, item.visitCount));
            const double frecency = std::log2(visits + 1) * 8 - std::min(days, 90.0) / 3;
            const Scored candidate{static_cast<double>(*match) + frecency, item.lastVisit, &url, &item};
            if (best.size() < limit) {
                best.push_back(candidate);
                std::push_heap(best.begin(), best.end(), better);
            } else if (better(candidate, best.front())) {
                std::pop_heap(best.begin(), best.end(), better);
                best.back() = candidate;
                std::push_heap(best.begin(), best.end(), better);
            }
        }
    }
    std::sort_heap(best.begin(), best.end(), better);
    const size_t kept = best.size();
    const std::vector<Scored>& scored = best;
    std::vector<HistoryEntry> out;
    out.reserve(kept);
    for (size_t i = 0; i < kept; ++i) out.push_back(EntryOf(*scored[i].url, *scored[i].item));
    return out;
}

// MARK: The file

std::string History::EncodeFile() const {
    std::vector<std::pair<const std::string*, const Item*>> sorted;
    sorted.reserve(count_);
    for (const auto& shard : shards_) {
        if (!shard) continue;
        for (const auto& [url, item] : *shard) sorted.emplace_back(&url, &item);
    }
    std::sort(sorted.begin(), sorted.end(), [](const auto& a, const auto& b) { return *a.first < *b.first; });
    // Members sorted by key, as json::Write writes them.
    std::string out = R"({"history":{"entries":{)";
    for (size_t i = 0; i < sorted.size(); ++i) {
        const auto& [url, item] = sorted[i];
        if (i) out += ',';
        json::AppendString(out, *url);
        out += R"(:{"lastVisit":)";
        json::Append(out, json::Value(item->lastVisit));
        out += R"(,"title":)";
        json::AppendString(out, item->title);
        out += R"(,"url":)";
        json::AppendString(out, *url);
        out += R"(,"visitCount":)";
        json::Append(out, json::Value(item->visitCount));
        out += '}';
    }
    out += R"(}},"version":)" + std::to_string(kCurrentVersion) + "}";
    return out;
}

std::variant<History, std::string> History::DecodeFile(std::string_view text) {
    auto parsed = json::Parse(text);
    if (auto* error = std::get_if<json::ParseError>(&parsed)) {
        return "not JSON (" + error->message + " at byte " + std::to_string(error->offset) + ")";
    }
    const json::Value& root = std::get<json::Value>(parsed);
    if (!root.IsObject()) return std::string("not a Kite history file");
    const json::Value* version = root.Find("version");
    if (!version || !version->AsInt()) return std::string("no version");
    const json::Value* history = root.Find("history");
    const json::Value* entries = history ? history->Find("entries") : nullptr;
    const json::Object* object = entries ? entries->AsObject() : nullptr;
    if (!object) return std::string("no history entries");
    History out;
    for (const auto& [key, value] : *object) {
        const json::Value* url = value.Find("url");
        const json::Value* title = value.Find("title");
        const json::Value* lastVisit = value.Find("lastVisit");
        const json::Value* visitCount = value.Find("visitCount");
        // As the Mac's decoder: every member, of its type, or the file doesn't read.
        if (!url || !url->AsString() || url->AsString()->empty() || !title || !title->AsString() || !lastVisit ||
            !lastVisit->AsNumber() || !visitCount || !visitCount->AsInt()) {
            return "an unreadable entry for " + key;
        }
        // Keyed as the file keys it: the Mac's key is the URL's absoluteString, which it also
        // writes as the entry's url.
        out.Insert({key, *title->AsString(), *lastVisit->AsNumber(), *visitCount->AsInt()});
    }
    return out;
}

HistoryFile::LoadResult HistoryFile::Load(Unreadable unreadable) const {
    std::error_code error;
    const bool exists = fs::exists(file_, error);
    if (error) return Error{"couldn't check " + store_file::PathText(file_) + ": " + error.message(), std::nullopt};
    if (!exists) return Missing{};
    if (!fs::is_regular_file(file_, error)) return Error{store_file::PathText(file_) + " isn't a file", std::nullopt};
    bool tooLarge = false;
    auto text = store_file::Read(file_, store_file::kMaxHistoryReadBytes, &tooLarge);
    // Left where it is: it may be history, just more than Kite reads.
    if (tooLarge) return Error{store_file::PathText(file_) + " is over 64 MB", std::nullopt};
    if (!text) return Error{"couldn't read " + store_file::PathText(file_), std::nullopt};
    auto decoded = History::DecodeFile(*text);
    if (auto* history = std::get_if<History>(&decoded)) return std::move(*history);
    const std::string problem = std::get<std::string>(decoded);
    if (unreadable == Unreadable::Leave) return Error{problem, std::nullopt};
    // Moved aside as the Mac's HistoryFile does, never over an earlier one.
    const auto seconds = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    fs::path backup;
    for (int attempt = 0; attempt < 100; ++attempt) {
        fs::path name = file_.stem();
        name += ".corrupt-" + std::to_string(seconds) + (attempt ? "-" + std::to_string(attempt) : "") + ".json";
        backup = file_.parent_path() / name;
        if (!fs::exists(backup, error) && !error) break;
    }
    if (fs::exists(backup, error)) return Error{problem, std::nullopt};
    fs::rename(file_, backup, error);
    if (error) return Error{problem, std::nullopt};
    return Error{problem, backup};
}

bool HistoryFile::MaySave(const LoadResult& result) {
    const Error* error = std::get_if<Error>(&result);
    return !error || error->quarantinedTo.has_value();
}

std::string HistoryFile::Write(std::string_view bytes) const {
    std::error_code error;
    fs::create_directories(file_.parent_path(), error);
    if (error) return "couldn't create " + store_file::PathText(file_.parent_path()) + ": " + error.message();
    return store_file::WriteAtomically(file_, bytes);
}

std::string HistoryFile::Save(const History& history) const { return Write(history.EncodeFile()); }

}  // namespace kite

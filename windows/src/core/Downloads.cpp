// Port of KiteCore's Downloads.swift and its neighbours; see Downloads.h.

#include "core/Downloads.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <iterator>
#include <system_error>

#include "core/StoreFile.h"
#include "core/Unicode.h"
#include "core/Url.h"
#include "core/Uuid.h"

namespace kite {

using json::Array;
using json::Object;
using json::Value;

namespace {

std::string AsciiLower(std::string_view text) {
    std::string out(text);
    for (char& c : out) {
        if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    }
    return out;
}

bool IsSeparator(char c) { return c == '/' || c == '\\'; }

// NSString's lastPathComponent, for '/' and Windows' '\': the part after the last separator,
// trailing separators aside.
std::string LastPathComponent(std::string_view path) {
    size_t end = path.size();
    while (end > 1 && IsSeparator(path[end - 1])) --end;
    std::string_view trimmed = path.substr(0, end);
    size_t start = trimmed.size();
    while (start > 0 && !IsSeparator(trimmed[start - 1])) --start;
    std::string_view last = trimmed.substr(start);
    return std::string(last.empty() ? trimmed : last);
}

int HexValue(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::string PercentDecoded(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '%' && i + 2 < text.size()) {
            const int high = HexValue(text[i + 1]);
            const int low = HexValue(text[i + 2]);
            if (high >= 0 && low >= 0) {
                out += static_cast<char>(high * 16 + low);
                i += 2;
                continue;
            }
        }
        out += text[i];
    }
    return out;
}

// URL.lastPathComponent: the path's last segment, decoded; "/" for a root path, "" for none.
std::string UrlLastPathComponent(std::string_view url) {
    std::string_view rest = url;
    if (url::Scheme(url)) rest = rest.substr(rest.find(':') + 1);
    if (rest.starts_with("//")) {
        rest = rest.substr(2);
        const size_t slash = rest.find_first_of("/?#");
        rest = slash == std::string_view::npos ? std::string_view() : rest.substr(slash);
    }
    const size_t query = rest.find_first_of("?#");
    std::string_view path = query == std::string_view::npos ? rest : rest.substr(0, query);
    if (path.empty()) return "";
    size_t end = path.size();
    while (end > 1 && path[end - 1] == '/') --end;
    path = path.substr(0, end);
    if (path == "/") return "/";
    const size_t slash = path.rfind('/');
    const std::string_view last = slash == std::string_view::npos ? path : path.substr(slash + 1);
    // Escapes that don't decode to UTF-8 stay as they are, as Foundation leaves them.
    std::string decoded = PercentDecoded(last);
    const std::vector<char32_t> points = unicode::Decode(decoded);
    return unicode::Encode(std::u32string_view(points.data(), points.size())) == decoded ? decoded : std::string(last);
}

// NSString's pathExtension and stringByDeletingPathExtension: a name starting with its only
// dot (".bashrc") has none.
std::pair<std::string_view, std::string_view> SplitExtension(std::string_view name) {
    const size_t dot = name.rfind('.');
    if (dot == std::string_view::npos || dot == 0 || dot + 1 == name.size()) return {name, {}};
    return {name.substr(0, dot), name.substr(dot + 1)};
}

std::optional<int64_t> IntMember(const Value& object, std::string_view key, bool& invalid) {
    const Value* v = object.Find(key);
    if (!v || v->IsNull()) return std::nullopt;
    auto number = v->AsInt();
    if (!number) invalid = true;
    return number;
}

}  // namespace

// MARK: DownloadItem

std::string_view RawValue(DownloadState state) {
    switch (state) {
    case DownloadState::InProgress: return "inProgress";
    case DownloadState::Complete: return "complete";
    case DownloadState::Canceled: return "canceled";
    case DownloadState::Interrupted: return "interrupted";
    }
    return "inProgress";
}

std::optional<DownloadState> DownloadStateFromRaw(std::string_view raw) {
    for (DownloadState state : {DownloadState::InProgress, DownloadState::Complete, DownloadState::Canceled, DownloadState::Interrupted}) {
        if (RawValue(state) == raw) return state;
    }
    return std::nullopt;
}

std::string DownloadItem::FileName() const {
    if (!path.empty()) return LastPathComponent(path);
    return UrlLastPathComponent(url);
}

std::optional<double> DownloadItem::Fraction() const {
    if (totalBytes <= 0) return state == DownloadState::Complete ? std::optional<double>(1.0) : std::nullopt;
    return std::min(1.0, std::max(0.0, static_cast<double>(receivedBytes) / static_cast<double>(totalBytes)));
}

std::optional<std::string> DownloadItem::SourceHost() const {
    auto host = url::Host(url);
    if (!host || host->empty()) return std::nullopt;
    if (host->starts_with("www.")) return host->substr(4);
    return host;
}

Value Encode(const DownloadItem& item) {
    Object o{{"id", item.id},
             {"isIncognito", item.isIncognito},
             {"url", item.url},
             {"path", item.path},
             {"state", std::string(RawValue(item.state))},
             {"receivedBytes", item.receivedBytes},
             {"totalBytes", item.totalBytes},
             {"speed", item.speed},
             {"startedAt", item.startedAt}};
    // Swift's synthesized encoder leaves out an optional that has no value.
    if (item.engineID) o.emplace("engineID", *item.engineID);
    if (item.engineContext) o.emplace("engineContext", *item.engineContext);
    return Value(std::move(o));
}

std::optional<DownloadItem> DecodeDownloadItem(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    DownloadItem item;
    bool invalid = false;
    const Value* id = v.Find("id");
    auto normalized = id && id->AsString() ? NormalizeUuid(*id->AsString()) : std::nullopt;
    if (!normalized) return std::nullopt;
    item.id = *normalized;
    item.engineID = IntMember(v, "engineID", invalid);
    if (const Value* context = v.Find("engineContext"); context && !context->IsNull()) {
        if (!context->AsString()) return std::nullopt;
        item.engineContext = *context->AsString();
    }
    if (const Value* incognito = v.Find("isIncognito"); incognito && !incognito->IsNull()) {
        if (!incognito->AsBool()) return std::nullopt;
        item.isIncognito = *incognito->AsBool();
    }
    const Value* url = v.Find("url");
    const Value* path = v.Find("path");
    const Value* state = v.Find("state");
    if (!url || !url->AsString() || !path || !path->AsString() || !state || !state->AsString()) return std::nullopt;
    auto parsedState = DownloadStateFromRaw(*state->AsString());
    auto received = IntMember(v, "receivedBytes", invalid);
    auto total = IntMember(v, "totalBytes", invalid);
    auto speed = IntMember(v, "speed", invalid);
    const Value* started = v.Find("startedAt");
    if (invalid || !parsedState || !received || !total || !started || !started->AsNumber()) return std::nullopt;
    item.url = *url->AsString();
    item.path = *path->AsString();
    item.state = *parsedState;
    item.receivedBytes = *received;
    item.totalBytes = *total;
    item.speed = speed.value_or(0);
    item.startedAt = *started->AsNumber();
    return item;
}

// MARK: DownloadUpdate

std::optional<DownloadUpdate> DownloadUpdate::FromInfo(const Value& info) {
    // NSNumber's intValue and int64Value: any number, truncated; a member of another type is
    // as good as missing (the Mac's `as? NSNumber` casts).
    const auto number = [&](std::string_view key) -> std::optional<int64_t> {
        const Value* v = info.Find(key);
        auto n = v ? v->AsNumber() : std::nullopt;
        if (!n || !std::isfinite(*n)) return std::nullopt;
        return static_cast<int64_t>(*n);
    };
    const auto text = [&](std::string_view key) -> std::optional<std::string> {
        const Value* v = info.Find(key);
        return v && v->AsString() ? std::optional<std::string>(*v->AsString()) : std::nullopt;
    };
    auto id = number("id");
    if (!id) return std::nullopt;
    DownloadUpdate update;
    update.engineID = *id;
    update.engineContext = text("context").value_or("");
    const Value* incognito = info.Find("incognito");
    update.isIncognito = incognito && incognito->AsBool().value_or(incognito->AsNumber().value_or(0) != 0);
    update.profileDirectory = text("profileDirectory");
    update.url = text("url").value_or("");
    update.path = text("path").value_or("");
    update.state = StateNamed(text("state").value_or(""));
    update.receivedBytes = number("receivedBytes").value_or(0);
    update.totalBytes = number("totalBytes").value_or(-1);
    update.speed = number("speed").value_or(0);
    return update;
}

Value DownloadUpdate::Info() const {
    Object o{{"id", engineID},
             {"context", engineContext},
             {"incognito", isIncognito},
             {"url", url},
             {"path", path},
             {"state", std::string(NameOf(state))},
             {"receivedBytes", receivedBytes},
             {"totalBytes", totalBytes},
             {"speed", speed}};
    if (profileDirectory) o.emplace("profileDirectory", *profileDirectory);
    return Value(std::move(o));
}

DownloadState DownloadUpdate::StateNamed(std::string_view name) {
    if (name == "complete") return DownloadState::Complete;
    if (name == "canceled") return DownloadState::Canceled;
    if (name == "interrupted") return DownloadState::Interrupted;
    return DownloadState::InProgress;
}

std::string_view DownloadUpdate::NameOf(DownloadState state) {
    switch (state) {
    case DownloadState::Complete: return "complete";
    case DownloadState::Canceled: return "canceled";
    case DownloadState::Interrupted: return "interrupted";
    case DownloadState::InProgress: return "in-progress";
    }
    return "in-progress";
}

// MARK: DownloadList

const DownloadItem* DownloadList::Item(int64_t engineID, std::string_view context) const {
    for (const DownloadItem& item : items_) {
        if (item.engineID == engineID && item.engineContext && *item.engineContext == context) return &item;
    }
    return nullptr;
}

const DownloadItem* DownloadList::Find(const std::string& id) const {
    for (const DownloadItem& item : items_) {
        if (item.id == id) return &item;
    }
    return nullptr;
}

DownloadList::Applied DownloadList::Apply(const DownloadUpdate& update, Timestamp now) {
    const bool live = update.state == DownloadState::InProgress;
    for (DownloadItem& item : items_) {
        if (item.engineID != update.engineID || !item.engineContext || *item.engineContext != update.engineContext) continue;
        if (!update.url.empty()) item.url = update.url;
        if (!update.path.empty()) item.path = update.path;
        item.state = update.state;
        item.receivedBytes = update.receivedBytes;
        item.totalBytes = update.totalBytes;
        item.speed = live ? update.speed : 0;
        return {item, false};
    }
    DownloadItem item;
    item.id = NewUuid();
    item.engineID = update.engineID;
    item.engineContext = update.engineContext;
    item.isIncognito = update.isIncognito;
    item.url = update.url;
    item.path = update.path;
    item.state = update.state;
    item.receivedBytes = update.receivedBytes;
    item.totalBytes = update.totalBytes;
    item.speed = live ? update.speed : 0;
    item.startedAt = now;
    items_.insert(items_.begin(), item);
    Trim();
    return {std::move(item), true};
}

void DownloadList::MarkRestored() {
    for (DownloadItem& item : items_) {
        item.engineID.reset();
        item.engineContext.reset();
        item.speed = 0;
        if (item.state == DownloadState::InProgress) item.state = DownloadState::Interrupted;
    }
}

void DownloadList::RemoveIncognito(std::string_view context) {
    std::erase_if(items_, [&](const DownloadItem& item) { return item.isIncognito && item.engineContext == context; });
}

bool DownloadList::SetPath(const std::string& path, const std::string& id) {
    for (DownloadItem& item : items_) {
        if (item.id != id) continue;
        item.path = path;
        return true;
    }
    return false;
}

void DownloadList::Remove(const std::string& id) {
    std::erase_if(items_, [&](const DownloadItem& item) { return item.id == id; });
}

void DownloadList::ClearFinished() {
    std::erase_if(items_, [](const DownloadItem& item) { return item.state != DownloadState::InProgress; });
}

void DownloadList::RemoveHistory(std::optional<Timestamp> since) {
    std::erase_if(items_, [&](const DownloadItem& item) {
        return item.state != DownloadState::InProgress && (!since || item.startedAt >= *since);
    });
}

void DownloadList::AdoptRestored(const DownloadList& restored) {
    for (const DownloadItem& item : restored.items_) {
        if (!Find(item.id)) items_.push_back(item);
    }
    Trim();
}

std::vector<DownloadItem> DownloadList::Active() const {
    std::vector<DownloadItem> active;
    for (const DownloadItem& item : items_) {
        if (item.state == DownloadState::InProgress) active.push_back(item);
    }
    return active;
}

std::optional<double> DownloadList::ActiveFraction() const {
    int64_t total = 0, received = 0;
    bool sized = false;
    for (const DownloadItem& item : items_) {
        if (item.state != DownloadState::InProgress || item.totalBytes <= 0) continue;
        sized = true;
        total += item.totalBytes;
        received += std::min(item.receivedBytes, item.totalBytes);
    }
    if (!sized) return std::nullopt;
    return static_cast<double>(received) / static_cast<double>(total);
}

void DownloadList::Trim() {
    while (items_.size() > kLimit) {
        auto last = std::find_if(items_.rbegin(), items_.rend(), [](const DownloadItem& item) { return item.state != DownloadState::InProgress; });
        if (last == items_.rend()) break;
        items_.erase(std::next(last).base());
    }
}

Value Encode(const DownloadList& list) {
    Array items;
    for (const DownloadItem& item : list.Items()) {
        if (!item.isIncognito) items.push_back(Encode(item));
    }
    return Value(Object{{"items", Value(std::move(items))}});
}

std::optional<DownloadList> DecodeDownloadList(const Value& v) {
    if (!v.IsObject()) return std::nullopt;
    const Value* items = v.Find("items");
    if (!items || items->IsNull()) return DownloadList();
    if (!items->AsArray()) return std::nullopt;
    std::vector<DownloadItem> decoded;
    for (const Value& element : *items->AsArray()) {
        if (auto item = DecodeDownloadItem(element)) decoded.push_back(std::move(*item));
    }
    return DownloadList(std::move(decoded));
}

// MARK: downloads.json

namespace downloads_file {

namespace {

// The items the file holds, readable or not.
size_t StoredItemCount(const Value& file) {
    const Value* downloads = file.Find("downloads");
    const Value* items = downloads ? downloads->Find("items") : nullptr;
    return items && items->AsArray() ? items->AsArray()->size() : 0;
}

std::optional<DownloadList> DecodeValue(const Value& value) {
    if (!value.IsObject()) return std::nullopt;
    const Value* version = value.Find("version");
    const Value* downloads = value.Find("downloads");
    if (!version || !version->AsInt() || !downloads) return std::nullopt;
    return DecodeDownloadList(*downloads);
}

}  // namespace

std::string Encode(const DownloadList& list) {
    return json::Write(Value(Object{{"version", DownloadList::kCurrentVersion}, {"downloads", kite::Encode(list)}}));
}

std::optional<DownloadList> Decode(std::string_view text) {
    auto parsed = json::Parse(text);
    const Value* value = std::get_if<Value>(&parsed);
    return value ? DecodeValue(*value) : std::nullopt;
}

std::filesystem::path AsidePath(const std::filesystem::path& file) {
    using namespace std::chrono;
    const long long millis = duration_cast<milliseconds>(system_clock::now().time_since_epoch()).count();
    std::filesystem::path aside = file;
    aside.replace_extension();
    aside += ".corrupt-" + std::to_string(millis) + "-" + NewUuid().substr(0, 8) + ".json";
    return aside;
}

std::optional<DownloadList> Read(const std::filesystem::path& file) {
    std::error_code error;
    if (!std::filesystem::exists(file, error) && !error) return DownloadList();
    auto bytes = store_file::Read(file);
    if (!bytes) return std::nullopt;
    auto list = Decode(*bytes);
    if (list) list->MarkRestored();
    return list;
}

std::optional<Loaded> Load(const std::filesystem::path& file) {
    namespace fs = std::filesystem;
    std::error_code error;
    // A file whose existence can't be checked counts as there: it's read, or moved aside.
    if (!fs::exists(file, error) && !error) return Loaded{};
    if (auto bytes = store_file::Read(file)) {
        auto parsed = json::Parse(*bytes);
        if (const Value* value = std::get_if<Value>(&parsed)) {
            if (auto list = DecodeValue(*value)) {
                Loaded loaded;
                loaded.list = std::move(*list);
                loaded.list.MarkRestored();
                const size_t stored = StoredItemCount(*value);
                loaded.dropped = stored > loaded.list.Items().size() ? stored - loaded.list.Items().size() : 0;
                if (loaded.dropped > 0) {
                    const fs::path aside = AsidePath(file);
                    std::error_code copyError;
                    if (fs::copy_file(file, aside, fs::copy_options::none, copyError) && !copyError) loaded.copiedAside = aside;
                    else loaded.canSave = false;
                }
                return loaded;
            }
        }
    }
    const fs::path aside = AsidePath(file);
    std::error_code moveError;
    fs::rename(file, aside, moveError);
    if (moveError) return std::nullopt;
    Loaded loaded;
    loaded.movedAside = aside;
    return loaded;
}

}  // namespace downloads_file

// MARK: DownloadText

namespace download_text {

std::string Size(int64_t bytes) {
    bytes = std::max<int64_t>(0, bytes);
    if (bytes == 0) return "Zero KB";
    if (bytes == 1) return "1 byte";
    if (bytes < 1000) return std::to_string(bytes) + " bytes";
    static const char* const kUnits[] = {"KB", "MB", "GB", "TB", "PB", "EB"};
    static const int kDigits[] = {0, 1, 2, 2, 2, 2};
    double value = static_cast<double>(bytes) / 1000;
    size_t unit = 0;
    for (;;) {
        const double scale = std::pow(10.0, kDigits[unit]);
        const double rounded = std::round(value * scale) / scale;
        if (rounded < 1000 || unit + 1 == std::size(kUnits)) {
            char text[48];
            std::snprintf(text, sizeof text, "%.*f", kDigits[unit], rounded);
            std::string number = text;
            if (number.find('.') != std::string::npos) {
                while (number.back() == '0') number.pop_back();
                if (number.back() == '.') number.pop_back();
            }
            return number + " " + kUnits[unit];
        }
        value /= 1000;
        ++unit;
    }
}

std::string Subtitle(const DownloadItem& item) {
    switch (item.state) {
    case DownloadState::InProgress: {
        std::string text = item.totalBytes > 0 ? Size(item.receivedBytes) + " of " + Size(item.totalBytes) : Size(item.receivedBytes);
        if (item.speed > 0) text += " \xC2\xB7 " + Size(item.speed) + "/s";
        return text;
    }
    case DownloadState::Complete: {
        std::string text = Kind(item.FileName());
        if (item.totalBytes > 0 || item.receivedBytes > 0) {
            text += " \xC2\xB7 " + Size(item.totalBytes > 0 ? item.totalBytes : item.receivedBytes);
        }
        if (auto host = item.SourceHost()) text += " from " + *host;
        return text;
    }
    case DownloadState::Canceled: return "Canceled";
    case DownloadState::Interrupted: return "Failed to Download";
    }
    return {};
}

std::string Kind(std::string_view fileName) {
    const std::string extension = AsciiLower(SplitExtension(fileName).second);
    const auto is = [&](std::initializer_list<std::string_view> list) {
        return std::find(list.begin(), list.end(), extension) != list.end();
    };
    if (extension == "pdf") return "PDF";
    if (is({"dmg", "iso", "img"})) return "Disk Image";
    if (extension == "mov") return "Movie";
    if (is({"mp4", "m4v", "webm", "mkv", "avi"})) return "Video";
    if (is({"png", "jpg", "jpeg", "gif", "heic", "webp", "svg", "tiff", "bmp"})) return "Image";
    if (is({"mp3", "m4a", "wav", "aac", "flac", "ogg", "aiff"})) return "Audio";
    if (extension == "zip") return "ZIP Archive";
    if (is({"tar", "gz", "tgz", "bz2", "xz", "7z", "rar"})) return "Archive";
    return "File";
}

}  // namespace download_text

// MARK: Extension packages, unique names

bool IsExtensionPackage(std::string_view mimeType, std::string_view suggestedName, std::string_view url) {
    if (AsciiLower(mimeType) == "application/x-chrome-extension") return true;
    if (!AsciiLower(suggestedName).ends_with(".crx") || url::Scheme(url) != "https") return false;
    const auto host = url::Host(url);
    if (!host) return false;
    const std::string lower = AsciiLower(*host);
    return lower == "clients2.google.com" || lower == "clients2.googleusercontent.com" || lower.ends_with(".gvt1.com");
}

std::filesystem::path UniqueDownloadPath(std::string_view name, const std::filesystem::path& directory,
                                         const std::function<bool(const std::filesystem::path&)>& taken) {
    std::string file = LastPathComponent(name);
    if (file.empty() || std::all_of(file.begin(), file.end(), IsSeparator) || file == "." || file == "..") file = "download";
    const auto [base, extension] = SplitExtension(file);
    const auto utf8 = [](const std::string& text) { return std::filesystem::path(std::u8string(text.begin(), text.end())); };
    std::filesystem::path candidate = directory / utf8(file);
    for (int n = 2; taken(candidate); ++n) {
        std::string numbered = std::string(base) + " " + std::to_string(n);
        if (!extension.empty()) numbered += "." + std::string(extension);
        candidate = directory / utf8(numbered);
    }
    return candidate;
}

}  // namespace kite

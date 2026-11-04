// Port of KiteCore SessionStore.swift's SessionBackups; see SessionBackups.h.

#include "core/SessionBackups.h"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <set>
#include <system_error>

#include "core/Models.h"
#include "core/SessionStore.h"
#include "core/StoreFile.h"

namespace kite {

namespace fs = std::filesystem;

namespace {

// Days since 1970-01-01 ↔ a proleptic Gregorian date (Howard Hinnant's algorithms), so the
// stamps need no time zone database or locale: UTC by construction.
long long DaysFromCivil(long long y, unsigned m, unsigned d) {
    y -= m <= 2;
    const long long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = static_cast<unsigned>(y - era * 400);
    const unsigned doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + static_cast<long long>(doe) - 719468;
}

void CivilFromDays(long long z, long long& y, unsigned& m, unsigned& d) {
    z += 719468;
    const long long era = (z >= 0 ? z : z - 146096) / 146097;
    const unsigned doe = static_cast<unsigned>(z - era * 146097);
    const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const unsigned mp = (5 * doy + 2) / 153;
    d = doy - (153 * mp + 2) / 5 + 1;
    m = mp < 10 ? mp + 3 : mp - 9;
    y = static_cast<long long>(yoe) + era * 400 + (m <= 2);
}

bool IsLeap(long long y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

unsigned DaysInMonth(long long y, unsigned m) {
    static constexpr unsigned kDays[] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    return m == 2 && IsLeap(y) ? 29 : kDays[m - 1];
}

std::string Pad(long long value, size_t width) {
    std::string text = std::to_string(value);
    return std::string(width > text.size() ? width - text.size() : 0, '0') + text;
}

std::string Utf8Name(const fs::path& path) {
    auto u8 = path.filename().u8string();
    return std::string(u8.begin(), u8.end());
}

// A backup file's name → its date and kind; none for anything else in the folder.
std::optional<SessionBackups::Backup> Parse(const fs::path& file) {
    const std::string name = Utf8Name(file);
    constexpr std::string_view prefix = "session.", suffix = ".json";
    if (!name.starts_with(prefix) || !name.ends_with(suffix) || name.size() < prefix.size() + suffix.size()) return std::nullopt;
    const std::string_view middle = std::string_view(name).substr(prefix.size(), name.size() - prefix.size() - suffix.size());
    // Swift's split(separator: ".", omittingEmptySubsequences: false): one or two parts.
    const size_t dot = middle.find('.');
    const std::string_view stamp = middle.substr(0, dot);
    std::optional<std::string_view> kindText;
    if (dot != std::string_view::npos) {
        kindText = middle.substr(dot + 1);
        if (kindText->find('.') != std::string_view::npos) return std::nullopt;
    }
    auto date = SessionBackups::DateFromStamp(stamp);
    if (!date) return std::nullopt;
    SessionBackups::Kind kind = SessionBackups::Kind::Hourly;
    if (kindText) {
        // An hourly backup has no kind in its name: "session.<stamp>.hourly.json" isn't one.
        if (*kindText == "launch") kind = SessionBackups::Kind::Launch;
        else if (*kindText == "restore") kind = SessionBackups::Kind::Restore;
        else return std::nullopt;
    }
    return SessionBackups::Backup{file, *date, kind};
}

}  // namespace

std::string_view SessionBackups::RawValue(Kind kind) {
    switch (kind) {
    case Kind::Launch: return "launch";
    case Kind::Hourly: return "hourly";
    case Kind::Restore: return "restore";
    }
    return "hourly";
}

double SessionBackups::Now() {
    using namespace std::chrono;
    return duration<double>(system_clock::now().time_since_epoch()).count();
}

std::string SessionBackups::Stamp(double unixSeconds) {
    const long long milliseconds = static_cast<long long>(std::floor(unixSeconds * 1000));
    // Floored, so a date before 1970 still has its milliseconds in 0...999.
    long long seconds = milliseconds / 1000, ms = milliseconds % 1000;
    if (ms < 0) {
        ms += 1000;
        seconds -= 1;
    }
    long long days = seconds / 86400, rest = seconds % 86400;
    if (rest < 0) {
        rest += 86400;
        days -= 1;
    }
    long long year = 0;
    unsigned month = 0, day = 0;
    CivilFromDays(days, year, month, day);
    return Pad(year, 4) + "-" + Pad(month, 2) + "-" + Pad(day, 2) + "-" + Pad(rest / 3600, 2) + "-" + Pad(rest / 60 % 60, 2) + "-" +
           Pad(rest % 60, 2) + "-" + Pad(ms, 3);
}

std::optional<double> SessionBackups::DateFromStamp(std::string_view stamp) {
    static constexpr size_t kWidths[] = {4, 2, 2, 2, 2, 2, 3};
    long long n[7] = {};
    size_t at = 0;
    for (size_t part = 0; part < 7; ++part) {
        if (part > 0) {
            if (at >= stamp.size() || stamp[at] != '-') return std::nullopt;
            ++at;
        }
        if (at + kWidths[part] > stamp.size()) return std::nullopt;
        for (size_t i = 0; i < kWidths[part]; ++i) {
            const char c = stamp[at + i];
            if (c < '0' || c > '9') return std::nullopt;
            n[part] = n[part] * 10 + (c - '0');
        }
        at += kWidths[part];
    }
    if (at != stamp.size()) return std::nullopt;
    // A real date (Calendar's isValidDate): no 13th month, no February 30th, no 24:00.
    if (n[1] < 1 || n[1] > 12 || n[2] < 1 || n[2] > DaysInMonth(n[0], static_cast<unsigned>(n[1])) || n[3] > 23 || n[4] > 59 || n[5] > 59) {
        return std::nullopt;
    }
    const long long days = DaysFromCivil(n[0], static_cast<unsigned>(n[1]), static_cast<unsigned>(n[2]));
    return static_cast<double>(days * 86400 + n[3] * 3600 + n[4] * 60 + n[5]) + static_cast<double>(n[6]) / 1000;
}

std::vector<SessionBackups::Backup> SessionBackups::All() const {
    std::vector<Backup> all;
    std::error_code error;
    for (fs::directory_iterator it(directory_, error), end; !error && it != end; it.increment(error)) {
        if (auto backup = Parse(it->path())) all.push_back(std::move(*backup));
    }
    // Newest first; the same second's backups by name, so the order doesn't depend on the folder's.
    std::sort(all.begin(), all.end(), [](const Backup& a, const Backup& b) {
        if (a.date != b.date) return a.date > b.date;
        return a.file.filename() > b.file.filename();
    });
    return all;
}

std::vector<SessionBackups::Backup> SessionBackups::Ordered(double now) const {
    std::vector<Backup> all = All();
    std::stable_partition(all.begin(), all.end(), [now](const Backup& b) { return b.date <= now; });
    return all;
}

SessionBackups::BackUpResult SessionBackups::BackUp(std::string_view bytes, Kind kind, double now) {
    std::lock_guard lock(mutex_);
    if (kind == Kind::Hourly) {
        if (!newestHourly_) {
            std::optional<double> newest;
            for (const Backup& backup : All()) {
                if (backup.kind == Kind::Hourly && backup.date <= now) {
                    newest = backup.date;
                    break;
                }
            }
            newestHourly_ = newest;
        }
        if (const auto& last = *newestHourly_; last && *last <= now && now - *last < kInterval) return {};
    }
    for (const Backup& backup : Ordered(now)) {
        if (backup.kind != kind) continue;
        if (store_file::Read(backup.file) == std::optional<std::string>(std::string(bytes))) return {};
        break;
    }
    std::error_code error;
    fs::create_directories(directory_, error);
    if (error) return {std::nullopt, "couldn't create " + store_file::PathText(directory_) + ": " + error.message()};
    const std::string name = "session." + Stamp(now) + (kind == Kind::Hourly ? "" : "." + std::string(RawValue(kind))) + ".json";
    const fs::path file = directory_ / fs::path(std::u8string(name.begin(), name.end()));
    if (std::string problem = store_file::WriteAtomically(file, bytes); !problem.empty()) return {std::nullopt, problem};
    if (kind == Kind::Hourly) newestHourly_ = std::optional<double>(now);
    Backup made{file, now, kind};
    Prune(now, made);
    return {made, {}};
}

void SessionBackups::Prune(double now, const std::optional<Backup>& protecting) const {
    const std::vector<Backup> all = All();
    std::set<fs::path> keep;
    if (protecting) keep.insert(protecting->file);
    for (Kind kind : {Kind::Launch, Kind::Hourly, Kind::Restore}) {
        std::vector<const Backup*> past;
        size_t future = 0;
        for (const Backup& backup : all) {
            if (backup.kind != kind) continue;
            if (backup.date > now) {
                if (future++ < kFutureKept) keep.insert(backup.file);
            } else {
                past.push_back(&backup);
            }
        }
        switch (kind) {
        case Kind::Launch:
            for (size_t i = 0; i < past.size() && i < kLaunchesKept; ++i) keep.insert(past[i]->file);
            break;
        case Kind::Restore:
            for (size_t i = 0; i < past.size() && i < kRestoresKept; ++i) keep.insert(past[i]->file);
            break;
        case Kind::Hourly: {
            std::set<std::string> days;
            for (const Backup* backup : past) {
                const double age = now - backup->date;
                if (age <= kHourlyKeptFor) {
                    keep.insert(backup->file);
                } else if (age <= kDailyKeptFor && days.insert(Stamp(backup->date).substr(0, 10)).second) {
                    // Newest first, so the first of each day is its newest.
                    keep.insert(backup->file);
                }
            }
            break;
        }
        }
    }
    for (const Backup& backup : all) {
        if (keep.contains(backup.file)) continue;
        std::error_code ignored;
        fs::remove(backup.file, ignored);
    }
}

std::optional<BrowserState> SessionBackups::State(const Backup& backup) {
    auto text = store_file::Read(backup.file);
    if (!text) return std::nullopt;
    std::string problem;
    return SessionStore::DecodeFile(*text, problem);
}

std::optional<std::pair<SessionBackups::Backup, BrowserState>> SessionBackups::NewestValid(double now) const {
    const std::vector<Backup> ordered = Ordered(now);
    for (bool restores : {false, true}) {
        for (const Backup& backup : ordered) {
            if ((backup.kind == Kind::Restore) != restores) continue;
            if (auto state = State(backup)) return std::make_pair(backup, std::move(*state));
        }
    }
    return std::nullopt;
}

SessionBackups::Summary SessionBackups::SummaryOf(const Backup& backup) {
    auto state = State(backup);
    if (!state) return Summary{backup, std::nullopt, std::nullopt};
    size_t tabs = 0;
    for (const auto& [directory, favorites] : state->favoritesByProfile) tabs += favorites.size();
    for (const Space& space : state->spaces) tabs += space.AllTabs().size();
    return Summary{backup, state->spaces.size(), tabs};
}

}  // namespace kite

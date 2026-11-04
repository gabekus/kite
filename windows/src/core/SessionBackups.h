#pragma once
// Rolling copies of session.json in the profile's Backups folder: a port of KiteCore's
// SessionBackups (SessionStore.swift), with the Mac's names, kinds and budgets, so either app
// reads the other's. Named like Arc's storable backups: `session.yyyy-MM-dd-HH-mm-ss-SSS.json`
// (UTC) for the hourly ones, with `.launch` or `.restore` before `.json` for the others. Each
// is a whole session file, so one can also be put back by hand.
//
// Each kind has its own budget, so a busy day of hourly copies never pushes out the launch ones:
// - launch: the session as found at each launch. The newest 30.
// - hourly: at most one an hour while Kite runs. All from the last 48 hours, then the newest of
//   each day for 30 days.
// - restore: the state Restore Data replaced. The newest 10, and never the one just made.
//
// Thread-safe (one lock around a backup and its prune). The newest hourly date is kept in
// memory once read, so a save inside the interval costs no disk access at all.
//
// Dates here are Unix seconds (the stamps' clock), not the model's Timestamp.

#include <filesystem>
#include <mutex>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

namespace kite {

struct BrowserState;

class SessionBackups {
public:
    enum class Kind { Launch, Hourly, Restore };

    static constexpr double kInterval = 60 * 60;
    static constexpr size_t kLaunchesKept = 30;
    static constexpr double kHourlyKeptFor = 48 * 60 * 60;
    static constexpr double kDailyKeptFor = 30 * 24 * 60 * 60;
    static constexpr size_t kRestoresKept = 10;
    // Backups stamped after now (the clock went back, or a copied folder) are ordered as the
    // oldest of their kind, so they never stay newest; this many of each kind are kept.
    static constexpr size_t kFutureKept = 5;

    explicit SessionBackups(std::filesystem::path directory) : directory_(std::move(directory)) {}
    const std::filesystem::path& Directory() const { return directory_; }

    struct Backup {
        std::filesystem::path file;
        double date = 0;  // Unix seconds, from the name
        Kind kind = Kind::Hourly;
        bool operator==(const Backup&) const = default;
    };

    // What Restore Data lists for a backup; no counts when it doesn't decode.
    struct Summary {
        Backup backup;
        std::optional<size_t> spaceCount;
        std::optional<size_t> tabCount;
        bool IsRestorable() const { return spaceCount.has_value(); }
    };

    // By date, newest first.
    std::vector<Backup> All() const;
    // Newest first, with any stamped after `now` last.
    std::vector<Backup> Ordered(double now) const;

    struct BackUpResult {
        std::optional<Backup> made;  // none: nothing was due (or it failed: see error)
        std::string error;
    };
    // Keeps `bytes` (a whole session file) as a new backup of `kind` unless it holds the same
    // bytes as the newest backup of that kind, or, for an hourly one, the newest hourly backup is
    // under kInterval old. Then prunes.
    BackUpResult BackUp(std::string_view bytes, Kind kind, double now);
    // Drops what each kind's budget doesn't keep. `protecting` is never dropped.
    void Prune(double now, const std::optional<Backup>& protecting = std::nullopt) const;

    // The backup's session; none when it doesn't decode.
    static std::optional<BrowserState> State(const Backup& backup);
    // Launch and hourly backups first: a restore one holds a state the user restored away from.
    std::optional<std::pair<Backup, BrowserState>> NewestValid(double now) const;
    // Spaces, and tabs counting favorites, pinned and today tabs in every space.
    static Summary SummaryOf(const Backup& backup);

    // Arc's backup stamp, yyyy-MM-dd-HH-mm-ss-SSS in UTC, so names sort the same across time
    // zones and DST.
    static std::string Stamp(double unixSeconds);
    static std::optional<double> DateFromStamp(std::string_view stamp);
    static std::string_view RawValue(Kind kind);
    // The current time in Unix seconds, for the callers' `now`.
    static double Now();

private:
    std::filesystem::path directory_;
    mutable std::mutex mutex_;
    // The newest hourly backup's date once read; the outer optional is "not read yet".
    std::optional<std::optional<double>> newestHourly_;
};

}  // namespace kite

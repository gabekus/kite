#pragma once
// Reads and writes session.json in the Mac's format ({"state": ..., "version": 1}),
// like KiteCore's SessionStore: writes are atomic (core/StoreFile.h), and an unreadable file is
// moved aside (session.corrupt-<unix time>.json), never overwritten, so a bug never eats
// someone's tabs; the newest backup that reads (core/SessionBackups.h) then takes its place.
//
// Save is the one-shot, synchronous write (kitecore, an importer, tests). The app saves through
// core/SessionWriter.h instead, which does the same write on a background thread and keeps the
// backups.

#include <filesystem>
#include <memory>
#include <optional>
#include <string>
#include <string_view>
#include <variant>

#include "core/Models.h"
#include "core/SessionBackups.h"

namespace kite {

class SessionStore {
public:
    static constexpr int kCurrentVersion = 1;

    // Backups go in a Backups folder beside the file, as on the Mac.
    explicit SessionStore(std::filesystem::path file)
        : file_(std::move(file)), backups_(std::make_shared<SessionBackups>(file_.parent_path() / "Backups")) {}
    const std::filesystem::path& File() const { return file_; }
    // Shared by copies of this store, so its lock and its newest-hourly cache are one.
    SessionBackups& Backups() const { return *backups_; }

    struct Missing {};
    struct Error {
        std::string message;
        // Where the unreadable file went. nullopt means it's still in place (it couldn't be
        // read or moved), so saving would overwrite it: see MaySave.
        std::optional<std::filesystem::path> quarantinedTo;
    };
    using LoadResult = std::variant<BrowserState, Missing, Error>;
    // The app moves an unreadable file aside, like the Mac; tools that only look (kitecore)
    // leave it where it is.
    enum class Unreadable { MoveAside, Leave };
    // With MoveAside, a file that was moved aside is replaced by the newest backup that reads
    // (the Mac's loadRecovering), and `recoveredFrom` says which; with none, the Error stands.
    LoadResult Load(Unreadable unreadable = Unreadable::MoveAside,
                    std::optional<SessionBackups::Backup>* recoveredFrom = nullptr) const;

    // Whether saving after this load can't destroy the user's session: false when the file is
    // still there but couldn't be read (locked by antivirus or sync, a failed move aside).
    // Run without saving then, rather than replace their tabs with a fresh session.
    static bool MaySave(const LoadResult& result);

    // Empty on success, otherwise what went wrong.
    std::string Save(const BrowserState& state) const;
    // The two halves of Save: the file's bytes, and writing them over the session.
    static std::string EncodeFile(const BrowserState& state);
    std::string WriteFile(std::string_view bytes) const;
    // A whole session file's state; none (with `problem` set) when it isn't one.
    static std::optional<BrowserState> DecodeFile(std::string_view text, std::string& problem);

private:
    std::filesystem::path file_;
    std::shared_ptr<SessionBackups> backups_;
};

}  // namespace kite

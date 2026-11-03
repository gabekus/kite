#pragma once
// Reads and writes session.json in the Mac's format ({"state": ..., "version": 1}),
// like KiteCore's SessionStore: writes are atomic, and an unreadable file is moved aside
// (session.corrupt-<unix time>.json), never overwritten, so a bug never eats someone's tabs.

#include <filesystem>
#include <optional>
#include <string>
#include <variant>

#include "core/Models.h"

namespace kite {

class SessionStore {
public:
    static constexpr int kCurrentVersion = 1;

    explicit SessionStore(std::filesystem::path file) : file_(std::move(file)) {}
    const std::filesystem::path& File() const { return file_; }

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
    LoadResult Load(Unreadable unreadable = Unreadable::MoveAside) const;

    // Whether saving after this load can't destroy the user's session: false when the file is
    // still there but couldn't be read (locked by antivirus or sync, a failed move aside).
    // Run without saving then, rather than replace their tabs with a fresh session.
    static bool MaySave(const LoadResult& result);

    // Empty on success, otherwise what went wrong.
    std::string Save(const BrowserState& state) const;

private:
    std::filesystem::path file_;
};

}  // namespace kite

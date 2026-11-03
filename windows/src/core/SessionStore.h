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
        std::optional<std::filesystem::path> quarantinedTo;
    };
    std::variant<BrowserState, Missing, Error> Load() const;

    // Empty on success, otherwise what went wrong.
    std::string Save(const BrowserState& state) const;

private:
    std::filesystem::path file_;
};

}  // namespace kite

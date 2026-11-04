// Port of KiteCore SessionStore.swift; see SessionStore.h.

#include "core/SessionStore.h"

#include <chrono>
#include <fstream>
#include <sstream>

#include "core/Files.h"

namespace kite {

namespace fs = std::filesystem;

bool SessionStore::MaySave(const LoadResult& result) {
    if (auto* error = std::get_if<Error>(&result)) return error->quarantinedTo.has_value();
    return true;
}

SessionStore::LoadResult SessionStore::Load(Unreadable unreadable) const {
    std::error_code error;
    bool exists = fs::exists(file_, error);
    if (error) return Error{"couldn't check " + PathText(file_) + ": " + error.message(), std::nullopt};
    if (!exists) return Missing{};
    // Read straight into one string (startup, on the UI thread: no second copy).
    std::string text;
    {
        // Not a regular file (a directory, say): nothing to read, and nothing to move aside.
        if (!fs::is_regular_file(file_, error)) return Error{PathText(file_) + " isn't a file", std::nullopt};
        const auto size = fs::file_size(file_, error);
        if (error) return Error{"couldn't read " + PathText(file_) + ": " + error.message(), std::nullopt};
        std::ifstream in(file_, std::ios::binary);
        if (!in) return Error{"couldn't open " + PathText(file_), std::nullopt};
        text.resize(static_cast<size_t>(size));
        if (!in.read(text.data(), static_cast<std::streamsize>(size))) return Error{"couldn't read " + PathText(file_), std::nullopt};
    }

    std::string problem;
    auto parsed = json::Parse(text);
    if (auto* parseError = std::get_if<json::ParseError>(&parsed)) {
        problem = "invalid JSON at byte " + std::to_string(parseError->offset) + ": " + parseError->message;
    } else {
        const json::Value& root = std::get<json::Value>(parsed);
        const json::Value* state = root.Find("state");
        if (auto decoded = state ? DecodeBrowserState(*state) : std::nullopt) return std::move(*decoded);
        problem = "not a Kite session";
    }

    if (unreadable == Unreadable::Leave) return Error{problem, std::nullopt};
    // Move it aside, like the Mac, so the next save doesn't overwrite it.
    auto seconds = std::chrono::duration_cast<std::chrono::seconds>(std::chrono::system_clock::now().time_since_epoch()).count();
    // Never over an earlier backup (rename would replace it; the Mac's moveItem refuses).
    fs::path backup;
    for (int attempt = 0; attempt < 100; ++attempt) {
        fs::path name = file_.stem();
        name += ".corrupt-" + std::to_string(seconds) + (attempt ? "-" + std::to_string(attempt) : "") + ".json";
        backup = file_.parent_path() / name;
        if (!fs::exists(backup, error) && !error) break;
    }
    if (fs::exists(backup, error)) return Error{problem, std::nullopt};
    fs::rename(file_, backup, error);
    return Error{problem, error ? std::nullopt : std::optional<fs::path>(backup)};
}

std::string SessionStore::Save(const BrowserState& state) const {
    json::Value root(json::Object{{"state", Encode(state)}, {"version", kCurrentVersion}});
    return WriteFileAtomically(file_, json::Write(root));
}

}  // namespace kite

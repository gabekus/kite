// Port of KiteCore SessionStore.swift; see SessionStore.h.

#include "core/SessionStore.h"

#include <chrono>
#include <fstream>
#include <sstream>

namespace kite {

namespace fs = std::filesystem;

namespace {
// UTF-8 for messages; path::string() throws on Windows for names outside the ANSI code page.
std::string PathText(const fs::path& path) {
    auto u8 = path.u8string();
    return std::string(u8.begin(), u8.end());
}
}  // namespace

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
    fs::path name = file_.stem();
    name += ".corrupt-" + std::to_string(seconds) + ".json";
    fs::path backup = file_.parent_path() / name;
    fs::rename(file_, backup, error);
    return Error{problem, error ? std::nullopt : std::optional<fs::path>(backup)};
}

std::string SessionStore::Save(const BrowserState& state) const {
    std::error_code error;
    fs::create_directories(file_.parent_path(), error);
    if (error) return "couldn't create " + PathText(file_.parent_path()) + ": " + error.message();

    json::Value root(json::Object{{"state", Encode(state)}, {"version", kCurrentVersion}});
    std::string text = json::Write(root);

    // Write a sibling temp file, then rename over the session (MoveFileExW with replace on Windows).
    fs::path temp = file_;
    temp += ".tmp";
    {
        std::ofstream out(temp, std::ios::binary | std::ios::trunc);
        if (!out) return "couldn't write " + PathText(temp);
        out.write(text.data(), static_cast<std::streamsize>(text.size()));
        out.flush();
        if (!out) return "couldn't write " + PathText(temp);
    }
    fs::rename(temp, file_, error);
    if (error) {
        std::error_code ignored;
        fs::remove(temp, ignored);
        return "couldn't replace " + PathText(file_) + ": " + error.message();
    }
    return {};
}

}  // namespace kite

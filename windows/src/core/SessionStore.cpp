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

std::variant<BrowserState, SessionStore::Missing, SessionStore::Error> SessionStore::Load() const {
    std::error_code error;
    if (!fs::exists(file_, error)) return Missing{};
    std::ifstream in(file_, std::ios::binary);
    if (!in) return Error{"couldn't open " + PathText(file_), std::nullopt};
    std::stringstream buffer;
    buffer << in.rdbuf();
    in.close();

    std::string problem;
    auto parsed = json::Parse(buffer.str());
    if (auto* parseError = std::get_if<json::ParseError>(&parsed)) {
        problem = "invalid JSON at byte " + std::to_string(parseError->offset) + ": " + parseError->message;
    } else {
        const json::Value& root = std::get<json::Value>(parsed);
        const json::Value* state = root.Find("state");
        if (auto decoded = state ? DecodeBrowserState(*state) : std::nullopt) return std::move(*decoded);
        problem = "not a Kite session";
    }

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
        fs::remove(temp, error);
        return "couldn't replace " + PathText(file_);
    }
    return {};
}

}  // namespace kite

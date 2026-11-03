// Same cases as the Mac's profile-path handling (AppDelegate.supportDirectory) plus the refusal.

#include <filesystem>
#include <fstream>
#include <variant>

#include "Check.h"
#include "core/SupportDirectory.h"

using kite::ResolveSupportDirectory;
using kite::SupportDirectoryError;
namespace fs = std::filesystem;

namespace {
fs::path TempPath(const char* name) { return fs::temp_directory_path() / name; }
}  // namespace

TEST(defaultsToLocalAppDataKite) {
    auto result = ResolveSupportDirectory(std::nullopt, fs::path("C:/Users/x/AppData/Local"));
    CHECK(std::holds_alternative<fs::path>(result));
    CHECK(std::get<fs::path>(result) == fs::path("C:/Users/x/AppData/Local") / "Kite");
}

TEST(emptyOverrideCountsAsUnset) {
    auto result = ResolveSupportDirectory(fs::path(), fs::path("C:/Local"));
    CHECK(std::holds_alternative<fs::path>(result));
}

TEST(usesAnOverrideThatIsADirectory) {
    fs::path dir = TempPath("kite-support-dir-test");
    fs::create_directories(dir);
    auto result = ResolveSupportDirectory(dir, fs::path("C:/Local"));
    CHECK(std::holds_alternative<fs::path>(result));
    CHECK(std::get<fs::path>(result) == dir);
    fs::remove_all(dir);
}

TEST(refusesAnOverrideThatIsAFile) {
    fs::path file = TempPath("kite-support-file-test");
    std::ofstream(file).put('x');
    auto result = ResolveSupportDirectory(file, fs::path("C:/Local"));
    CHECK(std::holds_alternative<SupportDirectoryError>(result));
    fs::remove(file);
}

TEST(refusesAMissingOverride) {
    auto result = ResolveSupportDirectory(TempPath("kite-support-missing-test"), fs::path("C:/Local"));
    CHECK(std::holds_alternative<SupportDirectoryError>(result));
}

TEST(failsWithoutLocalAppData) {
    CHECK(std::holds_alternative<SupportDirectoryError>(ResolveSupportDirectory(std::nullopt, std::nullopt)));
}

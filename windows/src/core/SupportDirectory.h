#pragma once
// Where Kite keeps its profile (session, history, Chromium's data). Mirrors the Mac's
// AppDelegate.supportDirectory: KITE_SUPPORT_PATH overrides it for test runs.

#include <filesystem>
#include <optional>
#include <string>
#include <variant>

namespace kite {

struct SupportDirectoryError {
    std::string message;  // UTF-8
};

// `overridePath` is KITE_SUPPORT_PATH and `localAppData` is %LOCALAPPDATA%, either absent.
// An override that isn't an existing directory is refused rather than created or ignored:
// on macOS a bad path once made Chromium fall back to the user's own profile and change it.
// Without one, the profile is %LOCALAPPDATA%\Kite (where Chrome keeps its User Data too).
std::variant<std::filesystem::path, SupportDirectoryError> ResolveSupportDirectory(
    const std::optional<std::filesystem::path>& overridePath,
    const std::optional<std::filesystem::path>& localAppData);

// An environment variable as a path (UTF-16 on Windows, so any user name works); empty counts as unset.
std::optional<std::filesystem::path> EnvironmentPath(const char* name);

}  // namespace kite

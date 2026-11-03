#pragma once
// Just enough URL parsing for the model and URL input: scheme and host of an absolute URL.

#include <optional>
#include <string>
#include <string_view>

namespace kite::url {

// "https" for "HTTPS://x" (lowercased); nullopt without a valid scheme.
std::optional<std::string> Scheme(std::string_view url);
// The host of a hierarchical URL ("scheme://[user@]host[:port]..."), without brackets for
// IPv6; nullopt when there's no authority. May be empty ("file:///x").
std::optional<std::string> Host(std::string_view url);

}  // namespace kite::url

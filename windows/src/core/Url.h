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
// Whether the authority ("//[user@]host[:port]") parses the way RFC 3986, and so Foundation's
// URL(string:), requires: a bracketed host is an IPv6 address, a port is ASCII digits up to
// 65535. True when there's no authority. A URL failing this is nil on the Mac, so it must
// never reach session.json (the Mac's decoder would reject the whole session).
bool HasValidAuthority(std::string_view url);
// A data: URL's bytes (RFC 2397, as URLSession reads one): base64 when its parameters end with
// ";base64", else the text itself, percent escapes decoded either way. nullopt when it isn't
// one or doesn't decode.
std::optional<std::string> DataBytes(std::string_view url);

}  // namespace kite::url

// See Url.h.

#include "core/Url.h"

#include <cctype>

namespace kite::url {

std::optional<std::string> Scheme(std::string_view url) {
    size_t colon = url.find(':');
    if (colon == std::string_view::npos || colon == 0) return std::nullopt;
    std::string scheme;
    for (size_t i = 0; i < colon; ++i) {
        unsigned char c = static_cast<unsigned char>(url[i]);
        bool ok = std::isalpha(c) || (i > 0 && (std::isdigit(c) || c == '+' || c == '-' || c == '.'));
        if (!ok) return std::nullopt;
        scheme += static_cast<char>(std::tolower(c));
    }
    return scheme;
}

std::optional<std::string> Host(std::string_view url) {
    auto scheme = Scheme(url);
    if (!scheme) return std::nullopt;
    std::string_view rest = url.substr(scheme->size() + 1);
    if (rest.substr(0, 2) != "//") return std::nullopt;
    rest.remove_prefix(2);
    std::string_view authority = rest.substr(0, rest.find_first_of("/?#"));
    if (size_t at = authority.rfind('@'); at != std::string_view::npos) authority.remove_prefix(at + 1);
    if (!authority.empty() && authority.front() == '[') {
        size_t close = authority.find(']');
        if (close == std::string_view::npos) return std::nullopt;
        return std::string(authority.substr(1, close - 1));
    }
    return std::string(authority.substr(0, authority.find(':')));
}

}  // namespace kite::url

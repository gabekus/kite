#include "core/URLInput.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <vector>

#include "core/Url.h"

namespace kite {
namespace {

bool IsUnreserved(unsigned char c) { return std::isalnum(c) || c == '-' || c == '.' || c == '_' || c == '~'; }

std::string PercentEncode(std::string_view text, bool (*keep)(unsigned char)) {
    static const char kHex[] = "0123456789ABCDEF";
    std::string out;
    for (unsigned char c : text) {
        if (keep(c)) {
            out += static_cast<char>(c);
        } else {
            out += '%';
            out += kHex[c >> 4];
            out += kHex[c & 0xF];
        }
    }
    return out;
}

// Characters Foundation's URL(string:) leaves alone in an otherwise valid URL; anything else
// (spaces, non-ASCII) it percent-encodes, which is what "https://example.org/a b" relies on.
bool IsURLCharacter(unsigned char c) {
    if (std::isalnum(c)) return true;
    static constexpr std::string_view kAllowed = "-._~:/?#[]@!$&'()*+,;=%";
    return kAllowed.find(static_cast<char>(c)) != std::string_view::npos;
}

std::string_view Trim(std::string_view s) {
    auto isSpace = [](char c) { return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f'; };
    while (!s.empty() && isSpace(s.front())) s.remove_prefix(1);
    while (!s.empty() && isSpace(s.back())) s.remove_suffix(1);
    return s;
}

bool HasWhitespace(std::string_view s) {
    return std::any_of(s.begin(), s.end(), [](char c) { return std::isspace(static_cast<unsigned char>(c)); });
}

std::string Lower(std::string_view s) {
    std::string out(s);
    for (char& c : out) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return out;
}

std::optional<std::string> ExplicitURL(std::string_view text) {
    static const std::array<std::string_view, 8> kKnownSchemes = {"http", "https", "file", "about", "data", "blob", "view-source", "mailto"};
    auto scheme = url::Scheme(text);
    if (!scheme || std::find(kKnownSchemes.begin(), kKnownSchemes.end(), *scheme) == kKnownSchemes.end()) return std::nullopt;
    std::string encoded = PercentEncode(text, IsURLCharacter);
    if (*scheme == "http" || *scheme == "https") {
        auto host = url::Host(encoded);
        if (!host || host->empty()) return std::nullopt;
    }
    return encoded;
}

bool IsIPv4(std::string_view host) {
    int octets = 0;
    size_t start = 0;
    while (true) {
        size_t end = host.find('.', start);
        std::string_view part = host.substr(start, end == std::string_view::npos ? std::string_view::npos : end - start);
        if (part.empty() || part.size() > 3 || !std::all_of(part.begin(), part.end(), [](char c) { return c >= '0' && c <= '9'; })) return false;
        if (std::stoi(std::string(part)) > 255) return false;
        ++octets;
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return octets == 4;
}

bool IsDomain(std::string_view host) {
    std::vector<std::string_view> labels;
    size_t start = 0;
    while (true) {
        size_t end = host.find('.', start);
        labels.push_back(host.substr(start, end == std::string_view::npos ? std::string_view::npos : end - start));
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    if (labels.size() < 2) return false;
    for (auto label : labels) {
        if (label.empty()) return false;
        for (unsigned char c : label) {
            if (!(std::isalnum(c) || c == '-' || c >= 0x80)) return false;  // non-ASCII letters count, like Swift's isLetter
        }
    }
    std::string_view tld = labels.back();
    bool letters = tld.size() >= 2 && std::all_of(tld.begin(), tld.end(), [](unsigned char c) { return std::isalpha(c) || c >= 0x80; });
    return letters || tld.substr(0, 4) == "xn--";
}

std::optional<std::string> HostLikeURL(std::string_view text) {
    if (text.empty() || HasWhitespace(text)) return std::nullopt;
    std::string_view hostAndPort = text.substr(0, text.find_first_of("/?#"));
    size_t colon = hostAndPort.find(':');
    std::string host = Lower(hostAndPort.substr(0, colon));
    if (host.empty()) return std::nullopt;
    if (colon != std::string_view::npos) {
        std::string_view port = hostAndPort.substr(colon + 1);
        if (port.empty() || port.find(':') != std::string_view::npos ||
            !std::all_of(port.begin(), port.end(), [](char c) { return c >= '0' && c <= '9'; })) {
            return std::nullopt;
        }
    }
    std::string scheme;
    if (host == "localhost" || (host.size() > 10 && host.ends_with(".localhost")) || IsIPv4(host)) {
        scheme = "http";
    } else if (IsDomain(host)) {
        scheme = "https";
    } else {
        return std::nullopt;
    }
    return scheme + "://" + PercentEncode(text, IsURLCharacter);
}

}  // namespace

std::optional<SearchEngine> SearchEngineFromRaw(std::string_view raw) {
    if (raw == "google") return SearchEngine::Google;
    if (raw == "duckDuckGo") return SearchEngine::DuckDuckGo;
    if (raw == "kagi") return SearchEngine::Kagi;
    if (raw == "bing") return SearchEngine::Bing;
    return std::nullopt;
}

std::string SearchURL(SearchEngine engine, std::string_view query) {
    const char* prefix = "https://www.google.com/search?q=";
    switch (engine) {
    case SearchEngine::Google: break;
    case SearchEngine::DuckDuckGo: prefix = "https://duckduckgo.com/?q="; break;
    case SearchEngine::Kagi: prefix = "https://kagi.com/search?q="; break;
    case SearchEngine::Bing: prefix = "https://www.bing.com/search?q="; break;
    }
    return prefix + PercentEncode(query, IsUnreserved);
}

namespace url_input {

std::optional<std::string> Resolve(std::string_view input, SearchEngine engine) {
    std::string_view text = Trim(input);
    if (text.empty()) return std::nullopt;
    if (auto url = AsURL(text)) return url;
    return SearchURL(engine, text);
}

std::optional<std::string> AsURL(std::string_view input) {
    std::string_view text = Trim(input);
    if (auto url = ExplicitURL(text)) return url;
    return HostLikeURL(text);
}

bool LooksLikeURL(std::string_view input) { return AsURL(input).has_value(); }

}  // namespace url_input
}  // namespace kite

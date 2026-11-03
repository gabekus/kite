// Port of KiteCore URLInput.swift; see URLInput.h.

#include "core/URLInput.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <vector>

#include "core/Unicode.h"
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

bool HasWhitespace(std::string_view s) {
    for (char32_t c : unicode::Decode(s)) {
        if (unicode::IsWhitespace(c)) return true;
    }
    return false;
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
    if (!url::HasValidAuthority(encoded)) return std::nullopt;
    if (*scheme == "http" || *scheme == "https") {
        auto host = url::Host(encoded);
        if (!host || host->empty()) return std::nullopt;
    }
    return encoded;
}

// Swift: four dot-separated parts that each parse as UInt8 ("010", "+1" and "-0" do).
bool IsIPv4(std::string_view host) {
    int octets = 0;
    size_t start = 0;
    while (true) {
        size_t end = host.find('.', start);
        std::string_view part = host.substr(start, end == std::string_view::npos ? std::string_view::npos : end - start);
        bool negative = false;
        if (!part.empty() && (part.front() == '+' || part.front() == '-')) {
            negative = part.front() == '-';
            part.remove_prefix(1);
        }
        if (part.empty() || !std::all_of(part.begin(), part.end(), [](char c) { return c >= '0' && c <= '9'; })) return false;
        unsigned value = 0;
        for (char c : part) {
            value = value * 10 + static_cast<unsigned>(c - '0');
            if (value > 255) return false;
        }
        if (negative && value != 0) return false;
        ++octets;
        if (end == std::string_view::npos) break;
        start = end + 1;
    }
    return octets == 4;
}

// Swift's isDomain: two or more labels of letters, numbers and hyphens, ending in a top-level
// domain of two or more letters (or an xn-- punycode one). Like Swift it works on characters
// (unicode::Characters) and classifies each by its first scalar, so "é" written e + U+0301 is
// one letter and a TLD of Hangul jamo is one character.
bool IsDomain(std::string_view host) {
    std::vector<std::vector<std::u32string>> labels(1);
    for (auto& character : unicode::Characters(host)) {
        if (character == U".") labels.emplace_back();
        else labels.back().push_back(std::move(character));
    }
    if (labels.size() < 2) return false;
    for (const auto& label : labels) {
        if (label.empty()) return false;
        for (const auto& character : label) {
            if (!(unicode::IsLetter(character[0]) || unicode::IsNumber(character[0]) || character == U"-")) return false;
        }
    }
    const auto& tld = labels.back();
    bool letters = std::all_of(tld.begin(), tld.end(), [](const std::u32string& c) { return unicode::IsLetter(c[0]); });
    bool punycode = tld.size() >= 4 && tld[0] == U"x" && tld[1] == U"n" && tld[2] == U"-" && tld[3] == U"-";
    return (letters && tld.size() >= 2) || punycode;
}

std::optional<std::string> HostLikeURL(std::string_view text) {
    if (text.empty() || HasWhitespace(text)) return std::nullopt;
    std::string_view hostAndPort = text.substr(0, text.find_first_of("/?#"));
    size_t colon = hostAndPort.find(':');
    std::string host = Lower(hostAndPort.substr(0, colon));
    if (host.empty()) return std::nullopt;
    // Swift allows any Unicode digits here, but URL(string:) then rejects all but ASCII ones.
    if (colon != std::string_view::npos) {
        std::string_view port = hostAndPort.substr(colon + 1);
        if (port.empty() || port.find(':') != std::string_view::npos ||
            !std::all_of(port.begin(), port.end(), [](char c) { return c >= '0' && c <= '9'; })) {
            return std::nullopt;
        }
    }
    std::string scheme;
    if (host == "localhost" || host.ends_with(".localhost") || IsIPv4(host)) {
        scheme = "http";
    } else if (IsDomain(host)) {
        scheme = "https";
    } else {
        return std::nullopt;
    }
    std::string url = scheme + "://" + PercentEncode(text, IsURLCharacter);
    if (!url::HasValidAuthority(url)) return std::nullopt;  // a port above 65535
    return url;
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
    std::string_view text = unicode::Trim(input);
    if (text.empty()) return std::nullopt;
    if (auto url = AsURL(text)) return url;
    return SearchURL(engine, text);
}

std::optional<std::string> AsURL(std::string_view input) {
    std::string_view text = unicode::Trim(input);
    if (auto url = ExplicitURL(text)) return url;
    return HostLikeURL(text);
}

bool LooksLikeURL(std::string_view input) { return AsURL(input).has_value(); }

}  // namespace url_input
}  // namespace kite

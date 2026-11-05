// See Url.h.

#include "core/Url.h"

#include <cctype>
#include <cstdint>

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

std::string_view Path(std::string_view url) {
    auto scheme = Scheme(url);
    if (!scheme) return {};
    std::string_view rest = url.substr(scheme->size() + 1);
    if (rest.substr(0, 2) == "//") {
        rest.remove_prefix(2);
        const size_t end = rest.find_first_of("/?#");
        rest = end == std::string_view::npos ? std::string_view() : rest.substr(end);
    }
    return rest.substr(0, rest.find_first_of("?#"));
}

bool HasValidAuthority(std::string_view url) {
    auto scheme = Scheme(url);
    if (!scheme) return false;
    std::string_view rest = url.substr(scheme->size() + 1);
    if (rest.substr(0, 2) != "//") return true;
    rest.remove_prefix(2);
    std::string_view authority = rest.substr(0, rest.find_first_of("/?#"));
    if (size_t at = authority.rfind('@'); at != std::string_view::npos) authority.remove_prefix(at + 1);
    std::string_view port;
    if (!authority.empty() && authority.front() == '[') {
        size_t close = authority.find(']');
        if (close == std::string_view::npos) return false;
        std::string_view address = authority.substr(1, close - 1);
        bool colon = false;
        for (char c : address) {
            if (c == ':') colon = true;
            else if (!std::isxdigit(static_cast<unsigned char>(c)) && c != '.') return false;
        }
        if (!colon) return false;
        std::string_view after = authority.substr(close + 1);
        if (!after.empty() && after.front() != ':') return false;
        if (!after.empty()) port = after.substr(1);
    } else {
        if (authority.find_first_of("[]") != std::string_view::npos) return false;
        size_t colon = authority.find(':');
        if (colon != std::string_view::npos) port = authority.substr(colon + 1);
    }
    unsigned value = 0;
    for (char c : port) {
        if (c < '0' || c > '9') return false;
        value = value * 10 + static_cast<unsigned>(c - '0');
        if (value > 65535) return false;
    }
    return true;
}

namespace {

int HexDigit(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

std::string PercentDecoded(std::string_view text) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        int high = 0, low = 0;
        if (text[i] == '%' && i + 2 < text.size() && (high = HexDigit(text[i + 1])) >= 0 &&
            (low = HexDigit(text[i + 2])) >= 0) {
            out.push_back(static_cast<char>(high * 16 + low));
            i += 2;
        } else {
            out.push_back(text[i]);
        }
    }
    return out;
}

std::optional<std::string> Base64Decoded(std::string_view text) {
    std::string out;
    out.reserve(text.size() / 4 * 3);
    uint32_t bits = 0;
    int count = 0;
    for (char c : text) {
        int value = -1;
        if (c >= 'A' && c <= 'Z') value = c - 'A';
        else if (c >= 'a' && c <= 'z') value = c - 'a' + 26;
        else if (c >= '0' && c <= '9') value = c - '0' + 52;
        else if (c == '+' || c == '-') value = 62;
        else if (c == '/' || c == '_') value = 63;
        else if (c == '=' || c == ' ' || c == '\t' || c == '\r' || c == '\n') continue;
        else return std::nullopt;
        bits = (bits << 6) | static_cast<uint32_t>(value);
        if (++count == 4) {
            out.push_back(static_cast<char>((bits >> 16) & 0xFF));
            out.push_back(static_cast<char>((bits >> 8) & 0xFF));
            out.push_back(static_cast<char>(bits & 0xFF));
            bits = 0;
            count = 0;
        }
    }
    if (count == 3) {
        out.push_back(static_cast<char>((bits >> 10) & 0xFF));
        out.push_back(static_cast<char>((bits >> 2) & 0xFF));
    } else if (count == 2) {
        out.push_back(static_cast<char>((bits >> 4) & 0xFF));
    } else if (count == 1) {
        return std::nullopt;
    }
    return out;
}

}  // namespace

std::optional<std::string> DataBytes(std::string_view url) {
    if (Scheme(url) != "data") return std::nullopt;
    const size_t comma = url.find(',');
    if (comma == std::string_view::npos) return std::nullopt;
    std::string meta(url.substr(5, comma - 5));
    for (char& c : meta) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    std::string payload = PercentDecoded(url.substr(comma + 1));
    if (meta.ends_with(";base64")) return Base64Decoded(payload);
    return payload;
}

}  // namespace kite::url

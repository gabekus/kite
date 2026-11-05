// Ports KiteCore's ArcCookieImport.swift and the reading half of KiteMac's
// ArcCookiesInstaller.swift; see ArcCookieImport.h.

#include "core/ArcCookieImport.h"

#include <cmath>

#include "core/ArcHistoryImport.h"
#include "core/Files.h"

namespace kite::arc_import {

namespace fs = std::filesystem;

namespace {

std::optional<int64_t> Integer(const sqlite::SqlValue& v) {
    if (auto* i = std::get_if<int64_t>(&v)) return *i;
    // As sqlite3_column_int64 converts a REAL: toward zero, clamped.
    if (auto* d = std::get_if<double>(&v); d && std::isfinite(*d)) {
        if (*d >= 9.2e18) return INT64_MAX;
        if (*d <= -9.2e18) return INT64_MIN;
        return static_cast<int64_t>(*d);
    }
    // A number kept as text (meta's value is LONGVARCHAR), as sqlite3_column_int64 reads it.
    if (auto* s = std::get_if<std::string>(&v)) {
        int64_t n = 0;
        size_t i = 0;
        const bool negative = !s->empty() && (*s)[0] == '-';
        if (negative) ++i;
        if (i >= s->size()) return std::nullopt;
        for (; i < s->size() && (*s)[i] >= '0' && (*s)[i] <= '9'; ++i) {
            if (n > (INT64_MAX - 9) / 10) return std::nullopt;
            n = n * 10 + ((*s)[i] - '0');
        }
        return negative ? -n : n;
    }
    return std::nullopt;
}

int Int(const sqlite::SqlValue& v, int fallback) {
    const auto i = Integer(v);
    if (!i || *i < INT32_MIN || *i > INT32_MAX) return fallback;
    return static_cast<int>(*i);
}

// As the Mac reads a text column, String(cString: sqlite3_column_text(...)): up to its first NUL;
// "" for NULL (its `?? ""`).
std::string Text(sqlite::SqlValue& v) {
    std::string out;
    if (auto* s = std::get_if<std::string>(&v)) out = std::move(*s);
    else if (auto* b = std::get_if<sqlite::Blob>(&v)) out = std::move(b->bytes);
    else if (auto* i = std::get_if<int64_t>(&v)) out = std::to_string(*i);
    if (const size_t nul = out.find('\0'); nul != std::string::npos) out.resize(nul);
    return out;
}

// sqlite3_column_blob: the bytes of a BLOB or TEXT, none for NULL.
std::string Bytes(sqlite::SqlValue& v) {
    if (auto* b = std::get_if<sqlite::Blob>(&v)) return std::move(b->bytes);
    if (auto* s = std::get_if<std::string>(&v)) return std::move(*s);
    return {};
}

// String(data:encoding: .utf8)'s test: well-formed UTF-8 (no overlong forms, surrogates or code
// points past U+10FFFF).
bool IsUtf8(std::string_view s) {
    size_t i = 0;
    while (i < s.size()) {
        const auto c = static_cast<unsigned char>(s[i]);
        size_t extra = 0;
        char32_t cp = 0;
        if (c < 0x80) {
            ++i;
            continue;
        } else if (c >= 0xC2 && c <= 0xDF) {
            extra = 1, cp = c & 0x1F;
        } else if (c >= 0xE0 && c <= 0xEF) {
            extra = 2, cp = c & 0x0F;
        } else if (c >= 0xF0 && c <= 0xF4) {
            extra = 3, cp = c & 0x07;
        } else {
            return false;
        }
        if (i + extra >= s.size()) return false;
        for (size_t k = 1; k <= extra; ++k) {
            const auto d = static_cast<unsigned char>(s[i + k]);
            if ((d & 0xC0) != 0x80) return false;
            cp = (cp << 6) | (d & 0x3F);
        }
        if ((extra == 2 && cp < 0x800) || (extra == 3 && cp < 0x10000) || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF)) return false;
        i += extra + 1;
    }
    return true;
}

// A host a URL can hold as it is: what Chromium keeps in host_key (lowercase names, IPv4, and
// IPv6 in brackets), never one with a character that would end or change the authority.
bool IsURLHost(std::string_view host) {
    if (host.empty()) return false;
    if (host.front() == '[') {
        if (host.size() < 3 || host.back() != ']') return false;
        for (char c : host.substr(1, host.size() - 2)) {
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F') || c == ':' || c == '.')) return false;
        }
        return true;
    }
    for (char c : host) {
        const auto u = static_cast<unsigned char>(c);
        if (u <= 0x20 || u == 0x7F || c == '/' || c == '?' || c == '#' || c == '@' || c == ':' || c == '\\' || c == '[' || c == ']' ||
            c == '%') {
            return false;
        }
    }
    return true;
}

// URLComponents.path's encoding: what a path may not hold as it is, percent-encoded.
std::string PathForURL(std::string_view path) {
    static constexpr char kHex[] = "0123456789ABCDEF";
    std::string out;
    for (char c : path) {
        const auto u = static_cast<unsigned char>(c);
        const bool keep = (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
                          std::string_view("-._~!$&'()*+,;=:@/%").find(c) != std::string_view::npos;
        if (keep) {
            out.push_back(c);
        } else {
            out.push_back('%');
            out.push_back(kHex[u >> 4]);
            out.push_back(kHex[u & 15]);
        }
    }
    return out;
}

// Base64 as Chromium writes Local State's key (RFC 4648, padded); none for anything else.
std::optional<std::string> Base64(std::string_view text) {
    std::string out;
    out.reserve(text.size() / 4 * 3);
    uint32_t bits = 0;
    int count = 0;
    size_t padding = 0;
    for (char c : text) {
        int value = -1;
        if (c >= 'A' && c <= 'Z') value = c - 'A';
        else if (c >= 'a' && c <= 'z') value = c - 'a' + 26;
        else if (c >= '0' && c <= '9') value = c - '0' + 52;
        else if (c == '+') value = 62;
        else if (c == '/') value = 63;
        else if (c == '=') {
            ++padding;
            continue;
        } else {
            return std::nullopt;
        }
        if (padding) return std::nullopt;
        bits = (bits << 6) | static_cast<uint32_t>(value);
        if ((count += 6) >= 8) {
            count -= 8;
            out.push_back(static_cast<char>((bits >> count) & 0xFF));
        }
    }
    return out;
}

}  // namespace

int64_t ChromeTime(Timestamp time) {
    // Timestamp is Foundation's, from 2001; Chromium's from 1601.
    return static_cast<int64_t>((time + 978'307'200.0 + 11'644'473'600.0) * 1'000'000.0);
}

std::optional<std::string> ArcCookie::Url() const {
    const std::string host = row.host.starts_with('.') ? row.host.substr(1) : row.host;
    if (!IsURLHost(host)) return std::nullopt;
    const bool secure = row.isSecure || row.sourceScheme != 1;
    std::string url = std::string(secure ? "https" : "http") + "://" + host;
    if (row.sourcePort > 0 && row.sourcePort != (secure ? 443 : 80)) url += ":" + std::to_string(row.sourcePort);
    const std::string path = row.path.empty() ? "/" : PathForURL(row.path);
    // URLComponents.url is nil for a path that doesn't start with "/" under a host.
    if (!path.starts_with('/')) return std::nullopt;
    return url + path;
}

std::optional<std::string> ArcCookie::Domain() const {
    if (row.host.starts_with('.')) return row.host;
    return std::nullopt;
}

std::variant<ArcCookie, CookieSkip> ClassifyCookie(const CookieRow& row, int databaseVersion, Timestamp now, const CookieDecrypt& decrypt,
                                                   const CookieHostHash& hostHash) {
    if (row.expiresUTC != 0 && row.expiresUTC <= ChromeTime(now)) return CookieSkip::Expired;
    if (!row.topFrameSiteKey.empty()) return CookieSkip::Partitioned;
    if (row.encryptedValue.empty()) return ArcCookie{row, row.value};
    const std::string_view encrypted = row.encryptedValue;
    if (encrypted.starts_with(kAppBoundPrefix)) return CookieSkip::AppBound;
    if (!encrypted.starts_with(kEncryptedPrefix)) return CookieSkip::OtherScheme;
    std::optional<std::string> plain = decrypt(encrypted.substr(kEncryptedPrefix.size()));
    if (!plain) return CookieSkip::NotDecrypted;
    if (databaseVersion >= 24) {
        // Chromium checks it too: with GCM a wrong key fails its tag, but a row moved from another
        // host would decrypt and still be wrong here.
        if (plain->size() < kHostHashLength || std::string_view(*plain).substr(0, kHostHashLength) != hostHash(row.host)) {
            return CookieSkip::NotDecrypted;
        }
        plain->erase(0, kHostHashLength);
    }
    if (!IsUtf8(*plain)) return CookieSkip::NotText;
    return ArcCookie{row, std::move(*plain)};
}

std::optional<ArcCookie> CookieFrom(const CookieRow& row, int databaseVersion, Timestamp now, const CookieDecrypt& decrypt,
                                    const CookieHostHash& hostHash) {
    auto result = ClassifyCookie(row, databaseVersion, now, decrypt, hostHash);
    if (auto* cookie = std::get_if<ArcCookie>(&result)) return std::move(*cookie);
    return std::nullopt;
}

std::optional<CookieToSet> ToSet(const ArcCookie& cookie) {
    auto url = cookie.Url();
    if (!url) return std::nullopt;
    CookieToSet out;
    out.url = std::move(*url);
    out.name = cookie.row.name;
    out.value = cookie.value;
    out.domain = cookie.Domain().value_or("");
    out.path = cookie.row.path;
    out.secure = cookie.row.isSecure;
    out.httpOnly = cookie.row.isHTTPOnly;
    out.expires = cookie.row.expiresUTC;
    // Chromium's stored values to CEF's: same-site -1…2 is 0…3, priority 0…2 is -1…1. One out of
    // range (a newer Chromium's) is CEF's unspecified and medium.
    out.sameSite = cookie.row.sameSite >= -1 && cookie.row.sameSite <= 2 ? cookie.row.sameSite + 1 : 0;
    out.priority = cookie.row.priority >= 0 && cookie.row.priority <= 2 ? cookie.row.priority - 1 : 0;
    return out;
}

std::optional<CookieTable> ReadChromiumCookies(sqlite::PageSource& source, const std::atomic<bool>* cancel) {
    CookieTable out;
    sqlite::ScanOptions options;
    options.cancel = cancel;
    options.maxRecordBytes = kMaxCookieRowBytes;
    // meta's "version": 0 when there's none, as the Mac's.
    std::optional<size_t> key, value;
    auto meta = sqlite::ScanTable(
        source, "meta",
        [&](const std::vector<std::string>& columns) {
            key = sqlite::ColumnIndex(columns, "key");
            value = sqlite::ColumnIndex(columns, "value");
            return key && value;
        },
        [&](std::vector<sqlite::SqlValue>& values) {
            if (Text(values[*key]) != "version") return true;
            out.version = Int(values[*value], 0);
            return false;
        },
        options);
    if (cancel && cancel->load()) return std::nullopt;
    (void)meta;  // no meta table is version 0, as the Mac's failed prepare
    struct Columns {
        std::optional<size_t> host, name, value, encrypted, path, expires, secure, httpOnly, sameSite, priority, sourceScheme, sourcePort, topFrame;
    } c;
    auto scan = sqlite::ScanTable(
        source, "cookies",
        [&](const std::vector<std::string>& columns) {
            auto at = [&](std::string_view name) { return sqlite::ColumnIndex(columns, name); };
            c = {at("host_key"), at("name"),        at("value"),    at("encrypted_value"), at("path"),        at("expires_utc"),
                 at("is_secure"), at("is_httponly"), at("samesite"), at("priority"),        at("source_scheme"), at("source_port"),
                 at("top_frame_site_key")};
            // The Mac's query names all thirteen: without one it doesn't run.
            return c.host && c.name && c.value && c.encrypted && c.path && c.expires && c.secure && c.httpOnly && c.sameSite && c.priority &&
                   c.sourceScheme && c.sourcePort && c.topFrame;
        },
        [&](std::vector<sqlite::SqlValue>& v) {
            CookieRow row;
            row.host = Text(v[*c.host]);
            row.name = Text(v[*c.name]);
            row.value = Text(v[*c.value]);
            row.encryptedValue = Bytes(v[*c.encrypted]);
            row.path = Text(v[*c.path]);
            row.expiresUTC = Integer(v[*c.expires]).value_or(0);
            row.isSecure = Integer(v[*c.secure]).value_or(0) != 0;
            row.isHTTPOnly = Integer(v[*c.httpOnly]).value_or(0) != 0;
            // sqlite3_column_int: 0 for NULL.
            row.sameSite = Int(v[*c.sameSite], 0);
            row.priority = Int(v[*c.priority], 0);
            row.sourceScheme = Int(v[*c.sourceScheme], 0);
            row.sourcePort = Int(v[*c.sourcePort], 0);
            row.topFrameSiteKey = Text(v[*c.topFrame]);
            out.rows.push_back(std::move(row));
            return true;
        },
        options);
    if (!scan || scan->stopped) return std::nullopt;
    out.tooLong = scan->oversized;
    return out;
}

fs::path ArcCookiesFile(const fs::path& arcFolder, const std::string& profile) {
    const fs::path folder = arcFolder / "User Data" / fs::path(std::u8string(profile.begin(), profile.end()));
    std::error_code error;
    const fs::path network = folder / "Network" / "Cookies";
    if (fs::exists(network, error) || error) return network;
    return folder / "Cookies";
}

CookieKeyInfo ParseCookieKey(std::string_view localState) {
    CookieKeyInfo out;
    auto root = json::ParseValue(localState);
    const json::Value* crypt = json::Member(root ? &*root : nullptr, "os_crypt");
    out.appBound = json::Member(crypt, "app_bound_encrypted_key") != nullptr;
    const json::Value* key = json::Member(crypt, "encrypted_key");
    const std::string* text = key ? key->AsString() : nullptr;
    if (!text) return out;
    auto bytes = Base64(*text);
    constexpr std::string_view kDPAPI = "DPAPI";
    if (!bytes || !std::string_view(*bytes).starts_with(kDPAPI) || bytes->size() == kDPAPI.size()) return out;
    bytes->erase(0, kDPAPI.size());
    out.protectedKey = std::move(*bytes);
    return out;
}

ProfileCookies ReadArcCookieRows(const fs::path& arcFolder, const std::string& profile, size_t maxFileBytes,
                                 const std::atomic<bool>* cancel) {
    ProfileCookies out;
    const fs::path file = ArcCookiesFile(arcFolder, profile);
    std::error_code error;
    if (!fs::exists(file, error) && !error) return out;
    if (!fs::is_regular_file(file, error)) {
        out.unreadable = true;
        return out;
    }
    const fs::path lockfile = arcFolder / "User Data" / "lockfile";
    if (out.problem = DatabaseBusy(file, lockfile); !out.problem.empty()) return out;
    const auto before = StampOf(file);
    if (!before) {
        out.unreadable = true;
        return out;
    }
    if (before->size > maxFileBytes) {
        out.tooLarge = before->size;
        return out;
    }
    sqlite::FilePages pages(file);
    if (pages.IsOpen() && pages.Size() > maxFileBytes) {
        out.tooLarge = pages.Size();
        return out;
    }
    std::string header;
    if (!pages.IsOpen() || !pages.Read(0, 100, header) || !sqlite::HeaderJournal(header)) {
        out.unreadable = true;
        return out;
    }
    auto table = ReadChromiumCookies(pages, cancel);
    if (cancel && cancel->load()) return out;
    // Arc started (or wrote) while it was read: what came out may mix two versions.
    if (StampOf(file) != before || !DatabaseBusy(file, lockfile).empty()) {
        out.problem = "Arc changed it while Kite read it: quit Arc and import again";
        return out;
    }
    if (!table) {
        out.unreadable = true;
        return out;
    }
    out.table = std::move(table);
    return out;
}

CookieRead DecideCookies(CookieTable& table, Timestamp now, const CookieDecrypt& decrypt, const CookieHostHash& hostHash) {
    CookieRead out;
    out.rows = table.rows.size() + table.tooLong;
    out.tooLong = table.tooLong;
    for (CookieRow& row : table.rows) {
        auto result = ClassifyCookie(row, table.version, now, decrypt, hostHash);
        if (auto* cookie = std::get_if<ArcCookie>(&result)) {
            if (!cookie->Url()) {
                ++out.noURL;
                continue;
            }
            out.cookies.push_back(std::move(*cookie));
            continue;
        }
        switch (std::get<CookieSkip>(result)) {
        case CookieSkip::Expired: ++out.expired; break;
        case CookieSkip::Partitioned: ++out.partitioned; break;
        case CookieSkip::AppBound: ++out.appBound; break;
        case CookieSkip::OtherScheme: ++out.otherScheme; break;
        case CookieSkip::NotDecrypted: ++out.notDecrypted; break;
        case CookieSkip::NotText: ++out.notText; break;
        }
    }
    return out;
}

CookieTally TallyCookies(const CookieTable& table, Timestamp now) {
    CookieTally out;
    out.rows = table.rows.size() + table.tooLong;
    out.tooLong = table.tooLong;
    const int64_t chromeNow = ChromeTime(now);
    for (const CookieRow& row : table.rows) {
        const std::string_view encrypted = row.encryptedValue;
        if (encrypted.empty()) ++out.plain;
        else if (encrypted.starts_with(kEncryptedPrefix)) ++out.v10;
        else if (encrypted.starts_with(kAppBoundPrefix)) ++out.v20;
        else ++out.other;
        if (row.expiresUTC == 0) ++out.session;
        else if (row.expiresUTC <= chromeNow) ++out.expired;
        if (!row.topFrameSiteKey.empty()) ++out.partitioned;
    }
    return out;
}

void AddCounts(CookieRead& total, const CookieRead& read) {
    total.rows += read.rows;
    total.expired += read.expired;
    total.partitioned += read.partitioned;
    total.appBound += read.appBound;
    total.otherScheme += read.otherScheme;
    total.notDecrypted += read.notDecrypted;
    total.notText += read.notText;
    total.tooLong += read.tooLong;
    total.noURL += read.noURL;
}

json::Value SignInsSummary(const SignInsResult& r) {
    json::Object skipped;
    auto add = [&](const char* kind, uint64_t count) {
        if (count > 0) skipped.emplace(kind, count);
    };
    add("expired", r.read.expired);
    add("partitioned", r.read.partitioned);
    add("appBound", r.read.appBound);
    add("otherEncryption", r.read.otherScheme);
    add("notDecrypted", r.read.notDecrypted);
    add("notText", r.read.notText);
    add("tooLong", r.read.tooLong);
    add("noURL", r.read.noURL);
    add("refusedByChromium", r.refused);
    json::Array problems;
    for (const auto& [profile, why] : r.problems) problems.push_back(json::Object{{"profile", profile}, {"reason", why}});
    json::Object o{{"rows", r.read.rows}, {"set", r.set}, {"skipped", std::move(skipped)}, {"profilesRead", r.profilesRead}};
    if (!problems.empty()) o.emplace("problems", std::move(problems));
    if (r.noKey) o.emplace("noKey", true);
    return json::Value(std::move(o));
}

std::pair<std::string, std::string> SignInsMessage(const SignInsResult& r) {
    auto count = [](uint64_t n, const char* what) { return std::to_string(n) + " " + what + (n == 1 ? "" : "s"); };
    if (r.noKey) {
        return {"Kite couldn't get Arc's key, so sign-ins didn't come over.",
                "Kite reads Arc's key from Arc's Local State with Windows' data protection for your account. Import from Arc again from the "
                "Windows account Arc ran in."};
    }
    const uint64_t unreadable = r.problems.size();
    std::string appBound;
    if (r.read.appBound > 0) {
        appBound = " " + count(r.read.appBound, "cookie") +
                   " used Chromium's app-bound encryption, which Kite can't read; sign in to those sites again.";
    }
    if (r.set > 0) {
        const std::string missed =
            unreadable > 0 ? " Kite couldn't read " + count(unreadable, "Arc profile") + "'s cookies; quit Arc and import again for those." : "";
        return {"Sign-ins came over from Arc.",
                "Kite set " + count(r.set, "cookie") + ". Sites you were signed in to in Arc should be signed in here too." + missed + appBound};
    }
    return {"No sign-ins came over from Arc.",
            (unreadable > 0 ? std::string("Kite couldn't read Arc's cookies. Quit Arc and import again.") : std::string("Kite found no cookies it could use.")) +
                appBound};
}

}  // namespace kite::arc_import

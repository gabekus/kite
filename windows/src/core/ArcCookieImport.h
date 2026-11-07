#pragma once
// Arc's cookies (its sign-ins), for Import from Arc's "Bring sign-ins": a port of KiteCore's
// ArcCookieImport.swift (what each row becomes) and the reading half of KiteMac's
// ArcCookiesInstaller.swift (which rows, from which file).
//
// Arc for Windows keeps them as Chromium for Windows does: each profile's Cookies database
// (User Data/<profile>/Network/Cookies; User Data/<profile>/Cookies before Chromium 96), a row
// per cookie, the value in `encrypted_value` as "v10" + a 12-byte nonce + AES-256-GCM ciphertext
// + its 16-byte tag. The key is in Local State's os_crypt.encrypted_key: base64 of "DPAPI" and the
// key protected with DPAPI for the user. From database version 24 the plaintext starts with the
// SHA-256 of the cookie's host, 32 bytes, as on the Mac. Chromium 127 and later can protect the
// key again with an elevated service instead ("v20", app-bound encryption, with
// os_crypt.app_bound_encrypted_key): Kite never asks for elevation and never works around it, so a
// v20 cookie stays behind (counted) and the user signs in to that site again. Arc for Windows
// 1.x writes v10 (docs/windows-arc-cookies.md).
//
// The Mac's key comes from the keychain and its cipher is AES-128-CBC; only those differ. The
// shell does the crypto (DPAPI and BCrypt, shell/ArcCookieCrypto.h) and hands it in as `decrypt`
// and `hostHash`; this decides what each row becomes, and reads the rows with Kite's own SQLite
// reader, in place, with the same checks as Arc's History (DatabaseBusy, ArcHistoryImport.h).
//
// Nothing here prints or logs a cookie: counts only. Delete with ArcImportController.h once Arc
// has shut down.

#include <atomic>
#include <cstdint>
#include <filesystem>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <variant>
#include <vector>

#include "core/Json.h"
#include "core/Models.h"
#include "core/SQLiteReader.h"

namespace kite::arc_import {

// One row of the `cookies` table (the Mac's ArcCookieImport.Row).
struct CookieRow {
    std::string host;
    std::string name;
    std::string value;           // the plain value, for a row Chromium didn't encrypt
    std::string encryptedValue;  // bytes
    std::string path;
    // Microseconds since 1601-01-01 UTC; 0 for a session cookie.
    int64_t expiresUTC = 0;
    bool isSecure = false;
    bool isHTTPOnly = false;
    // Chromium's: -1 unspecified, 0 none, 1 lax, 2 strict.
    int sameSite = -1;
    // Chromium's: 0 low, 1 medium, 2 high.
    int priority = 1;
    // The scheme that set it: 0 unset, 1 non-secure, 2 secure.
    int sourceScheme = 0;
    // The port that set it; -1 when unknown.
    int sourcePort = -1;
    // The top-level site of a partitioned (CHIPS) cookie; empty for an ordinary one.
    std::string topFrameSiteKey;
    bool operator==(const CookieRow&) const = default;
};

// A cookie ready to set in a Kite profile (the Mac's ArcCookieImport.Cookie).
struct ArcCookie {
    CookieRow row;
    std::string value;
    // The URL to set it for, as the site that set it: a domain cookie's host without its leading
    // dot, https unless a non-secure page set it, and its port when that wasn't the scheme's own
    // (Chromium can bind cookies to scheme and port). None for a host no URL can hold.
    std::optional<std::string> Url() const;
    // A domain cookie (leading dot) goes to the host and its subdomains; a host cookie only to its
    // host (none).
    std::optional<std::string> Domain() const;
    bool operator==(const ArcCookie&) const = default;
};

inline constexpr std::string_view kEncryptedPrefix = "v10";
// Chromium 127+'s app-bound encryption, which Kite can't decrypt (see above).
inline constexpr std::string_view kAppBoundPrefix = "v20";
// The SHA-256 of the host that Chromium puts before the value from database version 24.
inline constexpr size_t kHostHashLength = 32;

// Takes the ciphertext after "v10" and gives the plaintext, or none when it doesn't decrypt.
using CookieDecrypt = std::function<std::optional<std::string>(std::string_view)>;
// SHA-256 of the host, 32 bytes.
using CookieHostHash = std::function<std::string(std::string_view)>;

// Why a row doesn't come over.
enum class CookieSkip {
    Expired,      // expired by `now`
    Partitioned,  // CEF can't set a partition, and unpartitioned it would follow the user across sites
    AppBound,     // "v20": Chromium's app-bound encryption
    OtherScheme,  // encrypted some other way ("v11", an old raw DPAPI value)
    NotDecrypted, // the key didn't open it, or its host hash didn't match (a wrong key, a tampered row)
    NotText,      // not UTF-8
};

// The cookie for `row`, or why not: the Mac's cookie(from:databaseVersion:now:decrypt:hostHash:),
// with the reason it returns nil for.
std::variant<ArcCookie, CookieSkip> ClassifyCookie(const CookieRow& row, int databaseVersion, Timestamp now, const CookieDecrypt& decrypt,
                                                   const CookieHostHash& hostHash);
// The Mac's cookie(from:...): the cookie, or none.
std::optional<ArcCookie> CookieFrom(const CookieRow& row, int databaseVersion, Timestamp now, const CookieDecrypt& decrypt,
                                    const CookieHostHash& hostHash);

// Microseconds since 1601-01-01 UTC, Chromium's (and CEF's) time.
int64_t ChromeTime(Timestamp time);

// A cookie as CEF's SetCookie takes it (the Mac's ArcCookiesInstaller.set): Chromium's stored
// same-site -1…2 is CEF's 0…3 (cef_cookie_same_site_t), its priority 0…2 CEF's -1…1
// (cef_cookie_priority_t). `expires` 0: a session cookie.
struct CookieToSet {
    std::string url, name, value, domain, path;
    bool secure = false, httpOnly = false;
    int64_t expires = 0;
    int sameSite = 0;
    int priority = 0;
    bool operator==(const CookieToSet&) const = default;
};
// None when the cookie has no URL to set it for.
std::optional<CookieToSet> ToSet(const ArcCookie& cookie);

// A Cookies database's rows and its schema version (meta's "version"; 0 when it has none).
struct CookieTable {
    int version = 0;
    std::vector<CookieRow> rows;
    uint64_t tooLong = 0;  // rows over kMaxCookieRowBytes, left unread
};
// Chromium keeps a cookie's name and value to 4 KB together (net::ParsedCookie); a row past this
// isn't one it wrote.
inline constexpr size_t kMaxCookieRowBytes = size_t{64} << 10;
// The table in `source`. None when it isn't a Cookies database (no cookies table with the Mac's
// columns), turns out broken, or the read was cancelled.
std::optional<CookieTable> ReadChromiumCookies(sqlite::PageSource& source, const std::atomic<bool>* cancel = nullptr);

// An Arc profile's Cookies database: Network/Cookies, where Chromium for Windows keeps it, or the
// profile's own folder (the Mac's place, and Chromium's before version 96) when there's none.
std::filesystem::path ArcCookiesFile(const std::filesystem::path& arcFolder, const std::string& profile);

// What Local State says about the cookies' key.
struct CookieKeyInfo {
    // The DPAPI-protected key: os_crypt.encrypted_key's bytes after "DPAPI". None when it's not
    // there or isn't that.
    std::optional<std::string> protectedKey;
    // os_crypt.app_bound_encrypted_key is there (v20 cookies may be about).
    bool appBound = false;
};
CookieKeyInfo ParseCookieKey(std::string_view localState);

// One Arc profile's cookie rows, read from Arc's folder with History's checks (no live writer of
// the database, its journal or log, or of User Data/lockfile: Arc isn't running; no hot journal or
// waiting log; the same size and age, with no writer, after the read). `table` none and `problem`
// empty: no Cookies file (or the read was cancelled). `problem` says why one that's there didn't
// come over, in the words Import from Arc uses.
struct ProfileCookies {
    std::optional<CookieTable> table;
    std::string problem;
    std::optional<uint64_t> tooLarge;  // the file's size, past maxFileBytes
    bool unreadable = false;           // there, but not a database Kite can read
};
ProfileCookies ReadArcCookieRows(const std::filesystem::path& arcFolder, const std::string& profile, size_t maxFileBytes,
                                 const std::atomic<bool>* cancel = nullptr);

// What a profile's rows became: the cookies to set, and every other row counted once by reason.
struct CookieRead {
    std::vector<ArcCookie> cookies;
    uint64_t rows = 0;  // every row, including tooLong
    uint64_t expired = 0, partitioned = 0, appBound = 0, otherScheme = 0, notDecrypted = 0, notText = 0, tooLong = 0;
    uint64_t noURL = 0;  // a host no URL can hold (ToSet would have nothing to set it for)
};
// Each row of `table` through ClassifyCookie. The rows' bytes are moved out of `table`.
CookieRead DecideCookies(CookieTable& table, Timestamp now, const CookieDecrypt& decrypt, const CookieHostHash& hostHash);

// How a profile's rows are kept, without decrypting any: for `kitecore arc-cookies` and the spike
// (docs/windows-arc-cookies.md). Counts only.
struct CookieTally {
    uint64_t rows = 0, v10 = 0, v20 = 0, plain = 0, other = 0;
    uint64_t session = 0, expired = 0, partitioned = 0, tooLong = 0;
};
CookieTally TallyCookies(const CookieTable& table, Timestamp now);

// What sign-ins did, for Import from Arc's summary: counts per reason, never a cookie.
struct SignInsResult {
    uint64_t set = 0;       // CEF took them
    uint64_t refused = 0;   // CEF refused them (a name or value it won't store, say)
    CookieRead read;        // the counts, summed over the profiles (cookies emptied)
    uint64_t profilesRead = 0;
    std::vector<std::pair<std::string, std::string>> problems;  // (Arc profile, why its cookies didn't come over)
    bool noKey = false;     // Local State had no key Kite could use
};
void AddCounts(CookieRead& total, const CookieRead& read);
json::Value SignInsSummary(const SignInsResult& result);
// The Mac's note after sign-ins: the title and its detail.
std::pair<std::string, std::string> SignInsMessage(const SignInsResult& result);

}  // namespace kite::arc_import

# Import from Arc: cookies (sign-ins) on Windows

Status: the rules are ported and tested; decryption, setting the cookies, and the live import
are **not built** and wait on Gabe's go-ahead. No code in this checkpoint reads a cookie's value.

## What Arc for Windows uses

Arc for Windows keeps cookies the way Chromium for Windows does: each profile's `Cookies` SQLite
database (`User Data/<profile>/Network/Cookies`), a row per cookie, with the value in
`encrypted_value`. The prefix says how it's protected:

- **v10** — AES-256-GCM, with a key held in `Local State`'s `os_crypt.encrypted_key` (base64 of
  `DPAPI` + the key protected with Windows' data protection for the user). **Importable**: Kite
  can read the key as the user and open the values, no elevation.
- **v20** — Chromium 127+ app-bound encryption, with a key an elevated service protects
  (`os_crypt.app_bound_encrypted_key`). **Not importable** without privilege escalation or COM
  tricks, which Kite does not do. A v20 cookie stays behind and the user signs in to that site
  again.

A spike on this machine's Arc profile (a temporary copy of the database and `Local State`, read
counts-only and deleted afterwards) found the cookies are **v10** (tally: v10 in full, v20 none,
plain none), the schema is database version 24 (each value is preceded by the SHA-256 of its
host), `os_crypt.encrypted_key` is present and DPAPI-protected, and there is **no**
`os_crypt.app_bound_encrypted_key`. So on Arc for Windows 1.x the cookies are importable, matching
the parity plan's note that v20 would mean "can't".

The decision this resolves (parity plan, Decision 3): the SQLite is read with Kite's own
read-only reader (`core/SQLiteReader.h`, from W33a #375), not winsqlite3.dll, so there is still no
third-party code.

## What's ported in this checkpoint

`core/ArcCookieImport.h` / `.cpp` ports KiteCore's `ArcCookieImport.swift` (what each row becomes)
and the row-reading half of KiteMac's `ArcCookiesInstaller.swift` (which rows, from which file).
The only differences from the Mac are the key's source (Local State + DPAPI, not the keychain) and
the cipher (AES-GCM, not AES-128-CBC); the rest is the same logic:

- Chromium's time (microseconds from 1601) and expiry: an expired cookie is left out.
- Partitioned (CHIPS) cookies are left behind (CEF can't set a partition, and unpartitioned one
  would follow the user across sites).
- From database version 24, the plaintext must start with the SHA-256 of the cookie's host; a
  mismatch (a wrong key, or a row moved from another host) drops it.
- The URL to set each cookie for: the host without a leading dot, https unless a non-secure page
  set it, the source port when it isn't the scheme's own; and the domain for a domain cookie.
- Chromium's stored SameSite (-1…2) and priority (0…2) mapped to CEF's (0…3, -1…1).
- Counting every row once, by reason (expired, partitioned, app-bound/v20, other encryption, not
  opened, not text, too long, no URL), with **counts only** — never a name, value or host.

It reads the rows with the W33a reader, in place, under the same refusal rules as Arc history
(`ArcHistoryImport.h`'s `DatabaseBusy`: Arc not running, no live writer of the database, its
journal/log or `User Data/lockfile`, no hot journal or non-empty write-ahead log, and the same
size and modification time before and after the read).

`kitecore arc-cookies [PATH|--auto]` prints the per-profile encryption tally (v10/v20/plain/other),
session/expired/partitioned counts, the database version, and whether `Local State` has a DPAPI key
and an app-bound key. It **decrypts nothing** and prints no cookie. The decision-rules functions
have unit tests (`tests/ArcCookieImportTests.cpp`) that use only synthetic in-memory rows and a
plain reverse as the transform double — no real algorithm and no real data.

The confirmation and summary now describe sign-ins as an opt-in the app offers (an `ImportOptions`
flag and a map of which Arc profile goes to which Kite profile), rather than "not imported on
Windows yet".

## What waits for Gabe's decision

None of this is built in this checkpoint:

- **Decryption.** Unprotect the key from `Local State` with DPAPI (`CryptUnprotectData`), then open
  each v10 value with BCrypt AES-256-GCM (the 12-byte nonce and 16-byte tag Chromium writes). All
  of it on a worker thread, off the UI thread.
- **Key handling.** The unprotected key lives in memory only — never written to a file, logged or
  printed — and is `SecureZeroMemory`'d as soon as the profile's rows are decrypted.
- **Setting the cookies.** Map each kept cookie to `CefCookie` and set it via
  `CefCookieManager::SetCookie` on the target Kite profile's request context, counting what CEF
  takes and refuses. The UI thread sees only the final posted result.
- **The prompt and entry point.** The Mac's "Bring sign-ins" checkbox, off unless asked, under the
  existing Import from Arc flow, with the same refusal rules (Arc running, deny-write probe).
- **The live check.** A one-off import of the real Arc cookies into a **temporary** test profile
  only (never a real Kite profile, never `%LOCALAPPDATA%\Kite`), reporting counts only, then
  deleting the temp profile.

Until then, the honest behaviour is unchanged: Import from Arc brings spaces, favorites, profiles,
Site Search, the archive, settings and history, and the user signs in to sites again.

# Over-the-air updates

Kite updates itself the way Arc does: [Sparkle](https://sparkle-project.org) reads an
EdDSA-signed appcast, downloads the new build in the background, and installs it the next time
Kite quits. Kite › Check for Updates… shows Sparkle's window with the release notes and
Install and Relaunch.

## Which Kites update themselves

Only builds made with an update feed: `scripts/release.sh` and `scripts/package-share.sh` (what
coworkers get). `bundle-app.sh` writes the feed into Info.plist from `KITE_UPDATE_FEED`:

| Info.plist key | Value | Why |
|---|---|---|
| `SUFeedURL` | `https://github.com/gabekus/kite/releases/latest/download/appcast.xml` | the appcast attached to the latest release |
| `SUPublicEDKey` | in `Resources/Info.plist`, every build | the update's signature must verify against it |
| `SUEnableAutomaticChecks`, `SUAutomaticallyUpdate` | true | Arc's: check and install silently |
| `SUScheduledCheckInterval` | 28800 | Arc's 8 hours |
| `SUVerifyUpdateBeforeExtraction` | true | check the signature before unpacking |

Builds without a feed (`install-app.sh`, `update-app.sh`, test builds) never start Sparkle.
Gabe's /Applications/Kite.app is one of those: the merge thread keeps it on main, and nothing
else replaces it. Check for Updates… there falls back to the GitHub releases check
(`UpdaterWindow`).

Settings › General › Automatically update my Kite turns the scheduled checks and silent
installs off and on (`SoftwareUpdater`).

## Versions

`bundle-app.sh` sets `CFBundleVersion` to the commit count of HEAD, which grows with every merge
to main, and the version to Info.plist's major.minor plus that count (`0.1.2345`). Sparkle
compares `CFBundleVersion`. Release tags are `v<version>`.

## Signing and notarization

A release must be signed with Gabe's Developer ID (release.sh refuses anything else). Sparkle
only installs an update signed by the same team as the Kite that's running, and 1Password only
trusts a Developer ID browser.

Release builds (`bundle-app.sh release` with a Developer ID) are signed with the hardened runtime
and a secure timestamp, and each helper gets Chromium's entitlements from `Resources/entitlements`:

| Signed code | Entitlements | Why |
|---|---|---|
| Kite.app | camera, microphone, location, calendars, Apple events | web pages' camera, mic and location; favorite previews' calendar; VPN tool's Tunnelblick scripting |
| Kite Helper (utility processes) | JIT, camera, microphone | V8 in the proxy resolver; Chromium's audio and video capture services |
| Kite Helper (Renderer), (GPU) | JIT | V8, SwiftShader |
| Kite Helper (Plugin) | unsigned executable memory, no library validation | Chromium's plugin helper |
| Helpers/kite | Apple events | `kite vpn` drives Tunnelblick through osascript |

The CEF framework's dylibs are signed one by one, since the helpers' library validation only loads
code from the same team. Debug builds stay unhardened, so a debugger can still attach. The
designated requirement doesn't change (Developer ID, team 948JHP35FF), so 1Password's trust in
Kite holds.

`release.sh` and `package-share.sh` then run `scripts/notarize.sh`: it zips the app, submits it
with `xcrun notarytool submit --wait`, prints Apple's log if it's rejected, staples the ticket
(`xcrun stapler staple`) and checks Gatekeeper sees `source=Notarized Developer ID`. Stapling
changes the app, so the release zip and its Sparkle signature are made after it. Updates
themselves don't need it (Sparkle's downloads never carry the quarantine flag); a first install
from a browser download does. `KITE_SKIP_NOTARIZE=1` skips it for a local test build, never with
`--publish`.

## One-time setup (Gabe's Mac)

1. Create the signing key: `swift scripts/sparkle-key.swift`. It writes
   `~/.kite-secrets/sparkle-ed25519` (0600) and prints the public key, which goes in
   `Resources/Info.plist` as `SUPublicEDKey`.
2. Back the key file up in 1Password. Without it, no installed Kite can be updated again
   (they'd need a new build by hand).
3. Create the notarytool keychain profile, `kite-notary` (an app-specific password from
   [account.apple.com](https://account.apple.com) › Sign-In and Security › App-Specific
   Passwords; notarytool asks for it, and checks it with Apple before saving):
   `xcrun notarytool store-credentials kite-notary --apple-id <Apple ID> --team-id 948JHP35FF`.
   An App Store Connect API key works too (`--key`, `--key-id`, `--issuer`).
   `KITE_NOTARY_PROFILE` picks another profile name.
4. A release worktree that nothing else uses:
   `git -C ~/dev/kite worktree add --detach ~/dev/kite-ship origin/main`, then
   `ln -s ~/dev/kite/ThirdParty/cef ~/dev/kite-ship/ThirdParty/cef` (the codecs CEF).

## Releasing

```bash
cd ~/dev/kite-ship
git fetch origin main && git checkout --detach origin/main
scripts/release.sh            # builds dist/release/<version>/ and stops
scripts/release.sh --publish  # the same, then the GitHub release
```

The release has two files: `Kite-<version>.zip` (the app) and `appcast.xml`. It's created as a
draft and published once both are up, so `releases/latest` never points at a release without
its appcast. Installed Kites see it within 8 hours, or at once from Check for Updates….

## Testing an update locally

Build an "older" Kite that reads a local feed, then serve a newer build to it:

```bash
P=$(mktemp -d /tmp/kite-ota.XXXX)
# Both builds get a bundle ID of their own, so Sparkle's and Kite's settings stay out of Gabe's.
export KITE_BUNDLE_ID=dev.gabek.Kite.otatest
# The newer build, served from $P/feed.
KITE_UPDATE_FEED=http://127.0.0.1:8765/appcast.xml KITE_DOWNLOAD_BASE=http://127.0.0.1:8765 \
    scripts/release.sh --allow-branch
cp dist/release/*/Kite-*.zip dist/release/*/appcast.xml "$P/feed/"   # mkdir first
(cd "$P/feed" && python3 -m http.server 8765 --bind 127.0.0.1) &
# The older one, in a folder of its own.
KITE_BUILD_NUMBER=2 KITE_VERSION=0.1.2 KITE_UPDATE_FEED=http://127.0.0.1:8765/appcast.xml scripts/bundle-app.sh release
ditto build/Kite.app "$P/Kite.app"
KITE_SUPPORT_PATH=$(mktemp -d /tmp/k.XXXX) "$P/Kite.app/Contents/MacOS/Kite"
```

Check for Updates… should offer the newer version; Install and Relaunch should bring Kite back
on it. Afterwards delete the test app, `$P`, and `defaults delete dev.gabek.Kite.otatest`.

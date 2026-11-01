# Passkeys in Kite

Kite uses Chromium's WebAuthn stack and its passkey dialog. Which passkeys a
site can reach depends on how Kite is signed, not on Kite's code.

| Where the passkey lives | Works? | What it needs |
| --- | --- | --- |
| A phone (QR code, "Use your phone or tablet") | Yes | `NSBluetoothAlwaysUsageDescription` in Info.plist |
| 1Password | Yes | The 1Password extension, unlocked and connected to the app |
| iCloud Keychain / Passwords app | Only with Apple's grant | `com.apple.developer.web-browser.public-key-credential` from a provisioning profile |
| Chromium's own on-Mac store (Touch ID) | No | A custom CEF build (below) |

## Phone passkeys

Chromium reaches the phone over Bluetooth. Without the Bluetooth usage string
macOS refuses Bluetooth, Chromium logs "Cannot use Bluetooth because the
responsible app … does not have Bluetooth metadata in its Info.plist", and the
dialog only offers a security key or says "No passkeys available".

When testing, launch the build with `open`, not straight from a shell: macOS
holds the terminal responsible for Bluetooth in that case, and the terminal
has no usage string, so you get the error above. Also leave
`KITE_TEST_BLOCK_VIEWS_WINDOWS` unset, since it blocks the passkey dialog.

## iCloud Keychain passkeys

Chromium checks that the browser process has the
`com.apple.developer.web-browser.public-key-credential` entitlement before it
asks macOS for iCloud Keychain passkeys (`device/fido/mac/icloud_keychain_sys.mm`).
It's a restricted entitlement: it has to come from a provisioning profile that
Apple issues for the App ID, or macOS won't launch the app.

To turn it on:

1. In the Apple Developer portal (Certificates, Identifiers & Profiles), create
   an App ID for `dev.gabek.Kite` if there isn't one, and under Capability
   Requests ask for "Web Browser Public Key Credential Requests". Apple reviews
   it by hand, which can take weeks.
2. Once it's approved, create a **Developer ID** provisioning profile for
   `dev.gabek.Kite` with that capability and the Developer ID Application
   certificate Kite is signed with. (1Password only trusts Kite when it's
   signed with Developer ID, so a development profile won't do.)
3. Save it as `~/.kite-secrets/Kite.provisionprofile` (or point
   `KITE_PROVISIONING_PROFILE` at it).

`scripts/bundle-app.sh` then embeds the profile and signs the app with the
entitlement. `scripts/passkey-entitlements.sh` checks the profile first (it
grants the entitlement, matches the App ID, hasn't expired, covers this Mac
and lists the signing cert) and leaves the entitlement out with a warning
otherwise, so a bad profile never produces an app that won't launch.

## Chromium's own on-Mac passkeys

Chrome can also keep passkeys in the macOS keychain behind Touch ID. Chromium
only enables that when the app has a `keychain-access-groups` entitlement equal
to `MAC_TEAM_IDENTIFIER_STRING.MAC_BUNDLE_IDENTIFIER_STRING.webauthn`, values
compiled into the browser. The prebuilt CEF framework has them empty and
`org.chromium.Chromium`, so it expects `.org.chromium.Chromium.webauthn`
(logged as "Touch ID authenticator unavailable because keychain-access-group
entitlement is missing or incorrect"). No profile can grant a group without a
team prefix, so this needs a CEF build with Kite's team and bundle ID. Chrome
itself now saves new passkeys to iCloud Keychain on macOS, so this is low
priority.

#!/usr/bin/env bash
# Assembles build/Kite.app: the app, precompiled shaders, and (when
# scripts/fetch-cef.sh has run) the Chromium framework plus its helper apps.
# Usage: scripts/bundle-app.sh [debug|release]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
cd "$ROOT"

swift build -c "$CONFIG" --product Kite
BIN="$(swift build -c "$CONFIG" --show-bin-path)"
APP="$ROOT/build/Kite.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources/Shaders" "$CONTENTS/Frameworks"
cp "$BIN/Kite" "$CONTENTS/MacOS/Kite"
# The `kite` CLI / MCP server (claude mcp add kite -- …/Kite.app/Contents/Helpers/kite mcp).
swift build -c "$CONFIG" --product kite-cli
mkdir -p "$CONTENTS/Helpers"
cp "$BIN/kite-cli" "$CONTENTS/Helpers/kite"
cp Resources/Info.plist "$CONTENTS/Info.plist"
# Debug builds are test builds: their own bundle ID keeps their UserDefaults (Kite's settings
# and AppKit's window frames alike) out of the installed Kite's dev.gabek.Kite preferences.
# Release builds (install-app.sh, update-app.sh) keep dev.gabek.Kite. KITE_BUNDLE_ID overrides.
BUNDLE_ID="${KITE_BUNDLE_ID:-$([[ "$CONFIG" == debug ]] && echo dev.gabek.Kite.dev || echo dev.gabek.Kite)}"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS/Info.plist"
# Versions: Sparkle orders builds by CFBundleVersion, so it's the commit count of HEAD (it grows with
# every merge to main), and the version people see is Info.plist's major.minor plus that count
# ("0.1.2345"). A shallow clone (CI) can't count, so it keeps Info.plist's. KITE_VERSION and
# KITE_BUILD_NUMBER override them (release.sh's end-to-end test builds an "older" Kite with them).
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$CONTENTS/Info.plist")"
BUILD_NUMBER="${KITE_BUILD_NUMBER:-}"
if [[ -z "$BUILD_NUMBER" && "$(git rev-parse --is-shallow-repository 2>/dev/null)" == false ]]; then
    BUILD_NUMBER="$(git rev-list --count HEAD)"
fi
if [[ -n "$BUILD_NUMBER" ]]; then
    VERSION="${KITE_VERSION:-$(echo "$PLIST_VERSION" | cut -d. -f1,2).$BUILD_NUMBER}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS/Info.plist"
fi
# Over-the-air updates (Sparkle, docs/updates.md) only for builds given a feed: release.sh and
# package-share.sh. Without one, Kite never updates itself (install-app.sh keeps Gabe's Kite current).
# Arc's settings: check every 8 hours, download and install silently on quit.
if [[ -n "${KITE_UPDATE_FEED:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $KITE_UPDATE_FEED" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUEnableAutomaticChecks bool true" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUAutomaticallyUpdate bool true" "$CONTENTS/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :SUScheduledCheckInterval integer 28800" "$CONTENTS/Info.plist"
    # Sparkle checks the archive's EdDSA signature before it unpacks anything.
    /usr/libexec/PlistBuddy -c "Add :SUVerifyUpdateBeforeExtraction bool true" "$CONTENTS/Info.plist"
fi
# Built from Resources/AppIcon.svg (1024 canvas, 824 body, the macOS icon grid).
cp Resources/AppIcon.icns "$CONTENTS/Resources/AppIcon.icns"
# The AppleScript dictionary (Info.plist's OSAScriptingDefinition).
cp Resources/Kite.sdef "$CONTENTS/Resources/Kite.sdef"
# The setup guide `kite setup` hands to Claude Code.
cp Resources/SETUP.md "$CONTENTS/Resources/SETUP.md"
cp Sources/KiteMac/Shaders/*.metal "$CONTENTS/Resources/Shaders/"
# Kite's helper extension (lists and manages extensions), loaded at launch.
rm -rf "$CONTENTS/Resources/KiteHelperExtension"
cp -R Resources/KiteHelperExtension "$CONTENTS/Resources/KiteHelperExtension"

# Precompiled shaders mean no Metal compile at launch. Falls back to runtime
# compilation if the Metal toolchain isn't installed.
if xcrun -sdk macosx metal -c Sources/KiteMac/Shaders/Kite.metal -o "$ROOT/build/Kite.air" 2>/dev/null; then
    xcrun -sdk macosx metallib "$ROOT/build/Kite.air" -o "$CONTENTS/Resources/Kite.metallib"
    rm -f "$ROOT/build/Kite.air"
else
    echo "note: Metal toolchain missing, shaders will compile at launch (xcodebuild -downloadComponent MetalToolchain)"
fi

# Sparkle (over-the-air updates). Kite isn't sandboxed, so Sparkle's XPC services aren't used;
# they're left out, as Sparkle's docs allow.
ditto "$BIN/Sparkle.framework" "$CONTENTS/Frameworks/Sparkle.framework"
rm -rf "$CONTENTS/Frameworks/Sparkle.framework/Versions/B/XPCServices" "$CONTENTS/Frameworks/Sparkle.framework/XPCServices"

CEF="$ROOT/ThirdParty/cef"
if [[ -d "$CEF/Release/Chromium Embedded Framework.framework" ]]; then
    swift build -c "$CONFIG" --product KiteHelper
    cp -R "$CEF/Release/Chromium Embedded Framework.framework" "$CONTENTS/Frameworks/"
    # Chromium launches each process type from its own helper bundle.
    for kind in "" "GPU" "Renderer" "Plugin" "Alerts"; do
        name="Kite Helper${kind:+ ($kind)}"
        id="$BUNDLE_ID.helper${kind:+.$(echo "$kind" | tr '[:upper:]' '[:lower:]')}"
        helper="$CONTENTS/Frameworks/$name.app/Contents"
        mkdir -p "$helper/MacOS"
        cp "$BIN/KiteHelper" "$helper/MacOS/$name"
        sed -e "s/__NAME__/$name/g" -e "s/__ID__/$id/g" Resources/Helper-Info.plist > "$helper/Info.plist"
    done
else
    echo "note: no CEF in ThirdParty/cef, building a WebKit-only app (run scripts/fetch-cef.sh for Chromium)"
fi

# Sign inside out (helpers, framework, app) so everything loads. A stable
# identity keeps the code identity the same across rebuilds, so the keychain
# remembers "Always Allow" for Kite. Ad-hoc signing changes it on every build,
# and macOS asks for your password again. Order: KITE_SIGN_IDENTITY, then a
# valid Developer ID Application cert (1Password only trusts a browser signed
# with one), then Apple Development, then "Kite Local Signing" (make-signing-cert.sh).
SIGN_ID="${KITE_SIGN_IDENTITY:-}"
for kind in "Developer ID Application" "Apple Development"; do
    [[ -n "$SIGN_ID" ]] && break
    # By SHA-1, since an expired copy of the same cert would make the name ambiguous.
    SIGN_ID="$(security find-identity -v -p codesigning | awk -v kind="\"$kind: " 'index($0, kind) { print $2; exit }')"
done
if [[ -z "$SIGN_ID" ]] && security find-certificate -c "Kite Local Signing" >/dev/null 2>&1; then
    SIGN_ID="Kite Local Signing"
fi
if [[ -z "$SIGN_ID" ]]; then
    SIGN_ID="-"
    echo "note: ad-hoc signing, so the keychain will ask again after each rebuild (run scripts/make-signing-cert.sh once to fix)"
fi
codesign --force --sign "$SIGN_ID" "$CONTENTS/Helpers/kite"
for helper in "$CONTENTS/Frameworks/"*.app; do
    [[ -e "$helper" ]] && codesign --force --sign "$SIGN_ID" "$helper"
done
# Sparkle's helpers first, then the framework (Sparkle's documented order, hardened runtime as it ships).
SPARKLE="$CONTENTS/Frameworks/Sparkle.framework"
codesign --force --sign "$SIGN_ID" -o runtime "$SPARKLE/Versions/B/Autoupdate"
codesign --force --sign "$SIGN_ID" -o runtime "$SPARKLE/Versions/B/Updater.app"
codesign --force --sign "$SIGN_ID" -o runtime "$SPARKLE"
if [[ -d "$CONTENTS/Frameworks/Chromium Embedded Framework.framework" ]]; then
    codesign --force --sign "$SIGN_ID" "$CONTENTS/Frameworks/Chromium Embedded Framework.framework"
fi
# Passkeys from iCloud Keychain (the macOS passwords app) only reach a browser
# that has Apple's restricted com.apple.developer.web-browser.public-key-credential
# entitlement; Chromium checks for it before it offers them (icloud_keychain_sys.mm).
# A restricted entitlement needs a provisioning profile from Apple that grants it
# to this App ID and lists the signing cert, or macOS refuses to launch the app.
# So the entitlement is only added when such a profile is present, and checked
# first. See docs/passkeys.md.
PROFILE="${KITE_PROVISIONING_PROFILE:-$HOME/.kite-secrets/Kite.provisionprofile}"
ENTITLEMENTS=()
# The profile is for dev.gabek.Kite only, so other bundle IDs (debug builds) go without it.
if [[ -f "$PROFILE" && "$SIGN_ID" != "-" && "$BUNDLE_ID" == dev.gabek.Kite ]]; then
    if ENT_PLIST="$(scripts/passkey-entitlements.sh "$PROFILE" "$SIGN_ID" "$ROOT/build")"; then
        cp "$PROFILE" "$CONTENTS/embedded.provisionprofile"
        ENTITLEMENTS=(--entitlements "$ENT_PLIST")
        echo "note: signing with the passkey entitlement from $PROFILE"
    else
        echo "warning: not adding the passkey entitlement (see above), iCloud Keychain passkeys stay off" >&2
    fi
fi
codesign --force --sign "$SIGN_ID" ${ENTITLEMENTS[@]+"${ENTITLEMENTS[@]}"} "$APP"
echo "Built $APP"

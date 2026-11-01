#!/usr/bin/env bash
# Checks that a provisioning profile can sign Kite with Apple's passkey
# entitlement, and writes the entitlements plist for codesign.
# Prints the plist's path on success; explains what's wrong on stderr and
# exits 1 otherwise, so bundle-app.sh never produces an app macOS won't launch.
# Usage: scripts/passkey-entitlements.sh <profile> <signing identity: SHA-1 or name> <out dir>
set -euo pipefail

PROFILE="$1"
SIGN_ID="$2"
OUT="$3"
BUNDLE_ID="dev.gabek.Kite"
KEY="com.apple.developer.web-browser.public-key-credential"
mkdir -p "$OUT"
DECODED="$OUT/profile.plist"
ENT="$OUT/Kite.entitlements"

fail() { echo "passkeys: $*" >&2; exit 1; }

security cms -D -i "$PROFILE" > "$DECODED" 2>/dev/null || fail "can't decode $PROFILE"
get() { /usr/libexec/PlistBuddy -c "Print :$1" "$DECODED" 2>/dev/null; }

[[ "$(get "Entitlements:$KEY")" == "true" ]] \
    || fail "the profile doesn't grant $KEY (Apple hasn't approved it for this App ID yet, or the profile predates the approval)"

app_id="$(get 'Entitlements:com.apple.application-identifier')"
team="$(get 'Entitlements:com.apple.developer.team-identifier')"
[[ "$app_id" == "$team.$BUNDLE_ID" ]] || fail "the profile is for $app_id, not $team.$BUNDLE_ID"

# PlistBuddy prints dates like "Sat Nov 01 12:00:00 GMT 2027".
expires="$(get ExpirationDate)"
expires_epoch="$(date -j -f '%a %b %d %T %Z %Y' "$expires" +%s 2>/dev/null || echo 0)"
(( expires_epoch > $(date +%s) )) || fail "the profile expired ($expires)"

# Developer ID profiles cover every Mac; development ones list device UDIDs.
if [[ "$(get ProvisionsAllDevices)" != "true" ]]; then
    udid="$(system_profiler SPHardwareDataType | awk -F': ' '/Provisioning UDID/ { print $2 }')"
    get ProvisionedDevices | grep -q "$udid" || fail "the profile doesn't list this Mac ($udid)"
fi

# The signing cert has to be one the profile names, or the app won't launch.
sha="$SIGN_ID"
if [[ ! "$sha" =~ ^[0-9A-Fa-f]{40}$ ]]; then
    sha="$(security find-certificate -c "$SIGN_ID" -Z 2>/dev/null | awk '/SHA-1 hash:/ { print $3; exit }')"
fi
found=0
i=0
while cert="$(plutil -extract "DeveloperCertificates.$i" raw -o - "$DECODED" 2>/dev/null)"; do
    if [[ "$(echo "$cert" | base64 -D | shasum -a 1 | awk '{ print toupper($1) }')" == "$(echo "$sha" | tr '[:lower:]' '[:upper:]')" ]]; then
        found=1
        break
    fi
    i=$((i + 1))
done
(( found )) || fail "the profile doesn't include the signing cert $SIGN_ID"

cat > "$ENT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.application-identifier</key>
	<string>$app_id</string>
	<key>com.apple.developer.team-identifier</key>
	<string>$team</string>
	<key>$KEY</key>
	<true/>
</dict>
</plist>
EOF
echo "$ENT"

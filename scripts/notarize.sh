#!/usr/bin/env bash
# Notarizes a Developer ID signed, hardened Kite.app with Apple and staples the ticket to it, so
# Gatekeeper opens a downloaded copy without asking (and without install.sh clearing the
# quarantine flag). release.sh and package-share.sh run it; it changes the app in place.
#
# Credentials come from a notarytool keychain profile Gabe creates once (docs/updates.md):
#   xcrun notarytool store-credentials kite-notary --apple-id <Apple ID> --team-id 948JHP35FF
# Usage: scripts/notarize.sh <Kite.app>
# Environment: KITE_NOTARY_PROFILE (default kite-notary).
set -euo pipefail

APP="${1:?usage: scripts/notarize.sh <Kite.app>}"
PROFILE="${KITE_NOTARY_PROFILE:-kite-notary}"
fail() { echo "notarize: $*" >&2; exit 1; }

[[ -d "$APP" ]] || fail "no app at $APP"
SIGNING="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNING" == *$'\nAuthority=Developer ID Application'* ]] || fail "$APP isn't Developer ID signed"
[[ "$SIGNING" == *"flags="*"(runtime)"* ]] || fail "$APP isn't signed with the hardened runtime (bundle-app.sh release)"
[[ "$SIGNING" == *$'\nTimestamp='* ]] || fail "$APP has no secure timestamp (bundle-app.sh release)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# notarytool takes a zip; ditto keeps the bundle's symlinks and signatures intact.
ditto -c -k --keepParent "$APP" "$WORK/Kite.zip"
echo "Submitting $APP for notarization (usually a few minutes)…"
if ! RESULT="$(xcrun notarytool submit "$WORK/Kite.zip" --keychain-profile "$PROFILE" --wait \
        --output-format json 2>"$WORK/err")"; then
    cat "$WORK/err" >&2
    fail "notarytool couldn't submit. If there's no '$PROFILE' profile yet, create it: xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id 948JHP35FF"
fi
STATUS="$(plutil -extract status raw - <<<"$RESULT" 2>/dev/null || true)"
ID="$(plutil -extract id raw - <<<"$RESULT" 2>/dev/null || true)"
if [[ "$STATUS" != Accepted ]]; then
    # Apple's log names each file it rejected and why.
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    fail "Apple didn't accept $APP (status ${STATUS:-unknown}, submission ${ID:-none}): $RESULT"
fi
echo "Notarized (submission $ID)"

# The stapled ticket lets Gatekeeper check the app offline, the first time it opens.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP" 2>&1 | tee "$WORK/spctl"
grep -q 'source=Notarized Developer ID' "$WORK/spctl" || fail "Gatekeeper doesn't see $APP as notarized"

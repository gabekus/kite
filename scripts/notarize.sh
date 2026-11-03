#!/usr/bin/env bash
# Notarizes a Developer ID signed, hardened Kite.app with Apple and staples the ticket to it, so
# Gatekeeper opens a downloaded copy without asking (and without install.sh clearing the
# quarantine flag). release.sh and package-share.sh run it; it changes the app in place.
#
# Credentials come from a notarytool keychain profile Gabe creates once (docs/updates.md):
#   xcrun notarytool store-credentials kite-notary --apple-id <Apple ID> --team-id 948JHP35FF
# Usage: scripts/notarize.sh <Kite.app>
#        scripts/notarize.sh --check   (only checks the profile works, before a build)
# Environment: KITE_NOTARY_PROFILE (default kite-notary).
set -euo pipefail

PROFILE="${KITE_NOTARY_PROFILE:-kite-notary}"
fail() { echo "notarize: $*" >&2; exit 1; }
CREATE="xcrun notarytool store-credentials $PROFILE --apple-id <Apple ID> --team-id 948JHP35FF"

if [[ "${1:-}" == --check ]]; then
    # Asks Apple for past submissions, which needs working credentials.
    xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null \
        || fail "the '$PROFILE' notarytool profile doesn't work. Create it once: $CREATE"
    exit 0
fi

APP="${1:?usage: scripts/notarize.sh <Kite.app> | --check}"
[[ -d "$APP" ]] || fail "no app at $APP"
SIGNING="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNING" == *$'\nAuthority=Developer ID Application'* ]] || fail "$APP isn't Developer ID signed"
[[ "$SIGNING" == *"flags="*"(runtime)"* ]] || fail "$APP isn't signed with the hardened runtime (KITE_HARDENED_RUNTIME=1 bundle-app.sh release)"
[[ "$SIGNING" == *$'\nTimestamp='* ]] || fail "$APP has no secure timestamp (KITE_HARDENED_RUNTIME=1 bundle-app.sh release)"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# notarytool takes a zip; ditto keeps the bundle's symlinks and signatures intact.
ditto -c -k --keepParent "$APP" "$WORK/Kite.zip"
echo "Submitting $APP for notarization (usually a few minutes)…"
# Whatever notarytool exits with, its JSON says what happened (an Invalid result can exit non-zero).
RESULT="$(xcrun notarytool submit "$WORK/Kite.zip" --keychain-profile "$PROFILE" --wait --timeout 30m \
    --output-format json 2>"$WORK/err")" || true
STATUS="$(plutil -extract status raw - <<<"$RESULT" 2>/dev/null || true)"
ID="$(plutil -extract id raw - <<<"$RESULT" 2>/dev/null || true)"
if [[ -z "$ID" ]]; then
    cat "$WORK/err" >&2
    fail "notarytool couldn't submit $APP${RESULT:+: $RESULT}. If the '$PROFILE' profile is missing: $CREATE"
fi
if [[ "$STATUS" != Accepted ]]; then
    # Apple's log names each file it rejected and why.
    xcrun notarytool log "$ID" --keychain-profile "$PROFILE" >&2 || true
    fail "Apple didn't accept $APP (status ${STATUS:-unknown}, submission $ID)"
fi
echo "Notarized (submission $ID)"

# The stapled ticket lets Gatekeeper check the app offline, the first time it opens.
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
ASSESS="$(spctl --assess --type execute --verbose=2 "$APP" 2>&1)" || true
echo "$ASSESS"
[[ "$ASSESS" == *"source=Notarized Developer ID"* ]] || fail "Gatekeeper doesn't see $APP as notarized"

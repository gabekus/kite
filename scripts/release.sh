#!/usr/bin/env bash
# Builds a Kite release that installed Kites pick up by themselves (Sparkle), and with --publish
# puts it on GitHub Releases. See docs/updates.md.
#
#   dist/release/<version>/Kite-<version>.zip   the signed app, which Sparkle downloads
#   dist/release/<version>/appcast.xml          the feed, EdDSA signature included
#   dist/release/<version>/notes.md             what changed since the last release
#
# Every release carries its own appcast.xml, and Kite reads the one on the latest release
# (releases/latest/download/appcast.xml), so publishing a release is all it takes.
#
# Builds into this checkout's build/, so run it in its own worktree (~/dev/kite-ship), never the
# one install-app.sh or update-app.sh use. It never touches /Applications.
#
# Usage: scripts/release.sh [--publish] [--allow-branch]
#   --publish        create the GitHub release (draft first, published once its files are up)
#   --allow-branch   build from something other than origin/main (never with --publish)
# Environment: KITE_SPARKLE_KEY (default ~/.kite-secrets/sparkle-ed25519), and for local tests
#   KITE_UPDATE_FEED / KITE_DOWNLOAD_BASE (feed and download URLs), KITE_ALLOW_NO_CODECS=1.
set -euo pipefail

PUBLISH=0
ALLOW_BRANCH=0
for arg in "$@"; do
    case "$arg" in
        --publish) PUBLISH=1 ;;
        --allow-branch) ALLOW_BRANCH=1 ;;
        *) echo "usage: scripts/release.sh [--publish] [--allow-branch]" >&2; exit 2 ;;
    esac
done
if [[ "$PUBLISH" == 1 && "$ALLOW_BRANCH" == 1 ]]; then
    echo "error: releases are published from origin/main only" >&2
    exit 2
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
REPO=gabekus/kite
FEED="${KITE_UPDATE_FEED:-https://github.com/$REPO/releases/latest/download/appcast.xml}"
KEY_FILE="${KITE_SPARKLE_KEY:-$HOME/.kite-secrets/sparkle-ed25519}"
fail() { echo "error: $*" >&2; exit 1; }

# What gets released is exactly origin/main.
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
    fail "the checkout has uncommitted changes"
fi
if [[ "$ALLOW_BRANCH" == 0 ]]; then
    git fetch --quiet origin main
    [[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] \
        || fail "HEAD isn't origin/main (git checkout --detach origin/main, or --allow-branch for a test build)"
fi
git fetch --quiet --tags origin || true

[[ -d ThirdParty/cef/Release ]] || fail "no CEF in ThirdParty/cef (symlink ~/dev/kite/ThirdParty/cef)"
if ! grep -q codecs ThirdParty/cef/.version 2>/dev/null && [[ "${KITE_ALLOW_NO_CODECS:-}" != 1 ]]; then
    fail "ThirdParty/cef isn't the codecs build (H.264/AAC), so videos on Reddit and X wouldn't play"
fi

# The key that signs the update must be the one installed Kites trust.
[[ -f "$KEY_FILE" ]] || fail "no update signing key at $KEY_FILE (swift scripts/sparkle-key.swift creates one)"
PUBLIC_KEY="$(swift scripts/sparkle-key.swift "$KEY_FILE")"
PLIST_KEY="$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' Resources/Info.plist 2>/dev/null || true)"
[[ "$PUBLIC_KEY" == "$PLIST_KEY" ]] || fail "$KEY_FILE doesn't match SUPublicEDKey in Resources/Info.plist"

# Build, ad blocker included (see install-app.sh).
ADBLOCK_LIB="Sources/KiteAdblock/rust/target/lib/libkite_adblock.a"
[[ -f "$ADBLOCK_LIB" ]] || scripts/build-adblock.sh
links_adblock() { [[ $(nm build/Kite.app/Contents/MacOS/Kite 2>/dev/null | grep -c ka_engine_) -gt 0 ]]; }
KITE_UPDATE_FEED="$FEED" scripts/bundle-app.sh release
if ! links_adblock; then
    swift build -c release --manifest-cache none --product Kite
    KITE_UPDATE_FEED="$FEED" scripts/bundle-app.sh release
fi
links_adblock || fail "build/Kite.app doesn't link the ad blocker"

APP=build/Kite.app
codesign --verify --deep --strict "$APP"
# Sparkle only installs an update signed by the same team as the running Kite, and 1Password only
# trusts a Developer ID browser, so a release must be Developer ID signed.
# (Read into a variable first: grep -q exits at the first match, and under pipefail codesign's
# SIGPIPE would fail the check.)
SIGNING="$(codesign -dv --verbose=2 "$APP" 2>&1)"
[[ "$SIGNING" == *$'\nAuthority=Developer ID Application'* ]] \
    || fail "Kite.app isn't signed with a Developer ID Application certificate"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
[[ "$BUILD" =~ ^[0-9]+$ && "$BUILD" -gt 1 ]] || fail "no build number (CFBundleVersion is $BUILD); is this a shallow clone?"
TAG="v$VERSION"
if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    fail "$TAG already exists"
fi

OUT="$ROOT/dist/release/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"
ZIP_NAME="Kite-$VERSION.zip"
ZIP="$OUT/$ZIP_NAME"
# ditto keeps the bundle's symlinks and signatures intact; plain zip breaks the frameworks.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

SPARKLE_BIN=.build/artifacts/sparkle/Sparkle/bin
[[ -x "$SPARKLE_BIN/sign_update" ]] || fail "no $SPARKLE_BIN/sign_update (swift package resolve)"
# Prints: sparkle:edSignature="…" length="…"
SIGNATURE="$("$SPARKLE_BIN/sign_update" --ed-key-file "$KEY_FILE" "$ZIP")"
[[ "$SIGNATURE" == *'sparkle:edSignature="'* ]] || fail "sign_update said: $SIGNATURE"

# Release notes: one line per pull request merged since the previous release.
PREVIOUS="$(git describe --tags --abbrev=0 --match 'v[0-9]*' HEAD^ 2>/dev/null || true)"
{
    if [[ -n "$PREVIOUS" ]]; then
        range="$PREVIOUS..HEAD"
    else
        range="HEAD~20..HEAD"
        echo "The first Kite release that updates itself. Recent changes:"
        echo
    fi
    git log --first-parent --format='%H' "$range" | while read -r commit; do
        subject="$(git log -1 --format=%s "$commit")"
        if [[ "$subject" =~ ^Merge\ pull\ request\ \#([0-9]+) ]]; then
            title="$(git log -1 --format=%b "$commit" | sed -n '/[^[:space:]]/{p;q;}')"
            echo "- ${title:-$subject} (#${BASH_REMATCH[1]})"
        else
            echo "- $subject"
        fi
    done
} > "$OUT/notes.md"

html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
NOTES_HTML="$({ grep '^- ' "$OUT/notes.md" || true; } | sed 's/^- //' | html_escape | sed 's|.*|<li>&</li>|')"
DOWNLOAD_BASE="${KITE_DOWNLOAD_BASE:-https://github.com/$REPO/releases/download/$TAG}"
MIN_SYSTEM="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
cat > "$OUT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Kite</title>
    <link>https://github.com/$REPO</link>
    <item>
      <title>Kite $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MIN_SYSTEM</sparkle:minimumSystemVersion>
      <sparkle:fullReleaseNotesLink>https://github.com/$REPO/releases/tag/$TAG</sparkle:fullReleaseNotesLink>
      <description><![CDATA[<ul>
$NOTES_HTML
</ul>]]></description>
      <enclosure url="$DOWNLOAD_BASE/$ZIP_NAME" type="application/octet-stream" $SIGNATURE />
    </item>
  </channel>
</rss>
EOF
echo "Built Kite $VERSION (build $BUILD) in $OUT ($(du -h "$ZIP" | cut -f1))"

if [[ "$PUBLISH" == 0 ]]; then
    echo "Not published (run again with --publish)"
    exit 0
fi

# A draft first, so releases/latest (and its appcast.xml) only moves once both files are up.
gh release create "$TAG" "$ZIP" "$OUT/appcast.xml" --repo "$REPO" --target "$(git rev-parse HEAD)" \
    --title "Kite $VERSION" --notes-file "$OUT/notes.md" --draft
gh release edit "$TAG" --repo "$REPO" --draft=false --latest
echo "Published https://github.com/$REPO/releases/tag/$TAG"

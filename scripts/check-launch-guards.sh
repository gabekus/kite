#!/usr/bin/env bash
# Holds every script that launches Kite to scripts/lib/test-kite.sh, and tests that guard. CI runs it.
#
# 1. Every tracked shell script that starts a Kite binary (…/Contents/MacOS/Kite, .build/<config>/Kite, `open` on a
#    Kite.app or bundle ID) must source scripts/lib/test-kite.sh and call kite_check_test_launch before its first
#    launch, unless it's listed below as launching the installed Kite on purpose.
# 2. kite_check_test_launch itself refuses: no profile, a missing one, a symlink, the real profile, a folder outside
#    /tmp, a non-empty unmarked folder, a dev.gabek.Kite bundle and a bundle in /Applications; and lets a fresh
#    kite_test_profile with a dev.gabek.Kite.dev bundle through.
#
# Why: on 5 Nov 2026 a perf build ran on Gabe's real profile and held its automation socket for three hours.
# Usage: scripts/check-launch-guards.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# Scripts that launch the installed Kite itself (they never start a test build).
INSTALLED_KITE_LAUNCHERS=(
    scripts/install-app.sh       # open "$DEST" after installing /Applications/Kite.app
    Resources/share/install.sh   # the same, for a shared Kite
)

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# --- 1. Every launcher is guarded. ---
# A line starts Kite when it runs a Kite executable or opens a Kite app; lines that only look at one (pgrep, nm,
# cp, grep, PlistBuddy, tests with [[ ]]) and comments don't count.
LAUNCH='(Contents/MacOS/Kite|\.build/(debug|release)/Kite|\$BIN/Kite)(["'"'"']?)([[:space:]]|$|&|\))|(^|[[:space:];&|(])open[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*([^|;&]*\.app\b|-b[[:space:]]+["'"'"']?dev\.gabek\.Kite|Kite\b)'
LOOKS='(^|[[:space:]])(pgrep|pkill|nm|cp|ditto|grep|lsof|codesign|PlistBuddy|lsregister|echo|printf|mv|rm|ln|cat|test|\[\[|links_adblock)([[:space:]]|$)'
checked=0
while IFS= read -r file; do
    [[ -f "$file" ]] || continue
    case "$file" in windows/*|scripts/lib/test-kite.sh|scripts/check-launch-guards.sh) continue ;; esac
    # Shell scripts only: *.sh, or a shell shebang.
    if [[ "$file" != *.sh ]] && ! head -1 "$file" | grep -qE '^#!.*\b(ba|z)?sh\b'; then continue; fi
    first_launch=0
    first_check=0
    sources=0
    n=0
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        code="${line%%#*}"   # a launch in a comment doesn't count
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        if [[ "$code" =~ source.*lib/test-kite\.sh || "$code" =~ \.\ .*lib/test-kite\.sh ]]; then sources=1; fi
        if [[ $first_check == 0 && "$code" =~ kite_check_test_launch ]]; then first_check=$n; fi
        if [[ $first_launch == 0 ]] && echo "$code" | grep -qE "$LAUNCH" && ! echo "$code" | grep -qE "$LOOKS"; then
            first_launch=$n
        fi
    done <"$file"
    [[ $first_launch == 0 ]] && continue
    checked=$((checked + 1))
    allowed=0
    for installer in "${INSTALLED_KITE_LAUNCHERS[@]}"; do [[ "$file" == "$installer" ]] && allowed=1; done
    if [[ $allowed == 1 ]]; then
        echo "ok: $file launches the installed Kite (allowed)"
        continue
    fi
    if [[ $sources == 0 ]]; then
        fail "$file:$first_launch launches Kite but doesn't source scripts/lib/test-kite.sh"
    elif [[ $first_check == 0 || $first_check -gt $first_launch ]]; then
        fail "$file:$first_launch launches Kite before kite_check_test_launch"
    else
        echo "ok: $file checks its launch (line $first_check) before starting Kite (line $first_launch)"
    fi
done < <(git ls-files)
[[ $checked -gt 0 ]] || fail "found no script that launches Kite: the pattern is broken"

# --- 2. The guard refuses what it should. ---
# shellcheck source=lib/test-kite.sh
source "$ROOT/scripts/lib/test-kite.sh"
WORK="$(mktemp -d /tmp/kg.XXXX)"
trap 'rm -rf "$WORK"' EXIT
make_app() { # make_app PATH BUNDLE_ID
    mkdir -p "$1/Contents/MacOS"
    cat >"$1/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleIdentifier</key><string>$2</string></dict></plist>
PLIST
}
make_app "$WORK/Dev.app" dev.gabek.Kite.dev
make_app "$WORK/Release.app" dev.gabek.Kite
expect() { # expect pass|refuse WHAT APP PROFILE
    local want=$1 what=$2 status=0
    shift 2
    (unset KITE_SUPPORT_PATH; kite_check_test_launch "$@") >"$WORK/out" 2>&1 || status=$?
    if [[ $want == pass && $status != 0 ]]; then fail "guard refused $what: $(cat "$WORK/out")"; fi
    if [[ $want == refuse && $status == 0 ]]; then fail "guard let through $what"; fi
    if [[ $want == refuse && $status != 0 ]]; then echo "ok: refuses $what"; fi
    if [[ $want == pass && $status == 0 ]]; then echo "ok: allows $what"; fi
}
FRESH="$(kite_test_profile)"
expect pass "a fresh test profile with a dev bundle" "$WORK/Dev.app" "$FRESH"
echo '{}' >"$FRESH/session.json"
expect pass "a seeded test profile (marked)" "$WORK/Dev.app" "$FRESH"
expect pass "a bare swift build binary" "$WORK/.build/debug/Kite" "$FRESH"
expect refuse "no profile" "$WORK/Dev.app" ""
expect refuse "a profile that doesn't exist" "$WORK/Dev.app" "/tmp/k.does-not-exist-$$"
expect refuse "the real profile" "$WORK/Dev.app" "$HOME/Library/Application Support/Kite"
mkdir -p "$WORK/home-like"
ln -s "$HOME/Library/Application Support" "$WORK/link"
expect refuse "a symlink to a profile" "$WORK/Dev.app" "$WORK/link"
expect refuse "a folder outside the temp folders" "$WORK/Dev.app" "$ROOT"
UNMARKED="$(mktemp -d /tmp/k.XXXX)"
echo '{}' >"$UNMARKED/session.json"
expect refuse "a non-empty profile that isn't marked as a test profile" "$WORK/Dev.app" "$UNMARKED"
rm -rf "$UNMARKED"
expect refuse "a dev.gabek.Kite bundle" "$WORK/Release.app" "$FRESH"
expect refuse "a dev.gabek.Kite executable" "$WORK/Release.app/Contents/MacOS/Kite" "$FRESH"
if [[ -d /Applications/Kite.app ]]; then
    expect refuse "the Kite in /Applications" /Applications/Kite.app "$FRESH"
fi
status=0
(KITE_SUPPORT_PATH=/tmp/k.other kite_check_test_launch "$WORK/Dev.app" "$FRESH") >/dev/null 2>&1 || status=$?
if [[ $status == 0 ]]; then fail "guard let through a KITE_SUPPORT_PATH other than the checked profile"; else echo "ok: refuses a mismatched KITE_SUPPORT_PATH"; fi
rm -rf "$FRESH"

if [[ $failures -gt 0 ]]; then
    echo "$failures check(s) failed" >&2
    exit 1
fi
echo "OK: every Kite launch is guarded, and the guard refuses what it should"

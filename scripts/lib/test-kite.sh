# shellcheck shell=bash
# Sourced by every script that launches a Kite build (scripts/check-launch-guards.sh holds them to it).
# A test Kite runs only on a fresh throwaway profile, never Gabe's real one (~/Library/Application Support/Kite),
# and never as dev.gabek.Kite, whose UserDefaults are the installed Kite's. On 5 Nov 2026 a perf build on the real
# profile held its automation socket for three hours, and every Claude session drove it instead of /Applications/Kite.app.
#
#   source "$ROOT/scripts/lib/test-kite.sh"
#   P=$(kite_test_profile)                 # mktemp -d /tmp/k.XXXX, marked as a test profile
#   … seed files into "$P" if the test needs them …
#   kite_check_test_launch "$APP" "$P"      # right before the launch; exits 2 with the reason if it isn't safe
#   KITE_SUPPORT_PATH=$P "$APP/Contents/MacOS/Kite" &

# The file that marks a folder as a test profile (so a seeded or relaunched profile still passes).
KITE_TEST_PROFILE_MARKER=.kite-test-profile

# Prints a fresh test profile: an empty folder in /tmp (socket paths are limited to 104 bytes), marked.
kite_test_profile() {
    local profile
    profile="$(mktemp -d /tmp/k.XXXX)" || return 1
    [[ -d "$profile" && ! -L "$profile" ]] || { echo "kite_test_profile: $profile isn't a directory" >&2; return 1; }
    : >"$profile/$KITE_TEST_PROFILE_MARKER"
    printf '%s\n' "$profile"
}

_kite_refuse() { echo "refusing to launch Kite: $*" >&2; return 2; }

# Resolved path of an existing folder (symlinks, .., /tmp → /private/tmp).
_kite_realdir() { (cd "$1" 2>/dev/null && pwd -P); }

# kite_check_test_launch APP PROFILE: returns 0 only when launching APP on PROFILE can't touch the real profile or
# the installed Kite's settings; otherwise prints why and returns 2 (callers run under set -e, so the script stops).
# APP is a .app bundle or a bare binary (.build/debug/Kite).
kite_check_test_launch() {
    local app="${1:-}" profile="${2:-}"
    [[ -n "$app" ]] || { _kite_refuse "no app given"; return 2; }
    [[ -n "$profile" ]] || { _kite_refuse "no test profile: set KITE_SUPPORT_PATH to \$(kite_test_profile)"; return 2; }
    [[ -e "$profile" ]] || { _kite_refuse "the test profile $profile doesn't exist (Chromium would fall back to a real profile)"; return 2; }
    [[ ! -L "$profile" ]] || { _kite_refuse "the test profile $profile is a symlink"; return 2; }
    [[ -d "$profile" ]] || { _kite_refuse "the test profile $profile isn't a directory"; return 2; }
    if [[ -n "${KITE_SUPPORT_PATH+set}" && "${KITE_SUPPORT_PATH}" != "$profile" ]]; then
        _kite_refuse "KITE_SUPPORT_PATH is $KITE_SUPPORT_PATH, not the profile being checked ($profile)"; return 2
    fi

    local resolved real
    resolved="$(_kite_realdir "$profile")"
    real="$HOME/Library/Application Support/Kite"
    [[ -d "$real" ]] && real="$(_kite_realdir "$real")"
    shopt -s nocasematch
    if [[ "$resolved" == "$real" || "$resolved" == "$real"/* || "$resolved" == "$HOME/Library"* ]]; then
        shopt -u nocasematch
        _kite_refuse "$profile is the real profile (or inside ~/Library)"; return 2
    fi
    shopt -u nocasematch
    local tmp_root ok=0
    for tmp_root in /private/tmp /private/var/folders "$(_kite_realdir "${TMPDIR:-/tmp}")"; do
        [[ -n "$tmp_root" && "$resolved" == "$tmp_root"/* ]] && ok=1
    done
    [[ $ok == 1 ]] || { _kite_refuse "$profile isn't a fresh temporary folder (mktemp -d /tmp/k.XXXX)"; return 2; }
    if [[ ! -e "$profile/$KITE_TEST_PROFILE_MARKER" ]] && [[ -n "$(ls -A "$profile")" ]]; then
        _kite_refuse "$profile isn't empty and isn't marked as a test profile (use kite_test_profile)"; return 2
    fi

    local bundle_path id resolved_app
    if [[ -d "$app" && "$app" == *.app ]]; then
        bundle_path="$app"
    elif [[ "$app" == */Contents/MacOS/* ]]; then
        bundle_path="${app%%/Contents/MacOS/*}"
    fi
    if [[ -n "$bundle_path" ]]; then
        [[ -f "$bundle_path/Contents/Info.plist" ]] || { _kite_refuse "$bundle_path has no Info.plist"; return 2; }
        id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$bundle_path/Contents/Info.plist" 2>/dev/null || true)"
        [[ -n "$id" ]] || { _kite_refuse "$bundle_path has no bundle ID"; return 2; }
        shopt -s nocasematch
        if [[ "$id" == dev.gabek.Kite ]]; then
            shopt -u nocasematch
            _kite_refuse "$bundle_path is dev.gabek.Kite, the installed Kite's bundle ID: build it with scripts/bundle-app.sh debug (dev.gabek.Kite.dev) or KITE_BUNDLE_ID=dev.gabek.Kite.dev"
            return 2
        fi
        resolved_app="$(_kite_realdir "$bundle_path")"
        if [[ "$resolved_app" == /Applications/* || "$resolved_app" == "$HOME/Applications/"* ]]; then
            shopt -u nocasematch
            _kite_refuse "$bundle_path is in Applications: test builds only"; return 2
        fi
        shopt -u nocasematch
    fi
    return 0
}

# A TCP port free on 127.0.0.1 right now, for a test's page server. A fixed default port can be held by a server an
# earlier run left behind, serving another checkout's pages: the test's own server then fails to bind and the old
# one answers, with pages that may be missing or out of date.
kite_free_port() {
    python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

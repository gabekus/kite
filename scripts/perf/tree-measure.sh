#!/usr/bin/env bash
# Whole-tree cost of Kite: launches APP on a fresh test profile, opens a fixed set of local tabs, lets it
# settle, then samples Kite's main process and every Chromium helper (renderers, GPU, network, storage) over
# SECONDS with tree-rusage. Prints per-process lines and a TOTAL line, labelled.
# Usage: scripts/perf/tree-measure.sh APP [LABEL] [SECONDS]
# Pages come from a local server (PAGES, default http://127.0.0.1:18765) serving p1–p10.html (static) and
# b1–b5.html (timers, requestAnimationFrame and a CSS animation). TABS picks them (default "p1 … p10");
# the last one opened is the selected tab. SETTLE (default 30) is the wait before sampling.
# MINIMIZE=1 minimizes the window first; HIDE=1 hides Kite (⌘H) first. ARGS are passed to Kite (Chromium
# switches, e.g. ARGS=--disable-features=SpareRendererForSitePerProcess), to measure one before building it in.
set -euo pipefail
APP="$1"; LABEL="${2:-run}"; SECS="${3:-60}"; SETTLE="${SETTLE:-30}"
TABS="${TABS:-p1 p2 p3 p4 p5 p6 p7 p8 p9 p10}"
# shellcheck source=../lib/test-kite.sh
source "$(dirname "$0")/../lib/test-kite.sh"
P=$(kite_test_profile)
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
# Refuses (exit 2), before anything starts, whatever could reach the real profile or the installed Kite's settings.
kite_check_test_launch "$APP" "$P" || exit 2
# shellcheck disable=SC2086
"$APP/Contents/MacOS/Kite" ${ARGS:-} >"$P/kite.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; sleep 1; pkill -9 -f "$P" 2>/dev/null; rm -rf "$P"' EXIT
CLI="$APP/Contents/Helpers/kite"
for _ in $(seq 60); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
PAGES="${PAGES:-http://127.0.0.1:18765}"
FIRST=$("$CLI" tabs 2>/dev/null | awk '/^- tab / {print $3; exit}')
for t in $TABS; do "$CLI" open "$PAGES/$t.html" >/dev/null 2>&1 || true; done
[[ -n "$FIRST" ]] && "$CLI" call tabs_close "{\"tab\":\"$FIRST\"}" >/dev/null 2>&1 || true
[[ -n "${MINIMIZE:-}" ]] && { "$CLI" ui input '{"keys":"cmd+m"}' >/dev/null 2>&1 || true; }
[[ -n "${HIDE:-}" ]] && { "$CLI" ui input '{"keys":"cmd+h"}' >/dev/null 2>&1 || true; }
sleep "$SETTLE"
# Kite's helpers carry the profile path on their command lines.
PIDS="$PID $(pgrep -f "$P" | grep -vx "$PID" | tr '\n' ' ')"
TREE="$(dirname "$0")/../../build/perf/tree-rusage"
[[ -x "$TREE" ]] || cc -O2 -o "$TREE" "$(dirname "$0")/tree-rusage.c"
"$TREE" "$SECS" $PIDS | sed "s/^/$LABEL /"

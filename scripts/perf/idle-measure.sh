#!/usr/bin/env bash
# Idle cost of Kite's main process: launches APP on a fresh test profile, opens a fixed set of
# static tabs, lets it settle, then samples the main process for SECONDS.
# Usage: scripts/perf/idle-measure.sh APP [LABEL] [SECONDS]
# Prints one line: the label, then CPU ms per second, wakeups per second, energy and footprint
# (proc_pid_rusage deltas, scripts/perf/rusage.c). SETTLE (default 30) sets the wait before sampling;
# HOVER=1 sweeps the pointer over the sidebar and scrolls it first.
set -euo pipefail
APP="$1"; LABEL="${2:-run}"; SECS="${3:-60}"; SETTLE="${SETTLE:-30}"
P=$(mktemp -d /tmp/k.XXXX)
[[ -d "$P" ]] || { echo "profile not a directory" >&2; exit 1; }
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$P"' EXIT
CLI="$APP/Contents/Helpers/kite"
for _ in $(seq 40); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
# Static pages from a local server (PAGES, default 127.0.0.1:18765), so nothing depends on the network.
PAGES="${PAGES:-http://127.0.0.1:18765}"
FIRST=$("$CLI" tabs 2>/dev/null | awk '/^- tab / {print $3; exit}')
for i in $(seq 10); do "$CLI" open "$PAGES/p$i.html" >/dev/null 2>&1 || true; done
# The fresh profile's own first tab (a network page) goes.
[[ -n "$FIRST" ]] && "$CLI" call tabs_close "{\"tab\":\"$FIRST\"}" >/dev/null 2>&1 || true
if [[ -n "${HOVER:-}" ]]; then
  "$CLI" ui pointer '{"from":[20,200],"to":[220,420],"steps":40}' >/dev/null 2>&1 || true
  "$CLI" ui input '{"scroll":[160,500],"dy":-200}' >/dev/null 2>&1 || true
  "$CLI" ui input '{"scroll":[160,500],"dy":200}' >/dev/null 2>&1 || true
  "$CLI" ui pointer '{"from":[220,420],"to":[600,420],"steps":10}' >/dev/null 2>&1 || true
fi
sleep "$SETTLE"
RUSAGE="$(dirname "$0")/../../build/perf/rusage"
[[ -x "$RUSAGE" ]] || cc -O2 -o "$RUSAGE" "$(dirname "$0")/rusage.c"
echo "$LABEL $("$RUSAGE" $PID "$SECS")"

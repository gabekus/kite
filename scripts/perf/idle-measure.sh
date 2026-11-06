#!/usr/bin/env bash
# Idle cost of Kite's main process: launches APP on a fresh test profile, opens a fixed set of
# static tabs, lets it settle, then samples the main process for SECONDS.
# Usage: scripts/perf/idle-measure.sh APP [LABEL] [SECONDS]
# Prints one line: the label, then CPU ms per second, wakeups per second, energy, disk writes and
# footprint (proc_pid_rusage deltas, scripts/perf/rusage.c). SETTLE (default 30) sets the wait before
# sampling; HOVER=1 sweeps the pointer over the sidebar and scrolls it first.
# ALL=1 also prints the sum over the main process and all its Kite Helper children (renderers, GPU,
# network), sampled over the same interval: two lines, "LABEL main …" and "LABEL all …".
# STATE=dir copies the profile files it holds (session.json, "Claude Handoffs.json", automation.json)
# into the fresh profile before launch; with a session.json, its tabs replace the ten static ones.
# In those files http://127.0.0.1:18765 becomes PAGES, and __NOW_MINUS_<n>H__ a time n hours ago.
# ADBLOCK=dir seeds the ad blocker with fixture lists (see below).
# Fixtures (fake data only, never a real profile): scripts/perf/fixtures/.
set -euo pipefail
APP="$1"; LABEL="${2:-run}"; SECS="${3:-60}"; SETTLE="${SETTLE:-30}"
# Static pages from a local server (PAGES, default 127.0.0.1:18765), so nothing depends on the network.
PAGES="${PAGES:-http://127.0.0.1:18765}"
# shellcheck source=../lib/test-kite.sh
source "$(dirname "$0")/../lib/test-kite.sh"
P=$(kite_test_profile)
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
# Refuses (exit 2), before anything starts, whatever could reach the real profile or the installed Kite's settings.
kite_check_test_launch "$APP" "$P" || exit 2
if [[ -n "${STATE:-}" ]]; then
  [[ -d "$STATE" ]] || { echo "STATE must be a directory" >&2; exit 1; }
  for f in session.json "Claude Handoffs.json" automation.json; do
    [[ -f "$STATE/$f" ]] || continue
    PAGES="$PAGES" perl -MPOSIX=strftime -pe \
      's#http://127\.0\.0\.1:18765#$ENV{PAGES}#g; s/__NOW_MINUS_(\d+)H__/strftime("%Y-%m-%dT%H:%M:%SZ", gmtime(time - $1 * 3600))/ge' \
      "$STATE/$f" >"$P/$f"
  done
fi
# ADBLOCK=dir gives the ad blocker dir's lists (<list id>.txt, e.g. fixtures/adblock/easylist.txt)
# marked fresh, so it builds from them and downloads nothing. Serve fixtures/adblock as PAGES for
# its ad-heavy pages.
if [[ -n "${ADBLOCK:-}" ]]; then
  mkdir -p "$P/Adblock/lists"
  cp "$ADBLOCK"/*.txt "$P/Adblock/lists/"
  echo '[]' >"$P/Adblock/resources.json"
  NOW=$(( $(date +%s) - 978307200 ))  # Foundation's reference date
  echo "{\"listsUpdatedAt\":$NOW,\"resourcesUpdatedAt\":$NOW,\"listsFormat\":2}" >"$P/Adblock/status.json"
fi
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$P"' EXIT
CLI="$APP/Contents/Helpers/kite"
for _ in $(seq 40); do "$CLI" ui windows >/dev/null 2>&1 && break; sleep 0.5; done
if [[ ! -f "$P/session.json" ]]; then
  FIRST=$("$CLI" tabs 2>/dev/null | awk '/^- tab / {print $3; exit}')
  for i in $(seq 10); do "$CLI" open "$PAGES/p$i.html" >/dev/null 2>&1 || true; done
  # The fresh profile's own first tab (a network page) goes.
  [[ -n "$FIRST" ]] && "$CLI" call tabs_close "{\"tab\":\"$FIRST\"}" >/dev/null 2>&1 || true
fi
if [[ -n "${HOVER:-}" ]]; then
  "$CLI" ui pointer '{"from":[20,200],"to":[220,420],"steps":40}' >/dev/null 2>&1 || true
  "$CLI" ui input '{"scroll":[160,500],"dy":-200}' >/dev/null 2>&1 || true
  "$CLI" ui input '{"scroll":[160,500],"dy":200}' >/dev/null 2>&1 || true
  "$CLI" ui pointer '{"from":[220,420],"to":[600,420],"steps":10}' >/dev/null 2>&1 || true
fi
sleep "$SETTLE"
# SWITCH=1: switch spaces back and forth (⌃2, ⌃1) every half second while sampling.
if [[ -n "${SWITCH:-}" ]]; then
  ( end=$((SECONDS + SECS)); while (( SECONDS < end )); do
      "$CLI" ui input '{"keys":"ctrl+2"}' >/dev/null 2>&1; sleep 0.5
      "$CLI" ui input '{"keys":"ctrl+1"}' >/dev/null 2>&1; sleep 0.5
    done ) &
fi
# RELOAD=1: reload the front tab (⌘R) every half second while sampling: page status changes.
if [[ -n "${RELOAD:-}" ]]; then
  ( end=$((SECONDS + SECS)); while (( SECONDS < end )); do
      "$CLI" ui input '{"keys":"cmd+r"}' >/dev/null 2>&1; sleep 0.5
    done ) &
fi
# TYPE=1: open the command bar, type a query and close it, every second, while sampling.
if [[ -n "${TYPE:-}" ]]; then
  ( end=$((SECONDS + SECS)); while (( SECONDS < end )); do
      "$CLI" ui input '{"keys":"cmd+t"}' >/dev/null 2>&1
      "$CLI" ui input '{"text":"static page"}' >/dev/null 2>&1; sleep 0.6
      "$CLI" ui input '{"keys":"escape"}' >/dev/null 2>&1; sleep 0.4
    done ) &
fi
RUSAGE="$(dirname "$0")/../../build/perf/rusage"
[[ -x "$RUSAGE" && "$RUSAGE" -nt "$(dirname "$0")/rusage.c" ]] || { mkdir -p "$(dirname "$RUSAGE")"; cc -O2 -o "$RUSAGE" "$(dirname "$0")/rusage.c"; }
PIDS=()
if [[ -n "${ALL:-}" ]]; then
  # Kite's Chromium helpers are its direct children ("Kite Helper", "Kite Helper (Renderer)", …).
  while read -r child; do
    [[ "$(ps -o comm= -p "$child" 2>/dev/null)" == *"Kite Helper"* ]] && PIDS+=("$child")
  done < <(pgrep -P "$PID")
fi
if [[ -n "${ALL:-}" ]]; then
  # The main process alone over the same interval, then the sum.
  "$RUSAGE" $PID "$SECS" >"$P/main.txt" &
  ALLOUT=$("$RUSAGE" $PID "$SECS" ${PIDS[@]+"${PIDS[@]}"})
  wait $!
  echo "$LABEL main $(cat "$P/main.txt")"
  echo "$LABEL all $ALLOUT processes=$((${#PIDS[@]} + 1))"
else
  echo "$LABEL $("$RUSAGE" $PID "$SECS")"
fi

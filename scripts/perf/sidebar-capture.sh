#!/usr/bin/env bash
# Captures the sidebar for a before/after comparison: launches APP on a fresh test profile with the same
# static tabs as idle-measure.sh, waits for Claude's rings from opening them to go, then saves captures,
# the accessibility/view tree and pointer sweeps into OUT.
# Usage: scripts/perf/sidebar-capture.sh APP OUT
# STATE=path/to/state.json seeds the profile (a light theme, folders, pinned tabs) before launch.
set -euo pipefail
APP="$1"; OUT="$2"
mkdir -p "$OUT"
P=$(mktemp -d /tmp/k.XXXX)
[[ -d "$P" ]] || { echo "profile not a directory" >&2; exit 1; }
export KITE_SUPPORT_PATH=$P KITE_TEST_BLOCK_VIEWS_WINDOWS=1 TYPESAFE_API_KEY=x KITE_DIAGNOSTICS=1
[[ -n "${STATE:-}" ]] && cp "$STATE" "$P/session.json"
"$APP/Contents/MacOS/Kite" --disable-backgrounding-occluded-windows >"$P/kite.log" 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$P"' EXIT
CLI_BIN="$APP/Contents/Helpers/kite"
# Every call gets 30 s: a capture can hang (seen once in 30 runs on 2 Nov 2026).
CLI() { perl -e 'alarm shift; exec @ARGV' 30 "$CLI_BIN" "$@"; }
for _ in $(seq 40); do CLI ui windows >/dev/null 2>&1 && break; sleep 0.5; done
if [[ -z "${STATE:-}" ]]; then
  PAGES="${PAGES:-http://127.0.0.1:18765}"
  FIRST=$(CLI tabs 2>/dev/null | awk '/^- tab / {print $3; exit}')
  for i in $(seq 10); do CLI open "$PAGES/p$i.html" >/dev/null 2>&1 || true; done
  [[ -n "$FIRST" ]] && CLI call tabs_close "{\"tab\":\"$FIRST\"}" >/dev/null 2>&1 || true
fi
sleep "${WAIT:-22}"
# Off the sidebar first, so nothing is hovered.
CLI ui pointer '{"points":[[700,400]]}' >/dev/null
CLI ui capture '{"region":[0,0,330,820]}' -o "$OUT/idle.png" >/dev/null
CLI ui tree '{"root":"0.5"}' > "$OUT/tree.txt"
for spot in ${HOVERS:-"tab:160,400" "selected:160,650" "newtab:160,240" "header:160,175"}; do
  name=${spot%%:*}; xy=${spot#*:}
  CLI ui pointer "{\"points\":[[700,400],[$xy]]}" >/dev/null
  CLI ui capture '{"region":[0,0,330,820]}' -o "$OUT/hover-$name.png" >/dev/null
done
CLI ui pointer '{"from":[2,150],"to":[328,150],"steps":82}' > "$OUT/pointer-x.txt"
CLI ui pointer '{"from":[160,150],"to":[160,780],"steps":158}' > "$OUT/pointer-y.txt"
CLI ui pointer '{"points":[[700,400]]}' >/dev/null
ls "$P" > "$OUT/profile-files.txt"
echo "captured into $OUT"
